import SwiftUI

// MARK: - ContentView
/// Root view. Tab bar on iPhone; NavigationSplitView on iPad and Mac.
struct ContentView: View {
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var sources: SourceViewModel
    @StateObject var search = SearchViewModel()

    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("accentColorHex") private var accentColorHex = "00D9E6"

    private var accentColor: Color { Color(hex: accentColorHex) ?? .kCyan }

    private var preferredScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                iPadLayout
            } else {
                iPhoneLayout
            }
            #else
            macLayout
            #endif
        }
        .environment(\..kAccent, accentColor)
        .preferredColorScheme(preferredScheme)
        .sheet(isPresented: $player.showingNowPlaying) {
            NowPlayingView()
                .environmentObject(player)
                .environment(\.colorScheme, .dark)
                .environment(\.kAccent, accentColor)
        }
        .onAppear {
            // Wire SourceViewModel → LibraryViewModel for post-upload scans
            sources.libraryViewModel = library
        }
    }

    // MARK: - iPhone tab bar
    private var iPhoneLayout: some View {
        TabView {
            NavigationStack {
                LibraryView()
            }
            .tabItem { Label("Library", systemImage: "music.note.list") }

            VibeView()
                .tabItem { Label("Vibe", systemImage: "waveform.circle.fill") }

            SourcesView()
                .tabItem { Label("Sources", systemImage: "externaldrive") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.state.status != .stopped {
                Color.clear.frame(height: 66)
            }
        }
        .overlay(alignment: .bottom) {
            MiniPlayerView()
                .environmentObject(player)
                .environment(\.colorScheme, .dark)
                .padding(.bottom, 57)   // above tab bar with 8pt gap
        }
        .tint(accentColor)
    }

    // MARK: - iPad split
    private var iPadLayout: some View {
        NavigationSplitView {
            SidebarView()
                .environmentObject(search)
        } content: {
            NavigationStack {
                LibraryView()
            }
        } detail: {
            NowPlayingView()
                .environmentObject(player)
        }
    }

    // MARK: - Mac (Catalyst)
    private var macLayout: some View {
        iPadLayout
    }
}
