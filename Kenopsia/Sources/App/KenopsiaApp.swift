import SwiftUI
import WatchConnectivity

// MARK: - Darwin notification callback
// Global C-compatible function invoked by CFNotificationCenter when the widget's
// TogglePlayPauseIntent posts "net.mohome.kenopsia.widget.togglePlayPause".
// Using a top-level function satisfies @convention(c) without capturing context.
private func widgetPlayPauseCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    Task { @MainActor in PlaybackService.shared.togglePlayPause() }
}

@main
struct KenopsiaApp: App {
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
                .task { registerWidgetNotifications() }
        }
    }

    private func registerWidgetNotifications() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            widgetPlayPauseCallback,
            "net.mohome.kenopsia.widget.togglePlayPause" as CFString,
            nil,
            .deliverImmediately
        )
    }
}
