import AVFoundation
import MediaPlayer
import Accelerate

// MARK: - AudioEngine
/// Wraps AVAudioEngine to provide:
/// - Gapless playback via double-buffered scheduling
/// - 10-band parametric EQ (AVAudioUnitEQ)
/// - ReplayGain / EBU R128 volume normalisation
/// - Crossfade with configurable curve
///
/// The engine is intentionally not @Observable — callers go through PlaybackService.
final class AudioEngine {
    // MARK: - Engine graph
    private let engine = AVAudioEngine()
    private let playerMixer = AVAudioMixerNode()   // merges both players into a single stream
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let timePitch = AVAudioUnitTimePitch()

    // Two players so we can pre-schedule the next track for gapless transitions.
    private let playerA = AVAudioPlayerNode()
    private let playerB = AVAudioPlayerNode()
    var activePlayer: AVAudioPlayerNode { isUsingPlayerA ? playerA : playerB }
    private var stagingPlayer: AVAudioPlayerNode { isUsingPlayerA ? playerB : playerA }
    private var isUsingPlayerA = true

    /// Serialises access to mutable state shared between the audio-completion thread
    /// and the main thread (stagingIsReady, isUsingPlayerA, nodeGenerations).
    private let lock = NSLock()

    // MARK: - Per-node generation counters
    // Each scheduleFile/scheduleSegment call captures the node's current generation.
    // Before calling stop() we increment the generation, so the captured value in
    // the old closure never matches and the stale callback is silently dropped.
    private var nodeGenerations: [ObjectIdentifier: Int] = [:]

    private func currentGen(for node: AVAudioPlayerNode) -> Int {
        nodeGenerations[ObjectIdentifier(node), default: 0]
    }

    @discardableResult
    private func nextGen(for node: AVAudioPlayerNode) -> Int {
        lock.lock()
        let g = nodeGenerations[ObjectIdentifier(node), default: 0] + 1
        nodeGenerations[ObjectIdentifier(node)] = g
        lock.unlock()
        return g
    }

    private func currentGenLocked(for node: AVAudioPlayerNode) -> Int {
        lock.lock()
        let g = nodeGenerations[ObjectIdentifier(node), default: 0]
        lock.unlock()
        return g
    }

    // MARK: - State
    private(set) var isRunning = false
    private var graphBuilt = false
    /// Whether the active player node is wired into the engine graph and can safely be started.
    var isActivePlayerConnected: Bool {
        isRunning && !engine.outputConnectionPoints(for: activePlayer, outputBus: 0).isEmpty
    }
    /// Tracks whether the staging player has been successfully pre-scheduled.
    /// Set to true in scheduleNext(), cleared in stopPlayers() and transition().
    private(set) var stagingIsReady = false
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue.clamped(to: 0...1) }
    }

    // MARK: - Crossfade
    var crossfadeDuration: TimeInterval = 3.0   // seconds; 0 = gapless, no fade
    var crossfadeCurve: CrossfadeCurve = .equalPower
    // Volume the new active player should reach after a crossfade completes.
    // Set by applyReplayGain(); the crossfade final step reads this so the gain
    // is applied at the moment the fade ends instead of being overwritten by it.
    private var pendingActivePlayerVolume: Float = 1.0
    /// Incremented each time a crossfade starts; stale asyncAfter closures bail out.
    private var crossfadeGeneration: Int = 0

    // MARK: - Init
    init() {
        // Graph is built lazily in start(), after the audio session is active.
        // Building it here (before the session is configured) means nil-format
        // connections have no hardware to negotiate against, so they silently
        // resolve to a null format and nodes end up disconnected on device.
        observeConfigurationChanges()
    }

    // MARK: - Graph construction
    private func buildGraph() {
        guard !graphBuilt else { return }
        engine.attach(playerA)
        engine.attach(playerB)
        engine.attach(playerMixer)
        engine.attach(eq)
        engine.attach(timePitch)

        // Both players feed into a dedicated mixer node so they each get their own
        // input bus. AVAudioUnitEQ only has 1 input bus, so connecting both players
        // directly to it causes the second connection to disconnect the first.
        engine.connect(playerA,    to: playerMixer, format: nil)
        engine.connect(playerB,    to: playerMixer, format: nil)
        engine.connect(playerMixer, to: eq,                   format: nil)
        engine.connect(eq,          to: timePitch,            format: nil)
        engine.connect(timePitch,   to: engine.mainMixerNode, format: nil)
        graphBuilt = true
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        // .allowBluetooth is only valid for .record / .playAndRecord categories.
        // Using it with .playback causes kAudio_ParamError (-50) on device which
        // corrupts the session before the engine starts. Bluetooth output routing
        // for .playback is handled automatically by the system.
        try? session.setCategory(.playback, mode: .default, options: [.allowAirPlay])
        try? session.setActive(true)
    }

    // When the audio route changes (e.g. headphones plugged in, AirPlay switch),
    // AVAudioEngine stops internally. Per Apple docs, the graph connections are
    // preserved — we only need to restart the engine, NOT rebuild the graph.
    // Rebuilding the graph here disconnects the player nodes and causes the
    // 'player started when in a disconnected state' crash.
    // Use the main queue so the handler is serialised with play() calls.
    private func observeConfigurationChanges() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRunning else { return }
            self.isRunning = false
            try? self.start()
            // Notify PlaybackService so it can reschedule the current track.
            self.onEngineConfigurationChange?()
        }
    }

    /// Called when the engine restarts after a configuration change (route switch).
    /// PlaybackService uses this to reschedule the current track from the last known position.
    var onEngineConfigurationChange: (() -> Void)?

    // MARK: - Playback control
    func start() throws {
        guard !isRunning else { return }
        // Configure the audio session first so the hardware format is known,
        // then (re)build the graph so nil-format connections resolve correctly.
        configureAudioSession()
        buildGraph()
        // Remove any stale tap before starting -- if the engine was stopped
        // externally (route change, interruption) the tap reference lingers
        // and installTap will throw on restart.
        if isMeteringInstalled {
            engine.mainMixerNode.removeTap(onBus: 0)
            isMeteringInstalled = false
        }
        try engine.start()
        // engine.start() can succeed without throwing yet leave the engine
        // in a degraded state on device (e.g. audio session still settling).
        // Guard here so callers get a Swift error instead of an NSException.
        guard engine.isRunning else {
            isRunning = false
            throw NSError(domain: AVFoundationErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioEngine failed to start"])
        }
        isRunning = true
        startMetering()
    }

    func stop() {
        stopMetering()
        lock.lock()
        stagingIsReady = false
        lock.unlock()
        nextGen(for: playerA); playerA.stop()
        nextGen(for: playerB); playerB.stop()
        engine.stop()
        isRunning = false
    }

    /// Resume the active player after a pause.
    /// Always checks the *actual* AVAudioEngine.isRunning rather than the
    /// Resume playback by rescheduling `file` from `seconds`.
    /// Always reschedules rather than resuming the paused node, so it is
    /// reliable even when the engine was restarted by a route change or
    /// interruption and the player node's queued audio was cleared.
    func resumeActivePlayer(at seconds: Double, in file: AVAudioFile) throws {
        if !engine.isRunning {
            isRunning = false   // clear stale flag so start() can proceed
            try start()
        }
        guard !engine.outputConnectionPoints(for: activePlayer, outputBus: 0).isEmpty else {
            throw NSError(domain: AVFoundationErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Player node disconnected"])
        }
        let sampleRate = file.processingFormat.sampleRate
        let startSample = AVAudioFramePosition(seconds * sampleRate)
        let remaining = file.length - startSample
        guard remaining > 0 else { return }
        let player = activePlayer
        let gen = nextGen(for: player)
        player.stop()
        player.scheduleSegment(
            file, startingFrame: startSample,
            frameCount: AVAudioFrameCount(remaining), at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self, self.currentGenLocked(for: player) == gen else { return }
            self.handlePlaybackCompletion()
        }
        player.play()
    }

    /// Stop only the player nodes without tearing down the engine graph.
    /// Use this when switching to AVPlayer streaming so the engine stays
    /// connected and doesn't need a full restart when returning to local files.
    func stopPlayers() {
        crossfadeGeneration += 1   // cancel any in-flight crossfade
        lock.lock()
        stagingIsReady = false
        lock.unlock()
        nextGen(for: playerA); playerA.stop()
        nextGen(for: playerB); playerB.stop()
    }

    /// Schedule a file for the active player and start playback.
    func play(file: AVAudioFile, replayGainDB: Float? = nil, at time: AVAudioTime? = nil) throws {
        try ensureRunning()
        // Verify the engine is truly running and the player is wired into the graph.
        // AVAudioPlayerNode.play() throws an uncatchable NSException (not a Swift error)
        // when disconnected, so we must gate here and let the caller fall back to AVPlayer.
        guard engine.isRunning,
              !engine.outputConnectionPoints(for: activePlayer, outputBus: 0).isEmpty else {
            throw NSError(domain: AVFoundationErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Player node not connected to engine"])
        }
        applyReplayGain(replayGainDB)
        let player = activePlayer
        let gen = nextGen(for: player)   // increment before stop so old callback is stale
        player.stop()
        player.scheduleFile(file, at: time, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self, self.currentGenLocked(for: player) == gen else { return }
            self.handlePlaybackCompletion()
        }
        player.play()
        setupNowPlaying()
    }

    /// Pre-schedule the next track on the staging player so it's ready for gapless handoff.
    /// No completion handler here: the staging player is stopped, and both .dataPlayedBack
    /// (fires immediately on stopped nodes) and .dataConsumed (fires when engine reads ahead)
    /// give false positives. End-of-track detection is handled by:
    ///   - Gapless: sentinel buffer installed after swap in handlePlaybackCompletion()
    ///   - Crossfade: position timer in PlaybackService triggers early
    func scheduleNext(file: AVAudioFile) {
        let player = stagingPlayer
        nextGen(for: player)
        player.stop()
        player.scheduleFile(file, at: nil)
        lock.lock()
        stagingIsReady = true
        lock.unlock()
    }

    /// Swap players for gapless / crossfade transition.
    /// Returns false if the staging player has no audio scheduled (pre-schedule failed).
    @discardableResult
    func transition(crossfade: Bool = false) -> Bool {
        // If staging player was never scheduled (preScheduleNext failed or hasn't completed),
        // bail and let the caller fall back to resolveAndPlay.
        lock.lock()
        guard stagingIsReady else {
            lock.unlock()
            return false
        }
        stagingIsReady = false
        lock.unlock()
        if crossfade && crossfadeDuration > 0 {
            crossfadeToStaging()
        } else {
            // True gapless: staging player was pre-scheduled; start it and stop the old one.
            stagingPlayer.play()
            nextGen(for: activePlayer)   // invalidate before stopping old active player
            activePlayer.stop()
        }
        isUsingPlayerA.toggle()
        return true
    }

    /// Check if a player node has audio scheduled but hasn't started yet.
    private func hasPendingSchedule(for player: AVAudioPlayerNode) -> Bool {
        // If the node has a render time, it has been connected and had audio pushed to it.
        // A non-nil lastRenderTime with sampleTime > 0 means it was at least scheduled.
        // As a simple heuristic: if the node is not playing, check if it was prepared.
        return player.lastRenderTime != nil
    }

    /// Seek the active player to a new position within a file.
    /// Uses the generation counter so the old callback is discarded.
    func seekActivePlayer(to seconds: Double, in file: AVAudioFile) {
        let sampleRate = file.processingFormat.sampleRate
        let startSample = AVAudioFramePosition(seconds * sampleRate)
        let remaining = file.length - startSample
        guard remaining > 0 else { return }
        let player = activePlayer
        let gen = nextGen(for: player)
        player.stop()
        player.scheduleSegment(
            file,
            startingFrame: startSample,
            frameCount: AVAudioFrameCount(remaining),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            guard let self, self.currentGenLocked(for: player) == gen else { return }
            self.handlePlaybackCompletion()
        }
        player.play()
    }

    // MARK: - EQ
    func applyEQPreset(_ preset: EQPreset) {
        for (i, band) in preset.bands.enumerated() {
            guard i < eq.bands.count else { break }
            let b = eq.bands[i]
            b.frequency  = band.frequencyHz
            b.gain       = band.gainDB
            b.bandwidth  = 1.0 / band.qFactor
            b.filterType = .parametric
            b.bypass     = false
        }
    }

    func setEQGain(_ gainDB: Float, bandIndex: Int) {
        guard bandIndex < eq.bands.count else { return }
        eq.bands[bandIndex].gain = gainDB.clamped(to: -12...12)
    }

    // MARK: - ReplayGain
    func applyReplayGain(_ gainDB: Float?) {
        let linear: Float
        if let gainDB {
            linear = Float(pow(10.0, Double(gainDB) / 20.0)).clamped(to: 0...2)
        } else {
            linear = 1.0
        }
        timePitch.rate = 1.0
        activePlayer.volume = linear
        // Store for the crossfade final step so the ramp doesn't overwrite the gain.
        pendingActivePlayerVolume = linear
    }

    /// Set the ReplayGain target for an upcoming crossfade transition WITHOUT
    /// modifying the currently-playing (outgoing) player's volume.
    func preparePendingReplayGain(_ gainDB: Float?) {
        let linear: Float
        if let gainDB {
            linear = Float(pow(10.0, Double(gainDB) / 20.0)).clamped(to: 0...2)
        } else {
            linear = 1.0
        }
        pendingActivePlayerVolume = linear
    }

    // MARK: - Crossfade
    private func crossfadeToStaging() {
        let steps = 60
        let stepDuration = crossfadeDuration / Double(steps)
        let active = activePlayer
        let staging = stagingPlayer
        let curve = crossfadeCurve
        // Invalidate the old player's generation now so its scheduled completion
        // callback is discarded and won't fire handlePlaybackCompletion() a second time.
        nextGen(for: active)
        crossfadeGeneration += 1
        let fadeGen = crossfadeGeneration
        staging.volume = 0
        staging.play()
        for i in 0...steps {
            let t = DispatchTime.now() + stepDuration * Double(i)
            DispatchQueue.main.asyncAfter(deadline: t) { [weak self] in
                guard let self, self.crossfadeGeneration == fadeGen else { return }
                let progress = Float(i) / Float(steps)   // 0 -> 1
                let (fadeOut, fadeIn) = curve.gains(at: progress)
                active.volume  = fadeOut
                staging.volume = fadeIn
                if i == steps {
                    // Crossfade complete — stop old player and reset its volume for next use.
                    active.stop()
                    active.volume = 1.0
                    // Apply the ReplayGain target volume now that the ramp is done.
                    staging.volume = self.pendingActivePlayerVolume
                }
            }
        }
    }

    // MARK: - Completion
    /// Called from the AVAudioPlayerNode completion callback (background thread).
    /// For gapless (no crossfade), performs the player swap immediately on the callback
    /// thread to avoid the latency of a main-actor round trip. PlaybackService is then
    /// notified to update metadata / queue state.
    private func handlePlaybackCompletion() {
        lock.lock()
        let ready = stagingIsReady
        let wantGapless = crossfadeDuration == 0
        if ready && wantGapless {
            stagingIsReady = false
            let staging = isUsingPlayerA ? playerB : playerA
            let active = isUsingPlayerA ? playerA : playerB
            let activeId = ObjectIdentifier(active)
            nodeGenerations[activeId, default: 0] += 1
            // Capture gen for the new active (staging) before releasing lock.
            let newActiveGen = nodeGenerations[ObjectIdentifier(staging), default: 0]
            isUsingPlayerA.toggle()
            lock.unlock()
            staging.play()
            active.stop()
            // Install a sentinel buffer on the new active player so we detect
            // when THIS track finishes. The player is now playing, so
            // .dataPlayedBack will fire at the correct time (after the main
            // file and this 1-frame silent buffer have been rendered).
            let format = staging.outputFormat(forBus: 0)
            if format.sampleRate > 0,
               let sentinel = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) {
                sentinel.frameLength = 1
                staging.scheduleBuffer(sentinel, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    guard let self, self.currentGenLocked(for: staging) == newActiveGen else { return }
                    self.handlePlaybackCompletion()
                }
            }
            onGaplessTransitionDidComplete?()
        } else {
            lock.unlock()
            onTrackDidFinish?()
        }
    }

    /// Fired when the engine auto-performed a gapless swap. PlaybackService should
    /// advance the queue and update metadata but NOT call transition() again.
    var onGaplessTransitionDidComplete: (() -> Void)?

    var onTrackDidFinish: (() -> Void)?

    // MARK: - Spectrum metering (FFT)
    private(set) var meterLevels: [Float] = Array(repeating: 0, count: 14)
    private var isMeteringInstalled = false

    // 14 log-spaced bands: 32 Hz → 16 kHz
    private let bandEdges: [Float] = [20, 40, 63, 100, 160, 250, 400, 630,
                                      1000, 1600, 2500, 4000, 6300, 10000, 20000]
    private let fftSize = 2048
    private var fftSetup: FFTSetup?
    private var fftHannWindow: [Float] = []
    private var fftAccumBuffer: [Float] = []
    private var fftAccumCount = 0

    private func setupFFT() {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        fftHannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&fftHannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftAccumBuffer = [Float](repeating: 0, count: fftSize)
        fftAccumCount = 0
    }

    private func teardownFFT() {
        if let s = fftSetup { vDSP_destroy_fftsetup(s); fftSetup = nil }
        fftAccumBuffer = []
        fftAccumCount = 0
    }

    private func computeSpectrum(sampleRate: Float, setup: FFTSetup) -> [Float] {
        let n    = fftSize
        let half = n / 2
        let log2n = vDSP_Length(log2(Float(n)))
        let bandCount = bandEdges.count - 1

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(fftAccumBuffer, 1, fftHannWindow, 1, &windowed, 1, vDSP_Length(n))

        // Pack interleaved reals into split-complex (treat pairs as Re/Im)
        var realPart = [Float](repeating: 0, count: half)
        var imagPart = [Float](repeating: 0, count: half)
        for i in 0..<half {
            realPart[i] = windowed[i * 2]
            imagPart[i] = windowed[i * 2 + 1]
        }

        // Forward FFT
        realPart.withUnsafeMutableBufferPointer { rb in
            imagPart.withUnsafeMutableBufferPointer { ib in
                var sc = DSPSplitComplex(realp: rb.baseAddress!, imagp: ib.baseAddress!)
                vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        // Magnitude spectrum
        var magnitudes = [Float](repeating: 0, count: half)
        realPart.withUnsafeBufferPointer { rb in
            imagPart.withUnsafeBufferPointer { ib in
                var sc = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: rb.baseAddress!),
                    imagp: UnsafeMutablePointer(mutating: ib.baseAddress!)
                )
                vDSP_zvabs(&sc, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        // Normalise: full-scale sine → ~1.0
        var scale = 2.0 / Float(n)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        // Map bins to frequency bands
        let freqPerBin = sampleRate / Float(n)
        var bands = [Float](repeating: 0, count: bandCount)
        for b in 0..<bandCount {
            let lo = max(1, Int(bandEdges[b] / freqPerBin))
            let hi = min(half - 1, Int(bandEdges[b + 1] / freqPerBin))
            guard hi >= lo else { continue }
            var sum: Float = 0
            for i in lo...hi { sum += magnitudes[i] }
            bands[b] = sum / Float(hi - lo + 1)  // mean magnitude per band
        }
        return bands
    }

    /// Serial queue for FFT work so the audio render thread is never blocked.
    private let meterQueue = DispatchQueue(label: "kenopsia.metering", qos: .userInteractive)

    private func startMetering() {
        guard !isMeteringInstalled, engine.isRunning else { return }
        setupFFT()
        let outputNode = engine.mainMixerNode
        let format = outputNode.outputFormat(forBus: 0)
        outputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self,
                  let channelData = buffer.floatChannelData,
                  buffer.frameLength > 0 else { return }

            // Copy samples off the render thread immediately.
            let nFrames = Int(buffer.frameLength)
            let nCh = min(Int(buffer.format.channelCount), 2)
            var mono = [Float](repeating: 0, count: nFrames)
            for i in 0..<nFrames {
                var s: Float = 0
                for ch in 0..<nCh { s += channelData[ch][i] }
                mono[i] = s / Float(nCh)
            }
            let sampleRate = Float(buffer.format.sampleRate)

            // Do all FFT work off the render thread.
            self.meterQueue.async { [weak self] in
                guard let self, let setup = self.fftSetup else { return }
                let frameCount = min(nFrames, self.fftSize - self.fftAccumCount)
                for i in 0..<frameCount {
                    self.fftAccumBuffer[self.fftAccumCount + i] = mono[i]
                }
                self.fftAccumCount += frameCount
                guard self.fftAccumCount >= self.fftSize else { return }

                let bands = self.computeSpectrum(sampleRate: sampleRate, setup: setup)
                self.fftAccumCount = 0
                DispatchQueue.main.async { self.meterLevels = bands }
            }
        }
        isMeteringInstalled = true
    }

    private func stopMetering() {
        guard isMeteringInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        isMeteringInstalled = false
        teardownFFT()
        meterLevels = Array(repeating: 0, count: 14)
    }

    // MARK: - Helpers
    private func ensureRunning() throws {
        if !isRunning { try start() }
    }

    private func setupNowPlaying() {
        // Filled in by PlaybackService with track metadata.
    }
}

// MARK: - Float clamping helper
private extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound))
    }
}

// MARK: - CrossfadeCurve
/// Controls the volume shape of the crossfade transition.
enum CrossfadeCurve: String, CaseIterable, Codable {
    /// Linear: outgoing fades 1→0, incoming fades 0→1 at equal rate.
    case linear
    /// Equal-power: uses sqrt curves so perceived loudness stays constant through the crossfade.
    /// This is the standard DJ/broadcast curve and avoids the "dip" in the middle.
    case equalPower
    /// S-curve: slow start, fast middle, slow end — smooth for orchestral music.
    case sCurve

    var displayName: String {
        switch self {
        case .linear:     "Linear"
        case .equalPower: "Equal Power"
        case .sCurve:     "S-Curve"
        }
    }

    /// Returns (fadeOut, fadeIn) gain values [0…1] for a normalised position `t` in [0…1].
    func gains(at t: Float) -> (out: Float, in: Float) {
        switch self {
        case .linear:
            return (1 - t, t)
        case .equalPower:
            // cos/sin quarter-wave: both channels sum to constant RMS power
            let angle = t * .pi / 2
            return (cos(angle), sin(angle))
        case .sCurve:
            // Smoothstep applied to both channels
            let fadeIn  = t * t * (3 - 2 * t)
            let fadeOut = 1 - fadeIn
            return (fadeOut, fadeIn)
        }
    }
}
