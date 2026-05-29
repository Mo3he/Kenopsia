#if canImport(GoogleCast)
import Foundation
import Combine
#if canImport(GoogleCast)
import GoogleCast
#endif

// MARK: - ChromecastService
/// Manages the Google Cast session lifecycle and remote media control.
/// All GCK API calls must happen on the main thread per SDK requirements;
/// this class is @MainActor to enforce that automatically.
///
/// When GoogleCast.xcframework is absent the class compiles as a no-op stub
/// so the rest of the project builds unchanged. Drop the framework into
/// Frameworks/ and run `xcodegen generate` to activate the real implementation.
@MainActor
final class ChromecastService: NSObject, ObservableObject {

    // MARK: - Singleton
    static let shared = ChromecastService()

    // MARK: - Published state
    @Published private(set) var isCasting: Bool = false
    @Published private(set) var connectedDeviceName: String? = nil
    @Published private(set) var castPositionSeconds: Double = 0
    @Published private(set) var castDurationSeconds: Double = 0
    @Published var castDeviceVolume: Float = 0.5

    // MARK: - Private
#if canImport(GoogleCast)
    private var remoteClient: GCKRemoteMediaClient? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient
    }
#endif
    private var positionTimer: Timer?

    // MARK: - One-time setup
    /// Call once early in app launch before anything touches GCKCastContext.
    static func setup() {
#if canImport(GoogleCast)
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = false
#endif
    }

    // MARK: - Init
    override private init() {
        super.init()
#if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.add(self)
#endif
    }

    // MARK: - Media loading
    @discardableResult
    func cast(track: Track, streamURL: URL) -> Bool {
#if canImport(GoogleCast)
        let hasClient = remoteClient != nil
        print("[Cast] cast() called. remoteClient available: \(hasClient). URL: \(streamURL)")
        guard let client = remoteClient else {
            print("[Cast] cast() FAILED - remoteClient is nil")
            return false
        }

        let metadata = GCKMediaMetadata(metadataType: .musicTrack)
        metadata.setString(track.title, forKey: kGCKMetadataKeyTitle)
        metadata.setString(track.artist, forKey: kGCKMetadataKeyArtist)
        metadata.setString(track.album, forKey: kGCKMetadataKeyAlbumTitle)
        if let year = track.year {
            metadata.setString("\(year)-01-01T00:00:00.000Z", forKey: kGCKMetadataKeyReleaseDate)
        }
        if let trackNumber = track.trackNumber {
            metadata.setInteger(trackNumber, forKey: kGCKMetadataKeyTrackNumber)
        }

        let builder = GCKMediaInformationBuilder(contentURL: streamURL)
        builder.streamType = .buffered
        builder.contentType = track.format.mimeType
        builder.metadata = metadata
        builder.streamDuration = track.durationSeconds

        let loadOptions = GCKMediaLoadOptions()
        loadOptions.autoplay = true

        print("[Cast] Calling loadMedia with contentType: \(track.format.mimeType) streamType: buffered")
        client.loadMedia(builder.build(), with: loadOptions)
        castDurationSeconds = track.durationSeconds
        startPositionTimer()
        print("[Cast] loadMedia dispatched")
        return true
#else
        return false
#endif
    }

    // MARK: - Transport controls
    func pause() {
#if canImport(GoogleCast)
        remoteClient?.pause()
#endif
    }

    func resume() {
#if canImport(GoogleCast)
        remoteClient?.play()
#endif
    }

    func stop() {
#if canImport(GoogleCast)
        remoteClient?.stop()
#endif
        stopPositionTimer()
        castPositionSeconds = 0
        castDurationSeconds = 0
    }

    func setVolume(_ volume: Float) {
#if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.setDeviceVolume(volume)
        castDeviceVolume = volume
#endif
    }

    func seek(to seconds: Double) {
#if canImport(GoogleCast)
        let opts = GCKMediaSeekOptions()
        opts.interval = seconds
        opts.resumeState = .play
        remoteClient?.seek(with: opts)
#endif
        castPositionSeconds = seconds
    }

    // MARK: - Position polling
    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollPosition() }
        }
    }

    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func pollPosition() {
#if canImport(GoogleCast)
        guard let client = remoteClient else { return }
        // approximateStreamPosition() interpolates between SDK status updates
        // for a smooth, real-time position value.
        let pos = client.approximateStreamPosition()
        guard pos > 0 else { return }
        castPositionSeconds = pos
        if let info = client.mediaStatus?.mediaInformation, info.streamDuration > 0 {
            castDurationSeconds = info.streamDuration
        }
#endif
    }
}

// MARK: - GCKSessionManagerListener
#if canImport(GoogleCast)
extension ChromecastService: GCKSessionManagerListener {

    nonisolated func sessionManager(
        _ sessionManager: GCKSessionManager,
        didStart session: GCKCastSession
    ) {
        print("[Cast] didStart session. device: \(session.device.friendlyName ?? "unknown"). remoteMediaClient: \(session.remoteMediaClient != nil)")
        let initialVolume = session.currentDeviceVolume
        Task { @MainActor in
            self.castDeviceVolume = initialVolume
            self.isCasting = true
            self.connectedDeviceName = session.device.friendlyName
        }
    }

    nonisolated func sessionManager(
        _ sessionManager: GCKSessionManager,
        didResumeCastSession session: GCKCastSession
    ) {
        let initialVolume = session.currentDeviceVolume
        Task { @MainActor in
            self.castDeviceVolume = initialVolume
            self.isCasting = true
            self.connectedDeviceName = session.device.friendlyName
        }
    }

    nonisolated func sessionManager(
        _ sessionManager: GCKSessionManager,
        castSession session: GCKCastSession,
        didReceiveDeviceVolume volume: Float,
        muted: Bool
    ) {
        Task { @MainActor in self.castDeviceVolume = volume }
    }

    nonisolated func sessionManager(
        _ sessionManager: GCKSessionManager,
        didEnd session: GCKCastSession,
        withError error: Error?
    ) {
        print("[Cast] didEnd session. error: \(error?.localizedDescription ?? "none")")
        // Best-effort: stop media on the receiver in case it was disconnected
        // without a STOP_APP (e.g. user tapped \"Disconnect\" not \"Stop Casting\").
        session.remoteMediaClient?.stop()
        // Capture the last known position BEFORE publishing isCasting = false.
        // PlaybackService's Combine subscriber fires asynchronously (next RunLoop
        // turn), so castPositionSeconds must already hold the right value by then.
        let lastPos = session.remoteMediaClient?.approximateStreamPosition() ?? 0
        Task { @MainActor in
            self.stopPositionTimer()
            // Use the interpolated session position if available, otherwise fall back to
            // the last polled value so PlaybackService resumes at the right spot.
            let resumePos = lastPos > 0 ? lastPos : self.castPositionSeconds
            self.castPositionSeconds = resumePos  // keep until PlaybackService reads it
            self.isCasting = false                // triggers handleCastSessionEnded
            self.connectedDeviceName = nil
            self.castDurationSeconds = 0
        }
    }

    nonisolated func sessionManager(
        _ sessionManager: GCKSessionManager,
        didSuspend session: GCKCastSession,
        with reason: GCKConnectionSuspendReason
    ) {
        // Session is temporarily suspended (brief network hiccup, etc.).
        // The receiver is still playing; do NOT change isCasting or start
        // local playback. didResumeCastSession will fire when it reconnects,
        // or didEnd will fire if the session fully drops.
        print("[Cast] didSuspend session. reason: \(reason.rawValue) — keeping isCasting = true")
    }
}
#endif

#endif // canImport(GoogleCast)
