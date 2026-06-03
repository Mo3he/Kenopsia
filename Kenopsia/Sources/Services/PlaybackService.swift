import AVFoundation
import CoreMedia
import MediaPlayer
import MusicKit
import Combine

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
    // Monotonically incremented each time a new stream end observer is registered
    // or the stream is stopped. The observer closure captures its generation and
    // bails if it no longer matches, preventing stale notifications from firing
    // handleTrackFinished() after manual navigation has already advanced the queue.
    private var streamEndGeneration: Int = 0

    // MARK: - Apple Music player
    // Lazy so ApplicationMusicPlayer.shared is never touched when no Apple Music
    // tracks are present, preventing spurious daemon connection timeouts.
    private lazy var musicPlayer = ApplicationMusicPlayer.shared
    private var musicPlayerSubscription: AnyCancellable?
    private var currentPathIsAppleMusic = false

    // MARK: - Internal
    private var positionTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var currentPathIsStream = false
    private var currentPathIsCast = false
    private var settingsObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    /// Seek offset for the AVAudioEngine path. AVAudioPlayerNode.sampleTime resets to 0
    /// whenever a new segment is scheduled, so we add this offset to get the file position.
    private var positionOffset: Double = 0
    /// The ID of the track most recently committed to hardware playback.
    /// handleTrackFinished() uses this to detect stale completion callbacks
    /// that fire after the user has already manually navigated to a new track.
    private var playingTrackID: Track.ID?
    /// Incremented every time play() is initiated. Stale gapless-transition callbacks
    /// compare against this to detect if the user navigated while the callback was in flight.
    private var playGeneration: Int = 0
    /// Set to true while handleTrackFinished is actively advancing the queue.
    /// Prevents re-entrant calls from the position-timer safety net.
    private var isAdvancingTrack = false
    /// Tracks stalled playback: last position value observed by tickPosition.
    private var lastObservedPosition: Double = -1
    /// How many consecutive timer ticks the position hasn't advanced.
    private var stallTickCount: Int = 0
    /// The playGeneration at the time the current track started. If playGeneration
    /// differs when a gapless callback arrives, a manual navigation happened.
    private var gaplessExpectedGeneration: Int = 0
    /// Throttle: last time we wrote state to the App Group container.
    private var lastAppGroupWriteDate: Date = .distantPast
    /// Set when the position timer triggers an early crossfade for the current track.
    /// Prevents re-triggering on subsequent timer ticks.
    private var crossfadeTriggeredForCurrentTrack = false
    /// The in-flight resolveAndPlay task. Cancelled when a new play() is issued
    /// so stale resolves never overwrite newer playback.
    private var playTask: Task<Void, Never>?
    // MARK: - Init
    init(
        engine: AudioEngine = AudioEngine(),
        sourceResolver: SourceResolver = .shared,
        artworkCache: ArtworkCache = ArtworkCache.shared,
        lyricsService: LyricsService = LyricsService(),
        statsStore: ListeningStatsStore? = nil,
        eqStore: EQPresetStore = .shared
    ) {
        self.engine = engine
        self.sourceResolver = sourceResolver
        self.artworkCache = artworkCache
        self.lyricsService = lyricsService
        self.statsStore = statsStore ?? ListeningStatsStore.shared
        self.eqStore = eqStore

        // Activate the .playback audio session up front. AVAudioEngine.start()
        // does this for local files, but the AVPlayer stream path (DLNA, NAS,
        // Subsonic, B2) never starts the engine — without this call the first
        // streamed track plays silently under the default .soloAmbient category.
        engine.configureAudioSession()

        // Sweep any temp stream files left over from previous sessions. Without
        // this, downloaded remote tracks accumulate in /tmp indefinitely.
        Task.detached(priority: .utility) { Self.purgeStreamTempFiles() }

        engine.onTrackDidFinish = { [weak self] in
            Task { @MainActor [weak self] in self?.handleTrackFinished() }
        }

        engine.onGaplessTransitionDidComplete = { [weak self] in
            Task { @MainActor [weak self] in self?.handleGaplessTransitionComplete() }
        }

        // Pre-schedule the next-next track once a crossfade finishes and the old
        // (fading-out) player has fully stopped and is free to be reused as staging.
        engine.onCrossfadeCompleted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, let next = self.queue.nextTrack else { return }
                await self.preScheduleNext(next)
            }
        }

        engine.onEngineConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in self?.handleEngineConfigChange() }
        }

        // Sync engine crossfade settings from UserDefaults immediately and on change.
        syncEngineSettings()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.syncEngineSettings() } }

        setupRemoteCommandCenter()
        setupInterruptionHandling()

        // Persist queue whenever shuffle/repeat/tracks change (debounced via objectWillChange).
        queue.objectWillChange
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.writeStateToAppGroupNow() }
            .store(in: &cancellables)

        // Restore persisted queue so the user can resume where they left off.
        restoreQueue()

        // React to Chromecast session lifecycle: auto-cast on connect, resume local on disconnect.
        ChromecastService.shared.$isCasting
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .dropFirst()   // ignore the initial false emitted at subscription time
            .sink { [weak self] isCasting in
                guard let self else { return }
                if isCasting {
                    self.handleCastSessionStarted()
                } else {
                    // Capture position before ChromecastService resets it to 0.
                    let lastPos = ChromecastService.shared.castPositionSeconds
                    self.handleCastSessionEnded(resumeFrom: lastPos)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Playback commands
    func play() {
        guard let track = queue.currentTrack else { return }
        playGeneration += 1
        stallTickCount = 0
        lastObservedPosition = -1
        crossfadeTriggeredForCurrentTrack = false
        playTask?.cancel()
        // Re-check isCasting so non-DRM tracks route to Cast even after an Apple Music
        // track played locally (which temporarily sets currentPathIsCast = false).
        if currentPathIsCast || ChromecastService.shared.isCasting {
            currentPathIsCast = true
            playTask = Task { await self.castCurrentTrack(track: track) }
        } else {
            playTask = Task { await resolveAndPlay(track: track) }
        }
    }

    func pause() {
        if currentPathIsCast {
            ChromecastService.shared.pause()
        } else if currentPathIsAppleMusic {
            musicPlayer.pause()
        } else if currentPathIsStream {
            streamPlayer.pause()
        } else {
            engine.activePlayer.pause()
        }
        state.status = .paused
        updateNowPlayingPlaybackRate(0)
    }

    func stop() {
        engine.stopPlayers()
        stopStreamPlayer()
        stopMusicPlayer()
        if currentPathIsCast {
            ChromecastService.shared.stop()
            currentPathIsCast = false
            Task { await CastHTTPServer.shared.stop() }
        }
        stopPositionTimer()
        state.status = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        writeStateToAppGroupNow()
    }

    func togglePlayPause() {
        switch state.status {
        case .playing:  pause()
        case .paused:   resumePlayback()
        default:        play()
        }
    }

    func next() {
        guard queue.nextIndex != nil else {
            state.status = .stopped
            stopPositionTimer()
            return
        }
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
        if currentPathIsCast {
            ChromecastService.shared.seek(to: seconds)
            state.positionSeconds = seconds
            updateNowPlayingPlaybackRate(state.status == .playing ? 1 : 0)
            return
        } else if currentPathIsAppleMusic {
            musicPlayer.playbackTime = seconds
            state.positionSeconds = seconds
        } else if currentPathIsStream {
            streamPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
            state.positionSeconds = seconds
        } else {
            guard let track = queue.currentTrack else { return }
            state.positionSeconds = seconds
            positionOffset = seconds
            Task {
                guard let url = try? await sourceResolver.localURL(for: track),
                      url.isFileURL,
                      let file = try? AVAudioFile(forReading: url) else { return }
                engine.seekActivePlayer(to: seconds, in: file)
            }
        }
        updateNowPlayingPlaybackRate(state.status == .playing ? 1 : 0)
    }

    func setVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        if currentPathIsCast {
            ChromecastService.shared.setVolume(clamped)
            state.volume = clamped
            return
        }
        engine.volume = clamped
        streamPlayer.volume = clamped
        // ApplicationMusicPlayer volume is system-controlled; adjust via MPVolumeView.
        state.volume = clamped
    }

    var meterLevels: [Float] { engine.meterLevels }

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
    /// Jump to a specific index in the current queue without replacing it.
    /// Preserves shuffle order and queue state.
    func skipTo(index: Int) {
        guard queue.tracks.indices.contains(index) else { return }
        queue.currentIndex = index
        play()
    }

    // MARK: - EQ
    func apply(preset: EQPreset) {
        currentEQPreset = preset
        engine.applyEQPreset(preset)
        // Persist the assignment so it survives track changes and app restart.
        if let track = queue.currentTrack {
            eqStore.assign(preset: preset, to: track.source)
        }
    }

    // MARK: - Settings sync
    private var lastSyncedCrossfade: Double = -1
    private var lastSyncedCurve: String?

    private func syncEngineSettings() {
        let defaults = UserDefaults.standard
        // If the key has never been set, double(forKey:) returns 0.
        // Treat "never set" as the default crossfade of 3s. Once the user
        // explicitly sets it (even to 0 for true gapless), respect that value.
        let crossfade: Double
        if defaults.object(forKey: "crossfadeDuration") != nil {
            crossfade = defaults.double(forKey: "crossfadeDuration")
        } else {
            crossfade = 3.0
        }
        let curveRaw = defaults.string(forKey: "crossfadeCurve")

        // Skip if nothing changed (avoids spam from unrelated UserDefaults writes).
        guard crossfade != lastSyncedCrossfade || curveRaw != lastSyncedCurve else { return }
        lastSyncedCrossfade = crossfade
        lastSyncedCurve = curveRaw

        engine.crossfadeDuration = crossfade
        if let curveRaw, let curve = CrossfadeCurve(rawValue: curveRaw) {
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

    /// Creates an AVURLAsset for a remote URL. If the URL contains an `Authorization`
    /// query parameter (e.g. from Backblaze B2 private buckets), strips it from the URL
    /// and injects it as an HTTP header so it doesn't appear in caches or logs.
    private func makeAVAssetExtractingAuth(from url: URL) -> AVURLAsset {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var queryItems = comps.queryItems,
              let idx = queryItems.firstIndex(where: { $0.name == "Authorization" }),
              let token = queryItems[idx].value else {
            return AVURLAsset(url: url)
        }
        queryItems.remove(at: idx)
        comps.queryItems = queryItems.isEmpty ? nil : queryItems
        let cleanURL = comps.url ?? url
        // "AVURLAssetHTTPHeaderFieldsKey" is the stable ObjC string underlying the Swift
        // constant (which has import scoping issues in some SDK configurations).
        return AVURLAsset(url: cleanURL, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": token]])
    }

    /// Prefix used for all temp files created by downloadToTemp. Used by the
    /// startup sweep so we don't accidentally delete other apps' temp files.
    private nonisolated static let streamTempPrefix = "kenopsia_stream_"

    /// Downloads a remote audio file to a temporary location so it can be opened by
    /// AVAudioFile and played through AVAudioEngine (enabling EQ and spectrum metering).
    /// Returns nil if the download fails or is cancelled.
    /// Streams to disk via URLSession.download(for:) so memory stays bounded even
    /// for large lossless files.
    private nonisolated func downloadToTemp(url: URL, track: Track) async -> URL? {
        let ext = url.pathExtension.isEmpty ? (track.format.fileExtension) : url.pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.streamTempPrefix)\(track.id.uuidString).\(ext)")
        // If already downloaded (e.g. seeking back in same track), reuse it.
        if FileManager.default.fileExists(atPath: tempURL.path) { return tempURL }
        do {
            var request = URLRequest(url: url)
            // Extract Authorization from query params if present (B2 private buckets).
            if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
               let items = comps.queryItems,
               let authIdx = items.firstIndex(where: { $0.name == "Authorization" }),
               let token = items[authIdx].value {
                var filtered = items; filtered.remove(at: authIdx)
                comps.queryItems = filtered.isEmpty ? nil : filtered
                request.url = comps.url ?? url
                request.setValue(token, forHTTPHeaderField: "Authorization")
            }
            let (downloadedURL, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: downloadedURL)
                return nil
            }
            // Move the downloaded file (typically in /tmp/CFNetworkDownload_*) to our
            // stable temp path. Replace any existing item at the destination.
            if FileManager.default.fileExists(atPath: tempURL.path) {
                try? FileManager.default.removeItem(at: tempURL)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }

    /// Deletes every temp stream file produced by downloadToTemp. Called on init
    /// so we don't leak megabytes after each launch.
    private nonisolated static func purgeStreamTempFiles() {
        let tmp = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(streamTempPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Private helpers
    private func resolveAndPlay(track: Track, startAt seconds: Double = 0) async {
        state.status = .buffering

        // Stop ALL backends immediately so old audio never bleeds through while
        // we await URL resolution. Each backend is idempotent to double-stop.
        engine.stopPlayers()
        stopStreamPlayer()
        stopMusicPlayer()
        streamEndGeneration += 1   // invalidate any queued stream-end notification

        // ── Apple Music path (MusicKit / ApplicationMusicPlayer) ──────────────
        if case .appleMusicID(let id) = track.uri {
            await playWithMusicPlayer(track: track, musicItemID: MusicItemID(rawValue: id), startAt: seconds)
            return
        }

        do {
            let url = try await sourceResolver.localURL(for: track)
            // If a newer play() was issued while we awaited, abandon this stale resolve.
            guard !Task.isCancelled else { return }
            let replayGain = replayGain(for: track)

            if url.isFileURL {
                // ── Local file path: AVAudioEngine (gapless, EQ) ──────────────────
                // Falls back to AVPlayer if the engine can't start (e.g. simulator audio HAL issues).
                currentPathIsStream = false
                currentPathIsAppleMusic = false
                positionOffset = seconds
                var usedEngine = false
                if let file = try? AVAudioFile(forReading: url),
                   (try? engine.play(file: file, replayGainDB: replayGain)) != nil {
                    usedEngine = true
                    if seconds > 0 {
                        engine.seekActivePlayer(to: seconds, in: file)
                    }
                }
                if !usedEngine {
                    // AVAudioEngine unavailable — fall back to AVPlayer for this track
                    currentPathIsStream = true
                    let item = AVPlayerItem(url: url)
                    streamPlayer.replaceCurrentItem(with: item)
                    streamPlayer.volume = state.volume
                    if seconds > 0 {
                        await streamPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
                    }
                    streamPlayer.play()
                    observeStreamPlayer(track: track)
                }
            } else {
                // ── Remote URL: finite audio files (DLNA, Subsonic, B2) get downloaded
                //    to a temp file so they play through AVAudioEngine with full EQ and
                //    spectrum metering. Live streams (web radio) go direct to AVPlayer.
                let isLiveStream: Bool
                if case .webRadio = track.uri { isLiveStream = true }
                else { isLiveStream = false }

                if !isLiveStream, let tempFile = await downloadToTemp(url: url, track: track) {
                    // Play through AVAudioEngine for EQ + spectrum
                    guard !Task.isCancelled else { return }
                    currentPathIsStream = false
                    currentPathIsAppleMusic = false
                    positionOffset = seconds
                    var usedEngine = false
                    if let file = try? AVAudioFile(forReading: tempFile),
                       (try? engine.play(file: file, replayGainDB: replayGain)) != nil {
                        usedEngine = true
                        if seconds > 0 {
                            engine.seekActivePlayer(to: seconds, in: file)
                        }
                    }
                    if !usedEngine {
                        // Engine failed -- fall back to AVPlayer
                        currentPathIsStream = true
                        let item = AVPlayerItem(url: tempFile)
                        streamPlayer.replaceCurrentItem(with: item)
                        streamPlayer.volume = state.volume
                        if seconds > 0 {
                            await streamPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
                        }
                        streamPlayer.play()
                        observeStreamPlayer(track: track)
                    }
                } else {
                    // Live stream or download failed -- use AVPlayer directly
                    guard !Task.isCancelled else { return }
                    currentPathIsStream = true
                    currentPathIsAppleMusic = false
                    let asset = makeAVAssetExtractingAuth(from: url)
                    let item = AVPlayerItem(asset: asset)
                    streamPlayer.replaceCurrentItem(with: item)
                    streamPlayer.volume = state.volume
                    if seconds > 0 {
                        await streamPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000))
                    }
                    streamPlayer.play()
                    observeStreamPlayer(track: track)
                }
            }

            // Final cancellation check before committing state. If a newer play()
            // was issued and already set up its own playback, don't overwrite it.
            guard !Task.isCancelled else { return }

            state.status = .playing
            playingTrackID = track.id
            gaplessExpectedGeneration = playGeneration
            state.currentTrackID = track.id
            state.durationSeconds = track.durationSeconds
            state.positionSeconds = seconds
            state.nowPlayingTitle = track.title
            state.nowPlayingArtist = track.artist
            state.nowPlayingAlbum = track.album
            state.nowPlayingArtworkCacheKey = track.artworkCacheKey
            updateNowPlayingInfo(track: track)

            // Fetch artwork asynchronously if not already cached; update Now Playing once available
            Task {
                if let key = await ArtworkFetchService.shared.fetchIfNeeded(for: track) {
                    state.nowPlayingArtworkCacheKey = key
                    // Refresh lock screen artwork now that it's been fetched
                    if state.currentTrackID == track.id {
                        updateNowPlayingInfo(track: track, artworkKey: key)
                    }
                }
            }

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
        // Watch for stream end — use a generation counter so stale end notifications
        // (e.g. from a track that ended while we were awaiting a URL) are ignored.
        if let obs = streamEndObserver { NotificationCenter.default.removeObserver(obs) }
        streamEndGeneration += 1
        let capturedGen = streamEndGeneration
        streamEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: streamPlayer.currentItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.streamEndGeneration == capturedGen else { return }
                self.handleTrackFinished()
            }
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
        streamEndGeneration += 1   // invalidate any pending stream-end notification
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
        currentPathIsStream = false
        currentPathIsAppleMusic = true

        do {
            guard let song = try await AppleMusicService.song(for: musicItemID) else {
                state.status = .stopped; return
            }
            guard !Task.isCancelled else { return }
            musicPlayer.queue = [song]
            if seconds > 0 { musicPlayer.playbackTime = seconds }
            try await musicPlayer.play()
            guard !Task.isCancelled else { return }
            // Cache artwork while we have the Song object.
            let artKey = "applemusic:\(musicItemID.rawValue)"
            Task { await AppleMusicService.cacheArtwork(for: song, key: artKey) }
        } catch {
            state.status = .stopped; return
        }

        state.status = .playing
        playingTrackID = track.id
        gaplessExpectedGeneration = playGeneration
        state.currentTrackID = track.id
        state.durationSeconds = track.durationSeconds
        state.positionSeconds = seconds
        state.nowPlayingTitle = track.title
        state.nowPlayingArtist = track.artist
        state.nowPlayingAlbum = track.album
        state.nowPlayingArtworkCacheKey = track.artworkCacheKey
        updateNowPlayingInfo(track: track)
        startPositionTimer()

        // Observe MusicPlayer state so we can sync pause/stop changes back to PlaybackState.
        musicPlayerSubscription = musicPlayer.state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.currentPathIsAppleMusic else { return }
                let status = self.musicPlayer.state.playbackStatus
                switch status {
                case .playing:  self.state.status = .playing
                case .paused:
                    // ApplicationMusicPlayer reports .paused (not .stopped) when a
                    // track finishes naturally. Distinguish from a real user-pause by
                    // checking whether playback reached the end of the track.
                    let pos = self.musicPlayer.playbackTime
                    let dur = self.state.durationSeconds
                    if dur > 0, pos >= dur - 1.5 {
                        self.handleTrackFinished()
                    } else if pos < 0.5, dur > 0 {
                        // Position resets to ~0 when track ends on some iOS versions
                        self.handleTrackFinished()
                    } else {
                        self.state.status = .paused
                    }
                case .stopped, .interrupted:
                    self.handleTrackFinished()
                default: break
                }
            }
    }

    private func preScheduleNext(_ track: Track) async {
        PLog.scheduler.debug("preScheduleNext: start '\(track.title, privacy: .public)'")
        guard let url = try? await sourceResolver.localURL(for: track),
              url.isFileURL,
              let file = try? AVAudioFile(forReading: url) else {
            PLog.scheduler.warning("preScheduleNext: BAIL — failed to resolve/open file for '\(track.title, privacy: .public)'")
            return
        }
        // Only schedule if we're still on the engine path and the track we're
        // pre-scheduling for is still the actual next track. If a transition
        // happened while we were resolving the URL, the player slots have
        // swapped and scheduling now would corrupt the active player.
        guard !currentPathIsStream, !currentPathIsAppleMusic, !currentPathIsCast,
              queue.nextTrack?.id == track.id else {
            PLog.scheduler.warning("preScheduleNext: BAIL — guard failed (stream=\(self.currentPathIsStream, privacy: .public) appleMusic=\(self.currentPathIsAppleMusic, privacy: .public) cast=\(self.currentPathIsCast, privacy: .public) nextTrackMatch=\(self.queue.nextTrack?.id == track.id, privacy: .public)) for '\(track.title, privacy: .public)'")
            return
        }
        PLog.scheduler.debug("preScheduleNext: calling scheduleNext for '\(track.title, privacy: .public)'")
        engine.scheduleNext(file: file)
    }

    // MARK: - Cast session lifecycle

    /// Called when a Cast session becomes active. Stops local playback and
    /// begins casting the current track to the connected device.
    private func handleCastSessionStarted() {
        // Apple Music tracks are DRM-protected and cannot be cast.
        // If that's what's playing, leave it running locally and do nothing else.
        if let track = queue.currentTrack, case .appleMusicID = track.uri {
            return
        }
        engine.stopPlayers()
        stopStreamPlayer()
        stopMusicPlayer()
        currentPathIsCast = true
        guard let track = queue.currentTrack else { return }
        let resumeAt = state.positionSeconds
        playGeneration += 1
        playTask?.cancel()
        playTask = Task { await self.castCurrentTrack(track: track, startAt: resumeAt) }
    }

    /// Called when the Cast session ends (user disconnects or session drops).
    /// Resumes local playback from the last known cast position.
    private func handleCastSessionEnded(resumeFrom seconds: Double) {
        guard currentPathIsCast else { return }
        currentPathIsCast = false
        Task { await CastHTTPServer.shared.stop() }
        guard state.status == .playing, let track = queue.currentTrack else { return }
        playGeneration += 1
        playTask?.cancel()
        state.positionSeconds = seconds
        positionOffset = seconds
        playTask = Task { await resolveAndPlay(track: track, startAt: seconds) }
    }

    /// Resolves the stream URL for `track` and loads it onto the Chromecast receiver.
    /// For local files, starts the CastHTTPServer and registers the file so the
    /// Chromecast can pull it over the local network. Apple Music tracks (DRM) are
    /// unsupported and result in a stopped state.
    private func castCurrentTrack(track: Track, startAt seconds: Double = 0) async {
        print("[Cast] castCurrentTrack: '\(track.title)' at \(seconds)s")
        state.status = .buffering

        // Apple Music tracks are DRM-protected and cannot be streamed to Chromecast.
        // Fall back to local Apple Music playback for this track.
        if case .appleMusicID = track.uri {
            print("[Cast] Track is Apple Music DRM — falling back to local Apple Music")
            currentPathIsCast = false
            await resolveAndPlay(track: track, startAt: seconds)
            return
        }

        do {
            let url = try await sourceResolver.localURL(for: track)
            print("[Cast] Resolved URL: \(url)")
            guard !Task.isCancelled else { return }

            let castURL: URL
            if url.isFileURL {
                await CastHTTPServer.shared.start()
                guard let httpURL = await CastHTTPServer.shared.register(
                    fileURL: url,
                    trackID: track.id,
                    format: track.format
                ) else {
                    print("[Cast] HTTP server register returned nil (no local IP?)")
                    state.status = .stopped; return
                }
                castURL = httpURL
            } else {
                castURL = url
            }

            guard !Task.isCancelled else { return }

            let castSucceeded = ChromecastService.shared.cast(track: track, streamURL: castURL)

            guard castSucceeded else {
                print("[Cast] cast() returned false — remoteClient nil. Falling back to local.")
                // remoteClient wasn't ready yet; fall back to local playback.
                currentPathIsCast = false
                Task { await CastHTTPServer.shared.stop() }
                await resolveAndPlay(track: track, startAt: seconds)
                return
            }

            print("[Cast] Cast started successfully")
            state.status = .playing
            playingTrackID = track.id
            state.currentTrackID = track.id
            state.durationSeconds = track.durationSeconds
            state.positionSeconds = seconds
            state.nowPlayingTitle = track.title
            state.nowPlayingArtist = track.artist
            state.nowPlayingAlbum = track.album
            state.nowPlayingArtworkCacheKey = track.artworkCacheKey
            updateNowPlayingInfo(track: track)
            startPositionTimer()
            Task { currentLyrics = await lyricsService.lyrics(for: track) }
        } catch {
            state.status = .stopped
        }
    }

    private func resumePlayback() {
        if currentPathIsCast {
            ChromecastService.shared.resume()
        } else if currentPathIsAppleMusic {
            Task { try? await musicPlayer.play() }
        } else if currentPathIsStream {
            streamPlayer.play()
        } else {
            // Fast path: if the engine is running and the player is still connected,
            // a simple play() call on the paused node resumes instantly.
            if engine.isActivePlayerConnected {
                engine.activePlayer.play()
            } else {
                // Engine was stopped (route change, interruption) — do a full play()
                // which re-resolves the file and restarts the engine.
                play()
                return
            }
        }
        state.status = .playing
        updateNowPlayingPlaybackRate(1)
    }

    private func handleTrackFinished() {
        // Prevent re-entrant calls (position-timer safety net + completion callback).
        guard !isAdvancingTrack else {
            PLog.service.debug("handleTrackFinished: skipped — isAdvancingTrack=true")
            return
        }
        // Discard stale callbacks: if the user manually navigated to a different
        // track (next/previous/queue-tap), playingTrackID will no longer match the
        // queue's current track. The real play() call will handle state correctly.
        guard queue.currentTrack?.id == playingTrackID else {
            PLog.service.debug("handleTrackFinished: skipped — trackID mismatch (current=\(self.queue.currentTrack?.title ?? "nil", privacy: .public) playing=\(self.playingTrackID?.uuidString ?? "nil", privacy: .public))")
            return
        }
        PLog.service.debug("handleTrackFinished: advancing from '\(self.queue.currentTrack?.title ?? "?", privacy: .public)' stagingReady=\(self.engine.stagingIsReady, privacy: .public) xfade=\(self.engine.crossfadeDuration, privacy: .public)s")
        isAdvancingTrack = true
        defer { isAdvancingTrack = false }
        crossfadeTriggeredForCurrentTrack = false
        if let track = queue.currentTrack {
            statsStore.record(played: track)
        }
        if queue.repeatMode == .one {
            play()
        } else if queue.nextIndex != nil {
            if currentPathIsCast || currentPathIsStream || currentPathIsAppleMusic {
                // Streams and Apple Music tracks can't use gapless engine handoff;
                // just advance the index and call play() to start the next item.
                queue.moveToNext()
                play()
            } else {
                // Local file: attempt gapless handoff to the pre-scheduled staging player.
                // For crossfade: set the incoming track's ReplayGain BEFORE the transition
                // so crossfadeToStaging uses the correct target volume for the new track.
                if engine.crossfadeDuration > 0, let nextTrack = queue.nextTrack {
                    let nextGain = replayGain(for: nextTrack)
                    engine.preparePendingReplayGain(nextGain)
                }
                let transitioned = engine.transition(crossfade: engine.crossfadeDuration > 0)
                queue.moveToNext()
                if !transitioned {
                    // Staging player had nothing queued (preScheduleNext failed).
                    // Fall back to a full resolve-and-play for the next track.
                    PLog.service.warning("handleTrackFinished: transition failed — calling play() fallback for '\(self.queue.currentTrack?.title ?? "?", privacy: .public)'")
                    play()
                    return
                }
                state.status = .playing
                PLog.service.debug("handleTrackFinished: transition OK → '\(self.queue.currentTrack?.title ?? "?", privacy: .public)'")
                if let track = queue.currentTrack {
                    playingTrackID = track.id   // update so the next completion is accepted
                    gaplessExpectedGeneration = playGeneration
                    // For gapless (no crossfade): apply ReplayGain immediately so the new
                    // active player plays at the right volume from the first sample.
                    // For crossfade: the ramp's final asyncAfter step applies
                    // pendingActivePlayerVolume. Calling applyReplayGain here would
                    // immediately set the volume to the target, then the first ramp step
                    // (i=0, fires on the next run-loop tick) resets it back to fadeIn(0)=0,
                    // making the new track briefly loud then silent — no audible crossfade.
                    if engine.crossfadeDuration == 0 {
                        let rg = UserDefaults.standard.string(forKey: "replayGainMode") == "album"
                            ? (track.replayGainAlbum ?? track.replayGainTrack)
                            : track.replayGainTrack
                        engine.applyReplayGain(rg)
                    }
                    state.currentTrackID = track.id
                    state.durationSeconds = track.durationSeconds
                    state.positionSeconds = 0
                    state.nowPlayingTitle = track.title
                    state.nowPlayingArtist = track.artist
                    state.nowPlayingAlbum = track.album
                    state.nowPlayingArtworkCacheKey = track.artworkCacheKey
                    positionOffset = 0
                    updateNowPlayingInfo(track: track)
                    writeStateToAppGroupNow()
                    Task { currentLyrics = await lyricsService.lyrics(for: track) }
                    Task {
                        if let key = await ArtworkFetchService.shared.fetchIfNeeded(for: track) {
                            state.nowPlayingArtworkCacheKey = key
                            if state.currentTrackID == track.id {
                                updateNowPlayingInfo(track: track, artworkKey: key)
                            }
                        }
                    }
                    // For gapless: pre-schedule the next-next track immediately — the old
                    // player is already stopped so scheduleNext() can reuse it safely.
                    // For crossfade: the old player is still fading out. Pre-scheduling now
                    // would call stagingPlayer.stop() on the fading player, killing the fade.
                    // Instead, onCrossfadeCompleted fires when the ramp finishes and the old
                    // player has stopped, then pre-schedules from there.
                    if engine.crossfadeDuration == 0 {
                        if let next = queue.nextTrack { Task { await preScheduleNext(next) } }
                    }
                }
            }
        } else {
            state.status = .stopped
            stopPositionTimer()
        }
    }

    /// Called when the AudioEngine already performed a gapless player swap in its
    /// completion callback (on the audio thread) to avoid the main-actor hop latency.
    /// We just need to advance the queue and update metadata here.
    private func handleGaplessTransitionComplete() {
        // If play() was called manually between the engine swap and this handler
        // executing on the main actor, this callback is stale. Discard it.
        guard gaplessExpectedGeneration == playGeneration else {
            PLog.service.debug("handleGaplessTransitionComplete: stale (gen \(self.gaplessExpectedGeneration, privacy: .public) != play \(self.playGeneration, privacy: .public))")
            return
        }
        guard queue.currentTrack?.id == playingTrackID else {
            PLog.service.debug("handleGaplessTransitionComplete: stale (trackID mismatch)")
            return
        }
        PLog.service.debug("handleGaplessTransitionComplete: advancing from '\(self.queue.currentTrack?.title ?? "?", privacy: .public)'")
        if let track = queue.currentTrack {
            statsStore.record(played: track)
        }
        if queue.repeatMode == .one {
            // Repeat-one: the engine already transitioned to the same track's file
            // (since nextTrack == currentTrack for repeat-one). Just reset position
            // and pre-schedule the next repeat.
            state.positionSeconds = 0
            positionOffset = 0
            writeStateToAppGroupNow()
            if let next = queue.nextTrack { Task { await preScheduleNext(next) } }
            return
        }
        guard queue.nextIndex != nil else {
            state.status = .stopped
            stopPositionTimer()
            return
        }
        queue.moveToNext()
        state.status = .playing
        stallTickCount = 0
        lastObservedPosition = -1
        crossfadeTriggeredForCurrentTrack = false
        if let track = queue.currentTrack {
            playingTrackID = track.id
            gaplessExpectedGeneration = playGeneration
            let replayGain = UserDefaults.standard.string(forKey: "replayGainMode") == "album"
                ? (track.replayGainAlbum ?? track.replayGainTrack)
                : track.replayGainTrack
            engine.applyReplayGain(replayGain)
            state.currentTrackID = track.id
            state.durationSeconds = track.durationSeconds
            state.positionSeconds = 0
            state.nowPlayingTitle = track.title
            state.nowPlayingArtist = track.artist
            state.nowPlayingAlbum = track.album
            state.nowPlayingArtworkCacheKey = track.artworkCacheKey
            positionOffset = 0
            updateNowPlayingInfo(track: track)
            writeStateToAppGroupNow()
            Task { currentLyrics = await lyricsService.lyrics(for: track) }
            Task {
                if let key = await ArtworkFetchService.shared.fetchIfNeeded(for: track) {
                    state.nowPlayingArtworkCacheKey = key
                    if state.currentTrackID == track.id {
                        updateNowPlayingInfo(track: track, artworkKey: key)
                    }
                }
            }
            if let next = queue.nextTrack { Task { await preScheduleNext(next) } }
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
        // Cast: sync position from ChromecastService's polled media status.
        if currentPathIsCast {
            let pos = ChromecastService.shared.castPositionSeconds
            let dur = ChromecastService.shared.castDurationSeconds
            state.positionSeconds = pos
            if dur > 0 { state.durationSeconds = dur }
            writeStateToAppGroup()
            // Stall-detect end-of-track (same heuristic used for AVAudioEngine path).
            if state.status == .playing, dur > 0, pos >= dur - 0.5 {
                if abs(pos - lastObservedPosition) < 0.01 {
                    stallTickCount += 1
                    if stallTickCount >= 4 {
                        stallTickCount = 0
                        handleTrackFinished()
                    }
                } else {
                    stallTickCount = 0
                }
            }
            lastObservedPosition = pos
            return
        }
        guard !currentPathIsStream else { return }  // stream uses periodic observer
        if currentPathIsAppleMusic {
            let playbackTime = musicPlayer.playbackTime
            let mpState = musicPlayer.state.playbackStatus
            state.positionSeconds = playbackTime
            writeStateToAppGroup()
            // Detect end-of-track for Apple Music: if the player reports stopped/paused
            // and we think we're still playing, the track ended naturally.
            if state.status == .playing {
                if mpState == .stopped || mpState == .interrupted {
                    handleTrackFinished()
                } else if state.durationSeconds > 0, playbackTime >= state.durationSeconds - 0.5 {
                    // Near end - check if position stalled
                    if abs(playbackTime - lastObservedPosition) < 0.01 {
                        stallTickCount += 1
                        if stallTickCount >= 3 {
                            stallTickCount = 0
                            handleTrackFinished()
                        }
                    } else {
                        stallTickCount = 0
                    }
                } else {
                    stallTickCount = 0
                }
                lastObservedPosition = playbackTime
            }
            return
        }
        guard state.status == .playing else {
            stallTickCount = 0
            return
        }
        let player = engine.activePlayer
        guard let nodeTime = player.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else {
            // Player node has no render time — might have finished and stopped.
            // If we're supposedly playing, this is likely end-of-track.
            stallTickCount += 1
            PLog.stall.debug("tickPosition: lastRenderTime nil — stallCount=\(self.stallTickCount, privacy: .public) track='\(self.queue.currentTrack?.title ?? "?", privacy: .public)'")
            if stallTickCount >= 3 {
                PLog.stall.warning("tickPosition: stall limit reached (nil lastRenderTime) — calling handleTrackFinished")
                stallTickCount = 0
                handleTrackFinished()
            }
            return
        }
        let format = player.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        let seconds = Double(playerTime.sampleTime) / format.sampleRate + positionOffset
        state.positionSeconds = seconds
        writeStateToAppGroup()

        // Crossfade trigger: start the crossfade transition N seconds before track end.
        // Only fires once per track (guarded by crossfadeTriggeredForCurrentTrack).
        let xfade = engine.crossfadeDuration
        if !crossfadeTriggeredForCurrentTrack,
           xfade > 0,
           state.durationSeconds > xfade,
           engine.stagingIsReady,
           seconds >= state.durationSeconds - xfade {
            crossfadeTriggeredForCurrentTrack = true
            handleTrackFinished()
            return
        }

        // Safety net: detect end-of-track if the completion callback failed to fire.
        // If position hasn't advanced for multiple timer ticks while we think we're
        // playing, the track has ended and the callback was lost.
        if abs(seconds - lastObservedPosition) < 0.01 {
            stallTickCount += 1
            if stallTickCount >= 3, state.durationSeconds > 0,
               seconds >= state.durationSeconds - 0.5 {
                PLog.stall.warning("tickPosition: stall limit reached (pos stalled at \(seconds, privacy: .public)/\(self.state.durationSeconds, privacy: .public)) — calling handleTrackFinished")
                stallTickCount = 0
                handleTrackFinished()
            }
        } else {
            stallTickCount = 0
        }
        lastObservedPosition = seconds
    }

    // MARK: - Now Playing Info Center
    private func updateNowPlayingInfo(track: Track, artworkKey: String? = nil) {
        // Append to recents the first time we see this track. recordStarted dedupes
        // against the head of the list, so artwork-update re-calls are no-ops.
        statsStore.recordStarted(track)

        var info: [String: Any] = [
            MPMediaItemPropertyTitle:            track.title,
            MPMediaItemPropertyArtist:           track.artist,
            MPMediaItemPropertyAlbumTitle:       track.album,
            MPMediaItemPropertyPlaybackDuration: track.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.positionSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            MPMediaItemPropertyMediaType: MPMediaType.music.rawValue
        ]
        let resolvedKey = artworkKey ?? track.artworkCacheKey
        if let key = resolvedKey {
            // Prefer the full-resolution image for CarPlay / lock screen / Now Playing widget;
            // fall back to grid (300 px) if the full size hasn't been generated yet.
            let largest = artworkCache.fullImage(forKey: key) ?? artworkCache.gridImage(forKey: key)
            if let largest {
                let cache = artworkCache
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: largest.size) { requested in
                    // Return the smallest cached size that satisfies the request to save memory.
                    if max(requested.width, requested.height) <= 64,
                       let thumb = cache.thumbnailImage(forKey: key) { return thumb }
                    if max(requested.width, requested.height) <= 300,
                       let grid = cache.gridImage(forKey: key) { return grid }
                    return largest
                }
            }
        }
        if let albumArtist = Optional(track.albumArtist), !albumArtist.isEmpty {
            info[MPMediaItemPropertyAlbumArtist] = albumArtist
        }
        if let trackNumber = track.trackNumber {
            info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
        }
        if let disc = track.discNumber {
            info[MPMediaItemPropertyDiscNumber] = disc
        }
        if !track.genre.isEmpty {
            info[MPMediaItemPropertyGenre] = track.genre
        }
        let q = queue
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = q.currentIndex
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = q.tracks.count
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = (state.status == .playing) ? .playing : .paused
    }

    private func updateNowPlayingPlaybackRate(_ rate: Float) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.positionSeconds
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // CarPlay (iOS 13+) uses playbackState rather than playbackRate alone
        // to drive the play/pause icon. Mirror it explicitly.
        MPNowPlayingInfoCenter.default().playbackState = (rate > 0) ? .playing : .paused
    }

    // MARK: - Remote Command Center
    private func setupRemoteCommandCenter() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            self?.resumeOrPlay(); return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .success }
            // AirPods and many Bluetooth remotes send pauseCommand for both
            // pause and resume taps. Toggle based on current state so a single
            // gesture works correctly in both directions.
            if self.state.status == .paused {
                self.resumeOrPlay()
            } else {
                self.pause()
            }
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            self?.next(); return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous(); return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                self?.seek(to: e.positionTime)
            }
            return .success
        }
    }

    /// Always resumes or starts playback. Used by the lock screen play command.
    private func resumeOrPlay() {
        if state.status == .paused {
            resumePlayback()
        } else {
            play()
        }
    }

    // MARK: - Engine Configuration Change (Route Switch)
    /// Called when AVAudioEngine restarts after a route change (headphones, AirPlay, etc.).
    /// Player nodes lose their scheduled buffers, so we reschedule from the current position.
    private func handleEngineConfigChange() {
        // Only relevant if we were playing via the engine path.
        guard !currentPathIsStream, !currentPathIsAppleMusic,
              state.status == .playing || state.status == .paused,
              let track = queue.currentTrack else { return }

        let position = state.positionSeconds
        let wasPlaying = state.status == .playing
        Task {
            guard let url = try? await sourceResolver.localURL(for: track),
                  url.isFileURL,
                  let file = try? AVAudioFile(forReading: url) else { return }
            do {
                try engine.resumeActivePlayer(at: position, in: file)
                if !wasPlaying {
                    engine.activePlayer.pause()
                }
            } catch {
                // Engine truly broken -- fall back to AVPlayer for this track
                currentPathIsStream = true
                let item = AVPlayerItem(url: url)
                streamPlayer.replaceCurrentItem(with: item)
                streamPlayer.volume = state.volume
                await streamPlayer.seek(to: CMTime(seconds: position, preferredTimescale: 1000))
                if wasPlaying {
                    streamPlayer.play()
                }
                observeStreamPlayer(track: track)
            }
        }
    }

    // MARK: - Audio Interruption Handling
    private func setupInterruptionHandling() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let info = notification.userInfo,
                      let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

                switch type {
                case .began:
                    // System paused our audio (phone call, Siri, etc.)
                    if self.state.status == .playing {
                        self.state.status = .paused
                        self.updateNowPlayingPlaybackRate(0)
                    }
                case .ended:
                    // Check if we should resume
                    let options = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    if shouldResume && self.state.status == .paused {
                        self.resumePlayback()
                    }
                @unknown default:
                    break
                }
            }
        }
    }

    // MARK: - App Group state (for widget and launch restore)
    private func writeStateToAppGroup() {
        // Throttle: writing the full queue to disk every 500ms causes main-thread
        // hitching for large queues. Only write at most once every 5 seconds for
        // position updates; explicit state changes (track change, stop) call
        // writeStateToAppGroupNow() directly.
        let now = Date()
        guard now.timeIntervalSince(lastAppGroupWriteDate) >= 5.0 else { return }
        writeStateToAppGroupNow()
    }

    private func writeStateToAppGroupNow() {
        lastAppGroupWriteDate = Date()
        let defaults = UserDefaults(suiteName: "group.net.mohome.kenopsia")
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(state) {
            defaults?.set(data, forKey: "playerState")
        }
        if let data = try? encoder.encode(queue) {
            defaults?.set(data, forKey: "playerQueue")
        }
    }

    /// Restores queue from the App Group defaults (called once at launch).
    func restoreQueue() {
        let defaults = UserDefaults(suiteName: "group.net.mohome.kenopsia")
        guard let data = defaults?.data(forKey: "playerQueue"),
              let savedQueue = try? JSONDecoder().decode(Queue.self, from: data) else { return }
        // Replace the entire queue object with the decoded one to preserve
        // shuffledOrder and all other internal state exactly as persisted.
        queue.restore(from: savedQueue)
    }

    // MARK: - Demo / screenshot support
#if DEBUG
    /// Injects a static playback state and queue without triggering audio.
    /// Only used by DemoDataProvider for App Store screenshot automation.
    func setDemoState(_ demoState: PlayerState, queue demoQueue: Queue) {
        stopPositionTimer()
        state = demoState
        queue.replace(with: demoQueue.tracks, startAt: demoQueue.currentIndex)
    }
#endif
}
