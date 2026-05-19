import SwiftUI

// MARK: - ContentView
/// Root view. Tab bar on iPhone; NavigationSplitView on iPad and Mac.
struct ContentView: View {
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var sources: SourceViewModel
    @StateObject var search = SearchViewModel()

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
        .sheet(isPresented: $player.showingNowPlaying) {
            NowPlayingView()
                .environmentObject(player)
        }
        .onAppear {
            // Wire SourceViewModel → LibraryViewModel for post-upload scans
            sources.libraryViewModel = library
        }
    }

    // MARK: - iPhone tab bar
    private var iPhoneLayout: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "music.note.list") }

            SearchView()
                .environmentObject(search)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            SourcesView()
                .tabItem { Label("Sources", systemImage: "externaldrive") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay(alignment: .bottom) {
            MiniPlayerView()
                .environmentObject(player)
                .padding(.bottom, 49)   // above tab bar
        }
    }

    // MARK: - iPad split
    private var iPadLayout: some View {
        NavigationSplitView {
            SidebarView()
                .environmentObject(search)
        } content: {
            LibraryView()
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
