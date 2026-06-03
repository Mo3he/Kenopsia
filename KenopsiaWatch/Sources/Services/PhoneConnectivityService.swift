import Foundation
import WatchConnectivity

// MARK: - PhoneConnectivityService
/// Watch-side WatchConnectivity bridge.
/// Receives PlayerState snapshots from the iPhone via updateApplicationContext
/// and sends control commands back via sendMessage.
@MainActor
final class PhoneConnectivityService: NSObject, ObservableObject {
    static let shared = PhoneConnectivityService()

    @Published var status: String = "stopped"
    @Published var positionSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var artworkData: Data? = nil
    @Published var isPhoneReachable: Bool = false

    var isPlaying: Bool { status == "playing" }
    var progress: Double {
        durationSeconds > 0 ? min(positionSeconds / durationSeconds, 1) : 0
    }

    // MARK: - Activation

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - Commands

    func sendCommand(_ command: String, extras: [String: Any] = [:]) {
        let reachable = WCSession.default.isReachable
        isPhoneReachable = reachable
        guard reachable else { return }
        var msg = extras
        msg["command"] = command
        WCSession.default.sendMessage(msg, replyHandler: nil)
    }

    // MARK: - Demo

    func injectDemoState() {
        status          = "playing"
        positionSeconds = 87
        durationSeconds = 210
        title           = "Idea"
        artist          = "Kai Engel"
        album           = "Idea"
        isPhoneReachable = true
    }

    // MARK: - Internal

    fileprivate func apply(context: [String: Any]) {
        status          = context["status"]   as? String ?? "stopped"
        positionSeconds = context["position"] as? Double ?? 0
        durationSeconds = context["duration"] as? Double ?? 0
        title           = context["title"]    as? String ?? ""
        artist          = context["artist"]   as? String ?? ""
        album           = context["album"]    as? String ?? ""
        if let data = context["artwork"] as? Data {
            artworkData = data
        }
    }
}

// MARK: - WCSessionDelegate
extension PhoneConnectivityService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        Task { @MainActor in
            self.apply(context: applicationContext)
            // Any inbound payload proves the iPhone app is alive and talking
            // to us, even if WCSession.isReachable hasn't yet flipped to true.
            self.isPhoneReachable = true
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        Task { @MainActor in
            self.apply(context: message)
            self.isPhoneReachable = true
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Restore last known state so the UI is populated immediately on launch.
        Task { @MainActor in
            let ctx = WCSession.default.receivedApplicationContext
            if !ctx.isEmpty { self.apply(context: ctx) }
            self.isPhoneReachable = WCSession.default.isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.isPhoneReachable = session.isReachable }
    }
}
