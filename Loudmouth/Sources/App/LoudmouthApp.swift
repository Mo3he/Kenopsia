import SwiftUI
import WatchConnectivity

@main
struct LoudmouthApp: App {
    @StateObject private var player = PlayerViewModel()
    @StateObject private var library = LibraryViewModel()
    @StateObject private var sources = SourceViewModel()
    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(sources)
                .sheet(isPresented: Binding(
                    get: { !hasLaunchedBefore },
                    set: { if !$0 { hasLaunchedBefore = true } }
                )) {
                    OnboardingView()
                        .environmentObject(sources)
                        .interactiveDismissDisabled()
                }
                .task { WatchConnectivityService.shared.activate() }
        }
    }
}
