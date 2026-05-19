import SwiftUI

// MARK: - SearchView
/// Unified search across the entire library (all sources simultaneously).
struct SearchView: View {
    @EnvironmentObject var search: SearchViewModel
    @EnvironmentObject var player: PlayerViewModel

    var body: some View {
        NavigationStack {
            Group {
                if search.query.isEmpty {
                    ContentUnavailableView(
                        "Search Your Library",
                        systemImage: "magnifyingglass",
                        description: Text("Search across tracks, albums, artists, and every connected source at once.")
                    )
                } else if search.isSearching {
                    ProgressView("Searching...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    searchResults
                }
            }
            .navigationTitle("Search")
            .searchable(text: $search.query, prompt: "Tracks, albums, artists...")
        }
    }

    private var searchResults: some View {
        List {
            if !search.trackResults.isEmpty {
                Section("Tracks") {
                    ForEach(search.trackResults.prefix(5)) { track in
                        TrackRowView(track: track)
                            .onTapGesture { player.play(track: track) }
                    }
                }
            }

            if !search.albumResults.isEmpty {
                Section("Albums") {
                    ForEach(search.albumResults.prefix(3)) { album in
                        NavigationLink(destination: AlbumDetailView(album: album)) {
                            HStack(spacing: 12) {
                                MiniArtworkView(cacheKey: album.artworkCacheKey)
                                VStack(alignment: .leading) {
                                    Text(album.title).font(.subheadline.bold())
                                    Text(album.artist).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            if !search.artistResults.isEmpty {
                Section("Artists") {
                    ForEach(search.artistResults.prefix(3)) { artist in
                        NavigationLink(destination: ArtistDetailView(artist: artist)) {
                            Text(artist.name).font(.subheadline)
                        }
                    }
                }
            }

            if search.trackResults.isEmpty && search.albumResults.isEmpty && search.artistResults.isEmpty {
                ContentUnavailableView.search(text: search.query)
            }
        }
        .listStyle(.insetGrouped)
    }
}
