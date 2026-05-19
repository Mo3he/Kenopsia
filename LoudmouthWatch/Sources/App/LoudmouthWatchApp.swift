import SwiftUI

@main
struct LoudmouthWatchApp: App {
    @StateObject private var phone = PhoneConnectivityService.shared

    init() {
        PhoneConnectivityService.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            NowPlayingView()
                .environmentObject(phone)
        }
    }
}
