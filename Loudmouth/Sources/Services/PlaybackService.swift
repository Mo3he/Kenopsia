import AVFoundation
import CoreMedia
import MediaPlayer
import MusicKit
import Combine

private extension Double {
    /// Returns self if non-zero, otherwise returns `fallback`.
    func nonZeroOr(_ fallback: Double) -> Double { self != 0 ? self : fallback }
}

// MARK: - PlaybackService
/// Coordinates the AudioEngine with the Queue model.
/// Owns the Now Playing info center and remote command center.
/// This is the single source of truth for "what is playing".
///
/// Two playback paths:
///   • Local files  → AVAudioEngine (gapless, EQ, ReplayGain)
///   • Remote URLs  → AVPlayer     (HTTP streaming, HLS, Icecast)
@MainActor
final class PlaybackService: ObservableObject {
    // MARK: - Shared instance (used by CarPlay and the SwiftUI layer)
    static let shared = PlaybackService()
    // MARK: - Published state
    @Published private(set) var state = PlayerState()
    @Published private(set) var queue = Queue()
    @Published private(set) var currentLyrics: [LyricsLine] = []
    @Published private(set) var currentEQPreset: EQPreset = .flat

    // MARK: - Dependencies
    private let engine: AudioEngine
    private let sourceResolver: SourceResolver
    private let artworkCache: ArtworkCache
    private let lyricsService: LyricsService
    private let statsStore: ListeningStatsStore
    private let eqStore: EQPresetStore

    // MARK: - Remote stream player (for non-file URLs)
    private let streamPlayer = AVPlayer()
    private var streamObserver: Any?
    private var streamStatusObservation: NSKeyValueObservation?
    private var streamTimeObservation: Any?
    private var streamEndObserver: (any NSObjectProtocol)?   // stored token for AVPlayerItemDidPlayToEndTime

    // MARK: - Apple Music player
    private let musicPlayer = ApplicationMusicPlayer.shared
    private var musicPlayerSubscription: AnyCancellable?
    private var currentPathIsAppleMusic = false

    // MARK: - Internal
    private var positionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var currentPathIsStream = false
    private var settingsObserver: NSObjectProtocol?

    // MARK: - Init
    init(
        engine: AudioEngine = AudioEngine(),
        sourceResolver: SourceResolver = SourceResolver(),
        artworkCache: ArtworkCache = ArtworkCache.shared,
        lyricsService: LyricsService = LyricsService(),
        statsStore: ListeningStatsStore? = nil,
        eqStore: EQPresetStore = .shared
    ) {
        self.engine = engine
        self.sourceResolver = sourceResolver
        self.artworkCache = artworkCache
        self.lyricsService = lyricsService
        self.statsStore = statsStore ?? ListeningStatsStore()
        self.eqStore = eqStore

        engine.onTrackDidFinish = { [weak self] in
            Task { @MainActor [weak self] in self?.handleTrackFinished() }
        }

        // Sync engine crossfade settings from UserDefaults immediately and on change.
        syncEngineSettings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.syncEngineSettings() }

        setupRemoteCommandCenter()
    }

    // MARK: - Playback commands
    func play() {
        guard let track = queue.currentTrack else { return }
        Task { await resolveAndPlay(track: track) }
    }

    func pause() {
        if currentPathIsAppleMusic {
            musicPlayer.pause()
        } else if currentPathIsStream {
            streamPlayer.pause()
        } else {
            engine.activePlayer.pause()
        }
        state.status = .paused
        updateNowPlayingPlaybackRate(0)
    }

    func togglePlayPause() {
        switch state.status {
        case .playing:  pause()
        case .paused:   resumePlayback()
        default:        play()
        }
    }

    func next() {
        queue.moveToNext()
        play()
    }

    func previous() {
        if state.positionSeconds > 3 {
            seek(to: 0)
        } else {
            queue.moveToPrevious()
            play()
        }
    }

    func seek(to seconds: Double) {
        if currentPathIsAppleMusic {
            musicPlayer.playbackTime = seconds
            state.positionSeconds = seconds
        } else if currentPathIsStream {
            streamPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
            state.positionSeconds = seconds
        } else {
            guard let track = queue.currentTrack else { return }
            state.positionSeconds = seconds
            Task { await resolveAndPlay(track: track, startAt: seconds) }
        }
    }

    func setVolume(_ volume: Float) {
        engine.volume = volume
        state.volume = volume
    }

    // MARK: - Queue management (pass-through)
    func enqueue(_ track: Track) { queue.enqueue(track) }
    func enqueue(tracks: [Track], playImmediately: Bool = false) {
        queue.enqueue(tracks: tracks, playImmediately: playImmediately)
        if playImmediately { play() }
    }
    func replace(with tracks: [Track], startAt index: Int = 0) {
        queue.replace(with: tracks, startAt: index)
        play()
    }

    // MARK: - EQ
    func apply(preset: EQPreset) {
        currentEQPreset = preset
        engine.applyEQPreset(preset)
    }

    // MARK: - Settings sync
    private func syncEngineSettings() {
        let defaults = UserDefaults.standard
        engine.crossfadeDuration = defaults.double(forKey: "crossfadeDuration").nonZeroOr(3)
        if let curveRaw = defaults.string(forKey: "crossfadeCurve"),
           let curve = CrossfadeCurve(rawValue: curveRaw) {
            engine.crossfadeCurve = curve
        }
    }

    /// Selects the correct ReplayGain value based on the user preference.
    private func replayGain(for track: Track) -> Float? {
        let mode = UserDefaults.standard.string(forKey: "replayGainMode") ?? "track"
        switch mode {
        case "off":   return nil
        case "album": return track.replayGainAlbum ?? track.replayGainTrack
        default:      return track.replayGainTrack ?? track.replayGainAlbum
        }
    }

    // MARK: - Private helpers
    private func resolveAndPlay(track: Track, startAt seconds: Double = 0) async {
        state.status = .buffering

        // ── Apple Music path (MusicKit / ApplicationMusicPlayer) ──────────────
        if case .appleMusicID(let id) = track.uri {
            await playWithMusicPlayer(track: track, musicItemID: MusicItemID(rawValue: id), startAt: seconds)
            return
        }

        do {
            let url = try await sourceResolver.localURL(for: track)
            let replayGain = replayGain(for: track)

            if url.isFileURL {
                // ── Local file path: AVAudioEngine (gapless, EQ) ──────────────────
                // Falls back to AVPlayer if the engine can't start (e.g. simulator audio HAL issues).
                currentPathIsStream = false
                stopStreamPlayer()
                stopMusicPlayer()
                var usedEngine = false
                if let file = try? AVAudioFile(forReading: url),
                   (try? engine.play(file: file, replayGainDB: replayGain)) != nil {
                    usedEngine = true
                    if seconds > 0 {
                        let sampleRate = file.processingFormat.sampleRate
                        let startSample = AVAudioFramePosition(seconds * sampleRate)
                        engine.activePlayer.stop()
                        await engine.activePlayer.scheduleSegment(file,
                            startingFrame: startSample,
                            frameCount: AVAudioFrameCount(file.length - startSample),
                            at: nil)
                        engine.activePlayer.play()
                    }
                }
                if !usedEngine {
                    // AVAudioEngine unavailable — fall back to AVPlayer for this track
                    currentPathIsStream = true
                    let item = AVPlayerItem(url: url)
                    streamPlayer.replaceCurrentItem(with: item)
                    if seconds > 0 {
                        await streamPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
                    }
                    streamPlayer.play()
                    observeStreamPlayer(track: track)
                }
            } else {
                // ── Remote URL: AVPlayer (HTTP, HLS, Icecast, Subsonic stream) ─────
                currentPathIsStream = true
                stopMusicPlayer()
                engine.stopPlayers()   // keep the engine graph alive; only stop the player nodes
                let item = AVPlayerItem(url: url)
                streamPlayer.replaceCurrentItem(with: item)
                if seconds > 0 {
                    await streamPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
                }
                streamPlayer.play()
                observeStreamPlayer(track: track)
            }

            state.status = .playing
            state.currentTrackID = track.id
            state.durationSeconds = track.durationSeconds
            state.positionSeconds = seconds
            state.nowPlayingTitle = track.title
            state.nowPlayingArtist = track.artist
            state.nowPlayingAlbum = track.album
            updateNowPlayingInfo(track: track)

            let sourcePreset = eqStore.preset(for: track.source)
            apply(preset: sourcePreset)
            startPositionTimer()

            Task { currentLyrics = await lyricsService.lyrics(for: track) }

            if !currentPathIsStream, let next = queue.nextTrack {
                Task { await preScheduleNext(next) }
            }
        } catch {
            state.status = .stopped
        }
    }

    private func observeStreamPlayer(track: Track) {
        streamStatusObservation?.invalidate()
        if let obs = streamObserver {
            streamPlayer.removeTimeObserver(obs)
            streamObserver = nil
        }
        // Watch for stream end — store the returned token so we can remove it correctly.
        if let obs = streamEndObserver { NotificationCenter.default.removeObserver(obs) }
        streamEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: streamPlayer.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTrackFinished() }
        }
        // Stream time updates
        let interval = CMTime(seconds: 0.5, preferredTimescale: 1000)
        streamObserver = streamPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.state.positionSeconds = time.seconds
                // Update duration once known
                if let dur = self.streamPlayer.currentItem?.duration, dur.isNumeric {
                    self.state.durationSeconds = dur.seconds
                }
                self.writeStateToAppGroup()
            }
        }
    }

    private func stopStreamPlayer() {
        streamPlayer.pause()
        streamPlayer.replaceCurrentItem(with: nil)
        streamStatusObservation?.invalidate()
        streamStatusObservation = nil
        if let obs = streamObserver { streamPlayer.removeTimeObserver(obs) }
        streamObserver = nil
        if let obs = streamEndObserver { NotificationCenter.default.removeObserver(obs) }
        streamEndObserver = nil
    }

    // MARK: - Apple Music playback

    private func stopMusicPlayer() {
        guard currentPathIsAppleMusic else { return }
        musicPlayer.stop()
        musicPlayerSubscription?.cancel()
        musicPlayerSubscription = nil
        currentPathIsAppleMusic = false
    }

    private func playWithMusicPlayer(track: Track, musicItemID: MusicItemID, startAt seconds: Double) async {
        stopStreamPlayer()
        engine.stopPlayers()
        currentPathIsStream = false
        currentPathIsAppleMusic = true

        do {
            guard let song = try await AppleMusicService.song(for: musicItemID) else {
                state.status = .stopped; return
            }
            musicPlayer.queue = [song]
            if seconds > 0 { musicPlayer.playbackTime = seconds }
            try await musicPlayer.play()
            // Cache artwork while we have the Song object.
            let artKey = "applemusic:\(musicItemID.rawValue)"
            Task { await AppleMusicService.cacheArtwork(for: song, key: artKey) }
        } catch {
            state.status = .stopped; return
        }

        state.status = .playing
        state.currentTrackID = track.id
        state.durationSeconds = track.durationSeconds
        state.positionSeconds = seconds
        state.nowPlayingTitle = track.title
        state.nowPlayingArtist = track.artist
        state.nowPlayingAlbum = track.album
        updateNowPlayingInfo(track: track)
        startPositionTimer()

        // Observe MusicPlayer state so we can sync pause/stop changes back to PlaybackState.
        musicPlayerSubscription = musicPlayer.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.currentPathIsAppleMusic else { return }
                switch self.musicPlayer.state.playbackStatus {
                case .playing:  self.state.status = .playing
                case .paused:   self.state.status = .paused
                case .stopped, .interrupted: self.state.status = .stopped
                default: break
                }
            }
    }

    private func preScheduleNext(_ track: Track) async {
        guard let url = try? await sourceResolver.localURL(for: track),
              let file = try? AVAudioFile(forReading: url) else { return }
        engine.scheduleNext(file: file)
    }

    private func resumePlayback() {
        if currentPathIsAppleMusic {
            Task { try? await musicPlayer.play() }
        } else if currentPathIsStream {
            streamPlayer.play()
        } else {
            engine.activePlayer.play()
        }
        state.status = .playing
        updateNowPlayingPlaybackRate(1)
    }

    private func handleTrackFinished() {
        if let track = queue.currentTrack {
            statsStore.record(played: track)
        }
        if queue.repeatMode == .one {
            play()
        } else if queue.nextIndex != nil {
            if currentPathIsStream {
                // AVPlayer can't gapless-crossfade; just start the next item.
                queue.moveToNext()
                play()
            } else {
                // Local file: hand off to the pre-scheduled staging player (gapless/crossfade).
                engine.transition(crossfade: engine.crossfadeDuration > 0)
                queue.moveToNext()
                state.status = .playing
                if let track = queue.currentTrack {
                    state.currentTrackID = track.id
                    state.durationSeconds = track.durationSeconds
                    state.positionSeconds = 0
                    updateNowPlayingInfo(track: track)
                    Task { currentLyrics = await lyricsService.lyrics(for: track) }
                    if let next = queue.nextTrack { Task { await preScheduleNext(next) } }
                }
            }
        } else {
            state.status = .stopped
            stopPositionTimer()
        }
    }

    // MARK: - Position timer
    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tickPosition() }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func tickPosition() {
        guard !currentPathIsStream else { return }  // stream uses periodic observer
        guard let nodeTime = engine.activePlayer.lastRenderTime,
              let playerTime = engine.activePlayer.playerTime(forNodeTime: nodeTime),
              let format = queue.currentTrack.map({ _ in engine.activePlayer.outputFormat(forBus: 0) }) else { return }
        let seconds = Double(playerTime.sampleTime) / format.sampleRate
        state.positionSeconds = seconds
        writeStateToAppGroup()
    }

    // MARK: - Now Playing Info Center
    private func updateNowPlayingInfo(track: Track) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle:            track.title,
            MPMediaItemPropertyArtist:           track.artist,
            MPMediaItemPropertyAlbumTitle:       track.album,
            MPMediaItemPropertyPlaybackDuration: track.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue
        ]
        if let artKey = track.artworkCacheKey,
           let image = artworkCache.gridImage(forKey: artKey) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func updateNowPlayingPlaybackRate(_ rate: Float) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.positionSeconds
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Command Center
    private func setupRemoteCommandCenter() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget    { [weak self] _ in self?.togglePlayPause(); return .success }
        cc.pauseCommand.addTarget   { [weak self] _ in self?.togglePlayPause(); return .success }
        cc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
            }
            return .success
        }
    }

    // MARK: - App Group state (for widget)
    private func writeStateToAppGroup() {
        let defaults = UserDefaults(suiteName: "group.net.mohome.loudmouth")
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(state) {
            defaults?.set(data, forKey: "playerState")
        }
    }
}
