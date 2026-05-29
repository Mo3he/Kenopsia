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

    init() {
        // Must be called before PlaybackService or any view accesses
        // ChromecastService.shared, so that GCKCastContext is configured first.
        #if canImport(GoogleCast)
        ChromecastService.setup()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(sources)
                .sheet(isPresented: Binding(
                    get: {
                        #if DEBUG
                        return !hasLaunchedBefore && !DemoDataProvider.isActive
                        #else
                        return !hasLaunchedBefore
                        #endif
                    },
                    set: { if !$0 { hasLaunchedBefore = true } }
                )) {
                    OnboardingView()
                        .environmentObject(sources)
                        .environmentObject(player)
                        .interactiveDismissDisabled()
                }
                .task { WatchConnectivityService.shared.activate() }
                .task { registerWidgetNotifications() }
                .task { await activateDemoModeIfNeeded() }
        }
    }

    @MainActor
    private func activateDemoModeIfNeeded() async {
#if DEBUG
        guard DemoDataProvider.isActive else { return }
        // Brief yield so the SwiftUI layout pass completes before we inject data.
        try? await Task.sleep(for: .milliseconds(300))
        DemoDataProvider.load()
#endif
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
