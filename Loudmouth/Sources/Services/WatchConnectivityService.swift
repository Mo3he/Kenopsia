import Foundation
import WatchConnectivity
import Combine
import UIKit

// MARK: - WatchConnectivityService
/// Phone-side bridge: pushes PlayerState to the watchOS companion app via
/// updateApplicationContext and routes control commands received from the watch
/// back to PlaybackService.
@MainActor
final class WatchConnectivityService: NSObject {
    static let shared = WatchConnectivityService()

    private var cancellables = Set<AnyCancellable>()
    private var lastSentArtworkKey: String?

    // MARK: - Activation

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        observeState()
    }

    // MARK: - State observation

    private func observeState() {
        PlaybackService.shared.$state
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] state in self?.push(state: state) }
            .store(in: &cancellables)
    }

    private func push(state: PlayerState) {
        guard WCSession.default.activationState == .activated else { return }

        var context: [String: Any] = [
            "status":   state.status.rawValue,
            "position": state.positionSeconds,
            "duration": state.durationSeconds,
            "title":    state.nowPlayingTitle,
            "artist":   state.nowPlayingArtist,
            "album":    state.nowPlayingAlbum
        ]

        // Send artwork only when the track changes to avoid context bloat.
        if let key = state.nowPlayingArtworkCacheKey, key != lastSentArtworkKey {
            if let image = ArtworkCache.shared.gridImage(forKey: key) {
                let size = CGSize(width: 100, height: 100)
                let thumbnail = UIGraphicsImageRenderer(size: size).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                context["artwork"] = thumbnail.jpegData(compressionQuality: 0.65)
            }
            lastSentArtworkKey = key
        }

        try? WCSession.default.updateApplicationContext(context)
    }
}

// MARK: - WCSessionDelegate
extension WatchConnectivityService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            switch message["command"] as? String {
            case "togglePlayPause": PlaybackService.shared.togglePlayPause()
            case "next":            PlaybackService.shared.next()
            case "previous":        PlaybackService.shared.previous()
            case "seek":
                if let pos = message["position"] as? Double {
                    PlaybackService.shared.seek(to: pos)
                }
            default: break
            }
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
}
