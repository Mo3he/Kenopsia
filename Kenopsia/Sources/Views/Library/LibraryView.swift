import SwiftUI

// MARK: - LibraryView
/// Main library tab. Albums, Artists, Tracks, Playlists segmented across a picker.
struct LibraryView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @State private var section: LibrarySection = .albums

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(LibrarySection.allCases, id: \.self) { s in
                        Text(s.label).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .padding([.horizontal, .bottom])

                switch section {
                case .albums:   AlbumGridView()
                case .artists:  ArtistListView()
                case .tracks:   TrackListView(tracks: library.tracks)
                case .playlists: PlaylistListView()
                }
            }
            .navigationTitle("Library")
            .searchable(text: $library.filterText, prompt: "Filter")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                            Button(order.displayName) { library.sortOrder = order }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
    }
}

enum LibrarySection: CaseIterable {
    case albums, artists, tracks, playlists
    var label: String {
        switch self {
        case .albums: "Albums"; case .artists: "Artists"
        case .tracks: "Tracks"; case .playlists: "Playlists"
        }
    }
}

// MARK: - AlbumGridView
struct AlbumGridView: View {
    @EnvironmentObject var library: LibraryViewModel
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(library.albums) { album in
                    NavigationLink(destination: AlbumDetailView(album: album)) {
                        AlbumTileView(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

struct AlbumTileView: View {
    let album: Album
    @State private var artworkImage: UIImage?
    @State private var resolvedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let img = artworkImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hue: albumHue, saturation: 0.4, brightness: 0.6))
                        .overlay {
                            Text(album.title.prefix(1))
                                .font(.largeTitle.bold())
                                .foregroundStyle(.white)
                        }
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(album.title)
                .font(.caption.bold())
                .lineLimit(1)
            Text(album.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .onAppear { loadArtwork() }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkCache.artworkDidUpdate)) { notification in
            guard let updatedKey = notification.userInfo?["key"] as? String,
                  updatedKey == resolvedKey else { return }
            loadArtwork()
        }
    }

    private func loadArtwork() {
        // Use the track's embedded key if present; otherwise generate from artist+album
        let key = album.artworkCacheKey
            ?? ArtworkFetchService.generateCacheKey(artist: album.artist, album: album.title)
        resolvedKey = key
        if let img = ArtworkCache.shared.gridImage(forKey: key) {
            artworkImage = img
            return
        }
        // Kick off a network fetch in the background; notification will refresh the view
        Task {
            await ArtworkFetchService.shared.fetch(artist: album.artist, album: album.title, cacheKey: key)
        }
    }

    private var albumHue: Double {
        Double(abs(album.id.hashValue) % 100) / 100
    }
}

// MARK: - ArtistListView
struct ArtistListView: View {
    @EnvironmentObject var library: LibraryViewModel
    var body: some View {
        List(library.artists) { artist in
            NavigationLink(destination: ArtistDetailView(artist: artist)) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(Color(hue: Double(abs(artist.id.hashValue) % 100) / 100,
                                    saturation: 0.4, brightness: 0.6))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Text(artist.name.prefix(1))
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                        }
                    VStack(alignment: .leading) {
                        Text(artist.name).font(.subheadline.bold())
                        Text("\(artist.albumIDs.count) album\(artist.albumIDs.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - TrackListView (reusable)
struct TrackListView: View {
    let tracks: [Track]
    @EnvironmentObject var player: PlayerViewModel

    var body: some View {
        List(tracks) { track in
            TrackRowView(track: track)
                .contentShape(Rectangle())
                .onTapGesture { player.play(tracks: tracks, startAt: tracks.firstIndex(of: track) ?? 0) }
                .swipeActions(edge: .trailing) {
                    Button { player.enqueueNext(track) } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(.accentColor)
                }
        }
        .listStyle(.plain)
    }
}

struct TrackRowView: View {
    let track: Track
    var body: some View {
        HStack(spacing: 12) {
            MiniArtworkView(cacheKey: track.artworkCacheKey
                ?? ArtworkFetchService.generateCacheKey(artist: track.artist, album: track.album))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.subheadline.bold()).lineLimit(1)
                Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if track.isLossless {
                Text(track.format.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.7))
                    .clipShape(Capsule())
            }
            Text(formatDuration(track.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - PlaylistListView
struct PlaylistListView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @State private var isCreating = false
    @State private var newName = ""

    var body: some View {
        List {
            ForEach(library.playlists) { playlist in
                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                    Label(playlist.name,
                          systemImage: playlist.kind == .smart ? "sparkles" : "music.note.list")
                }
            }
            .onDelete { offsets in
                offsets.forEach { library.delete(playlistID: library.playlists[$0].id) }
            }
        }
        .listStyle(.plain)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isCreating = true } label: { Image(systemName: "plus") }
            }
        }
        .alert("New Playlist", isPresented: $isCreating) {
            TextField("Name", text: $newName)
            Button("Create") {
                library.save(playlist: Playlist(name: newName))
                newName = ""
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Detail stubs (full implementations are in separate files)
struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel

    var tracks: [Track] {
        album.trackIDs.compactMap { library.track(for: $0) }
            .sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
    }

    var body: some View {
        TrackListView(tracks: tracks)
            .navigationTitle(album.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { player.play(tracks: tracks) } label: {
                        Label("Play All", systemImage: "play.fill")
                    }
                }
            }
    }
}

struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel

    var albums: [Album] {
        artist.albumIDs
            .compactMap { id in library.albums.first(where: { $0.id == id }) }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(albums) { album in
                    NavigationLink(destination: AlbumDetailView(album: album)) {
                        AlbumTileView(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.large)
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel

    var tracks: [Track] {
        if playlist.kind == .smart {
            return library.resolve(smartPlaylist: playlist)
        }
        return playlist.trackIDs.compactMap { library.track(for: $0) }
    }

    var body: some View {
        TrackListView(tracks: tracks)
            .navigationTitle(playlist.name)
    }
}

