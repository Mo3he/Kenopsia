import SwiftUI
import PhotosUI

// MARK: - LibraryView
struct LibraryView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var sources: SourceViewModel
    @Environment(\..kAccent) var accent
    @State private var section: LibrarySection = .artists
    @FocusState private var isSearchFocused: Bool

    private var totalHours: Double {
        library.tracks.reduce(0) { $0 + $1.durationSeconds } / 3600
    }

    private var populatedSources: [MusicSource] {
        sources.sources.filter { library.populatedSourceIDs.contains($0.id) }
    }

    var body: some View {
        ZStack {
            Color.kBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                breadcrumbHeader
                statsBar
                if populatedSources.count > 1 {
                    sourceFilterRow
                }
                filterTabs
                Divider().overlay(Color.kBorder)
                searchBar
                contentArea
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .tint(accent)
    }

    private var breadcrumbHeader: some View {
        HStack(spacing: 6) {
            Text("LIBRARY")
                .foregroundStyle(.primary)
            Spacer()
        }
        .font(.system(size: 12, weight: .bold))
        .tracking(1.5)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var statsBar: some View {
        HStack(spacing: 6) {
            Text("\(library.albums.count) ALBUMS")
            Text("·").foregroundStyle(.primary.opacity(0.2))
            Text("\(library.tracks.count) TRACKS")
            Text("·").foregroundStyle(.primary.opacity(0.2))
            Text(String(format: "%.1f HRS", totalHours))
            Spacer()
            if section == .tracks {
                Menu {
                    ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                        Button {
                            library.sortOrder = order
                        } label: {
                            if library.sortOrder == order {
                                Label(order.displayName, systemImage: "checkmark")
                            } else {
                                Text(order.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(library.sortOrder.displayName.uppercased())
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.0)
                    .foregroundStyle(.primary.opacity(0.4))
                }
            }
        }
        .font(.system(size: 9, weight: .semibold))
        .tracking(1.0)
        .foregroundStyle(.primary.opacity(0.4))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var sourceFilterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                sourceChip(label: "ALL", id: nil)
                ForEach(populatedSources) { source in
                    sourceChip(label: source.displayName.uppercased(), id: source.id)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private func sourceChip(label: String, id: MusicSourceID?) -> some View {
        let isSelected = library.selectedSourceID == id
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { library.selectedSourceID = id }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? accent : Color.primary.opacity(0.07))
                .foregroundStyle(isSelected ? Color.black : Color.primary.opacity(0.55))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var filterTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(LibrarySection.allCases, id: \.self) { s in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { section = s }
                    } label: {
                        Text(s.label)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(section == s ? accent : Color.primary.opacity(0.07))
                            .foregroundStyle(section == s ? Color.black : Color.primary.opacity(0.55))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.35))
                TextField("Search...", text: $library.filterText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isSearchFocused)
                if !library.filterText.isEmpty {
                    Button { library.filterText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.primary.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if isSearchFocused || !library.filterText.isEmpty {
                Button("Cancel") {
                    library.filterText = ""
                    isSearchFocused = false
                }
                .font(.system(size: 14))
                .foregroundStyle(.primary.opacity(0.7))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSearchFocused)
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var contentArea: some View {
        if library.tracks.isEmpty {
            emptyLibraryView
        } else {
            switch section {
            case .albums:    AlbumListView()
            case .artists:   ArtistListView()
            case .tracks:    TrackListView(tracks: library.tracks)
            case .playlists: PlaylistListView()
            case .folders:   FolderBrowserView()
            case .history:   RecentlyPlayedView()
            }
        }
    }

    private var emptyLibraryView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.house")
                .font(.system(size: 48))
                .foregroundStyle(.primary.opacity(0.15))
            Text("Your library is empty")
                .font(.headline)
                .foregroundStyle(.primary.opacity(0.6))
            Text("Add a music source to get started")
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.35))
            NavigationLink(destination: SourcesView()) {
                Text("ADD SOURCE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(accent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - LibrarySection
enum LibrarySection: CaseIterable {
    case artists, albums, tracks, playlists, history, folders
    var label: String {
        switch self {
        case .artists:   "ARTISTS"
        case .albums:    "ALBUMS"
        case .tracks:    "TRACKS"
        case .playlists: "PLAYLISTS"
        case .history:   "HISTORY"
        case .folders:   "FOLDERS"
        }
    }
}

// MARK: - AlbumListView
struct AlbumListView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @State private var activeLetter: String?

    private var sections: [(letter: String, items: [Album])] {
        alphaGroup(library.filteredAlbums, key: \.title)
    }
    private var letters: [String] { sections.map(\.letter) }

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollViewReader { proxy in
                List {
                    ForEach(sections, id: \.letter) { section in
                        Section {
                            Text(section.letter)
                                .id(section.letter)
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.primary.opacity(0.35))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 2, trailing: 20))
                            ForEach(section.items) { album in
                                NavigationLink(destination: AlbumDetailView(album: album)) {
                                    AlbumRowView(album: album)
                                }
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                                .listRowSeparator(.hidden)
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
                .onChange(of: activeLetter) { _, letter in
                    if let letter {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(letter, anchor: .top) }
                    }
                }
            }
            if !letters.isEmpty {
                AlphabetScrubber(letters: letters, onSelect: { activeLetter = $0 })
                    .padding(.trailing, 4)
                    .padding(.bottom, player.state.status != .stopped ? 66 : 0)
            }
        }
    }
}

// MARK: - AlbumRowView
struct AlbumRowView: View {
    let album: Album
    @State private var artworkImage: UIImage?
    @State private var resolvedKey: String?

    private var albumHue: Double {
        Double(abs(album.id.hashValue) % 100) / 100
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let img = artworkImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(hue: albumHue, saturation: 0.35, brightness: 0.28)
                        .overlay {
                            Text(album.title.prefix(1))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.system(.subheadline, design: .default).bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(album.artist.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(.primary.opacity(0.4))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let year = album.year {
                Text(String(year))
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(.primary.opacity(0.45))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 0.75)
                    )
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
        .onAppear { loadArtwork() }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkCache.artworkDidUpdate)) { notification in
            guard let key = notification.userInfo?["key"] as? String,
                  key == resolvedKey else { return }
            loadArtwork()
        }
    }

    private func loadArtwork() {
        let key = album.artworkCacheKey
            ?? ArtworkFetchService.generateCacheKey(artist: album.artist, album: album.title)
        resolvedKey = key
        artworkImage = ArtworkCache.shared.gridImage(forKey: key)
    }
}

// MARK: - ArtistListView
struct ArtistListView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @State private var activeLetter: String?

    private var sections: [(letter: String, items: [Artist])] {
        alphaGroup(library.filteredArtists, key: \.name)
    }
    private var letters: [String] { sections.map(\.letter) }

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollViewReader { proxy in
                List {
                    ForEach(sections, id: \.letter) { section in
                        Section {
                            Text(section.letter)
                                .id(section.letter)
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.primary.opacity(0.35))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 2, trailing: 20))
                            ForEach(section.items) { artist in
                                NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                    ArtistRowView(artist: artist)
                                }
                                .listRowBackground(Color.clear)
                                .listRowSeparatorTint(Color.primary.opacity(0.06))
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
                .onChange(of: activeLetter) { _, letter in
                    if let letter {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(letter, anchor: .top) }
                    }
                }
            }
            if !letters.isEmpty {
                AlphabetScrubber(letters: letters, onSelect: { activeLetter = $0 })
                    .padding(.trailing, 4)
                    .padding(.bottom, player.state.status != .stopped ? 66 : 0)
            }
        }
    }
}

// MARK: - ArtistRowView
struct ArtistRowView: View {
    let artist: Artist
    @State private var artworkImage: UIImage?
    @State private var resolvedKey: String?

    private var placeholderHue: Double {
        Double(abs(artist.id.hashValue) % 100) / 100
    }

    var body: some View {
        HStack(spacing: 14) {
            Group {
                if let img = artworkImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color(hue: placeholderHue, saturation: 0.35, brightness: 0.28)
                        .overlay {
                            Text(artist.name.prefix(1))
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                Text("\(artist.albumIDs.count) ALBUM\(artist.albumIDs.count == 1 ? "" : "S")")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(.primary.opacity(0.4))
            }
        }
        .padding(.vertical, 5)
        .onAppear { loadArtwork() }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkCache.artworkDidUpdate)) { notification in
            guard let key = notification.userInfo?["key"] as? String,
                  key == resolvedKey else { return }
            loadArtwork()
        }
    }

    private func loadArtwork() {
        guard let key = artist.artworkCacheKey else { return }
        resolvedKey = key
        artworkImage = ArtworkCache.shared.gridImage(forKey: key)
    }
}

// MARK: - TrackListView (reusable)
struct TrackListView: View {
    let tracks: [Track]
    @EnvironmentObject var player: PlayerViewModel
    @EnvironmentObject var library: LibraryViewModel
    @State private var editingTrack: Track?
    @State private var activeLetter: String?

    private var sections: [(letter: String, items: [Track])] {
        alphaGroup(tracks, key: \.title)
    }
    private var letters: [String] { sections.map(\.letter) }

    var body: some View {
        ZStack(alignment: .trailing) {
            ScrollViewReader { proxy in
                List {
                    ForEach(sections, id: \.letter) { section in
                        Section {
                            Text(section.letter)
                                .id(section.letter)
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.primary.opacity(0.35))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 2, trailing: 20))
                            ForEach(section.items) { track in
                                TrackRowView(track: track)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        player.play(tracks: tracks, startAt: tracks.firstIndex(of: track) ?? 0)
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) { library.delete(trackID: track.id) } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                        Button { editingTrack = track } label: {
                                            Label("Edit", systemImage: "pencil")
                                        }
                                        .tint(.indigo)
                                        Button { player.enqueueNext(track) } label: {
                                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                        }
                                        .tint(.kCyan)
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button { player.enqueueLast(track) } label: {
                                            Label("Add to Queue", systemImage: "text.append")
                                        }
                                        .tint(.orange)
                                    }
                                    .contextMenu {
                                        Button { player.enqueueNext(track) } label: {
                                            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                        }
                                        Button { player.enqueueLast(track) } label: {
                                            Label("Add to Queue", systemImage: "text.append")
                                        }
                                        if !library.playlists.isEmpty {
                                            Menu("Add to Playlist") {
                                                ForEach(library.playlists.filter { $0.kind == .manual }) { playlist in
                                                    Button(playlist.name) {
                                                        library.addTrack(track.id, to: playlist.id)
                                                    }
                                                }
                                            }
                                        }
                                        Divider()
                                        Button { editingTrack = track } label: {
                                            Label("Edit Tags", systemImage: "pencil")
                                        }
                                        Button(role: .destructive) { library.delete(trackID: track.id) } label: {
                                            Label("Remove from Library", systemImage: "trash")
                                        }
                                    }
                                    .listRowBackground(Color.clear)
                                    .listRowSeparatorTint(Color.primary.opacity(0.06))
                            }
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.immediately)
                .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
                .onChange(of: activeLetter) { _, letter in
                    if let letter {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(letter, anchor: .top) }
                    }
                }
            }
            if !letters.isEmpty {
                AlphabetScrubber(letters: letters, onSelect: { activeLetter = $0 })
                    .padding(.trailing, 4)
                    .padding(.bottom, player.state.status != .stopped ? 66 : 0)
            }
        }
        .sheet(item: $editingTrack) { track in
            TagEditorView(track: track)
                .environmentObject(library)
        }
    }
}

struct TrackRowView: View {
    let track: Track
    var body: some View {
        HStack(spacing: 12) {
            MiniArtworkView(cacheKey: track.artworkCacheKey
                ?? ArtworkFetchService.generateCacheKey(artist: track.artist, album: track.album))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(track.artist.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(.primary.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(track.format.displayName)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(track.isLossless ? Color.kCyan : Color.primary.opacity(0.35))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(
                                track.isLossless ? Color.kCyan.opacity(0.5) : Color.primary.opacity(0.18),
                                lineWidth: 0.75
                            )
                    )
                Text(formatDuration(track.durationSeconds))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.3))
            }
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - RecentlyPlayedView
struct RecentlyPlayedView: View {
    @EnvironmentObject var player: PlayerViewModel
    @ObservedObject private var stats = ListeningStatsStore.shared

    var body: some View {
        Group {
            if stats.recentlyPlayed.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock")
                        .font(.system(size: 44))
                        .foregroundStyle(.primary.opacity(0.15))
                    Text("No plays recorded yet")
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.4))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(stats.recentlyPlayed) { event in
                        Button {
                            if let track = LibraryStore.shared.tracks[event.trackID] {
                                player.play(tracks: [track])
                            }
                        } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title)
                                        .font(.subheadline.bold())
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(event.artist.isEmpty ? event.album : event.artist)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary.opacity(0.5))
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(event.playedAt, style: .relative)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.primary.opacity(0.3))
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparatorTint(Color.primary.opacity(0.06))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
            }
        }
    }
}

// MARK: - PlaylistListView
struct PlaylistListView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @State private var isCreating = false

    var body: some View {
        List {
            Button {
                isCreating = true
            } label: {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.07))
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.kCyan)
                        }
                    Text("New Playlist")
                        .font(.subheadline.bold())
                        .foregroundStyle(Color.kCyan)
                }
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Color.primary.opacity(0.06))

            ForEach(library.playlists) { playlist in
                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.07))
                            .frame(width: 44, height: 44)
                            .overlay {
                                Image(systemName: playlist.kind == .smart ? "sparkles" : "music.note.list")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.kCyan)
                            }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playlist.name)
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text(playlist.kind == .smart ? "SMART" : "\(playlist.trackIDs.count) TRACKS")
                                .font(.system(size: 9, weight: .medium))
                                .tracking(0.8)
                                .foregroundStyle(.primary.opacity(0.4))
                        }
                    }
                    .padding(.vertical, 5)
                }
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.primary.opacity(0.06))
            }
            .onDelete { offsets in
                offsets.forEach { library.delete(playlistID: library.playlists[$0].id) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
        .sheet(isPresented: $isCreating) {
            SmartPlaylistEditorView()
                .environmentObject(library)
        }
    }
}

// MARK: - AlbumDetailView
struct AlbumDetailView: View {
    let album: Album
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.kAccent) var accent
    @State private var artworkImage: UIImage?
    @State private var editingTrack: Track?
    @State private var showingAlbumEditor = false

    var tracks: [Track] {
        album.trackIDs.compactMap { library.track(for: $0) }
            .sorted { ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                albumHeader
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.bottom, 4)
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        DetailTrackRow(track: track, index: idx + 1)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(tracks: tracks, startAt: idx) }
                            .contextMenu {
                                Button { player.enqueueNext(track) } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                Button { player.enqueueLast(track) } label: {
                                    Label("Add to Queue", systemImage: "text.append")
                                }
                                if !library.playlists.isEmpty {
                                    Menu("Add to Playlist") {
                                        ForEach(library.playlists.filter { $0.kind == .manual }) { playlist in
                                            Button(playlist.name) {
                                                library.addTrack(track.id, to: playlist.id)
                                            }
                                        }
                                    }
                                }
                                Divider()
                                Button { editingTrack = track } label: {
                                    Label("Edit Tags", systemImage: "pencil")
                                }
                                Button(role: .destructive) { library.delete(trackID: track.id) } label: {
                                    Label("Remove from Library", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
        .background(Color.kBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(album.title.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingAlbumEditor = true } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.primary)
                }
            }
        }
        .toolbarBackground(Color.kBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showingAlbumEditor) {
            AlbumEditorView(album: album)
                .environmentObject(library)
        }
        .sheet(item: $editingTrack) { track in
            TagEditorView(track: track)
                .environmentObject(library)
        }
        .onAppear { loadArtwork() }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkCache.artworkDidUpdate)) { _ in
            loadArtwork()
        }
    }

    private var albumHeader: some View {
        VStack(spacing: 16) {
            Group {
                if let img = artworkImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color(hue: Double(abs(album.id.hashValue) % 100) / 100,
                          saturation: 0.35, brightness: 0.28)
                        .overlay {
                            Text(album.title.prefix(1))
                                .font(.system(size: 64, weight: .bold))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .frame(maxWidth: 220)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(spacing: 10) {
                Text(album.title)
                    .font(.system(.title3, design: .default).bold())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(album.artist.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.primary.opacity(0.4))

                HStack(spacing: 6) {
                    if let year = album.year {
                        MetaChip(text: String(year))
                    }
                    MetaChip(text: "\(tracks.count) TRACKS")
                    MetaChip(text: totalDuration)
                }

                HStack(spacing: 12) {
                    Button { player.play(tracks: tracks) } label: {
                        Text("PLAY")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(2.5)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    Button {
                        let shuffled = tracks.shuffled()
                        player.play(tracks: shuffled)
                    } label: {
                        Text("SHUFFLE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(2.5)
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(accent.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 20)
        .padding(.bottom, 20)
    }

    private var totalDuration: String {
        let s = tracks.reduce(0) { $0 + $1.durationSeconds }
        let m = Int(s) / 60
        return m < 60 ? "\(m)m" : String(format: "%dh %dm", m / 60, m % 60)
    }

    private func loadArtwork() {
        let key = album.artworkCacheKey
            ?? ArtworkFetchService.generateCacheKey(artist: album.artist, album: album.title)
        artworkImage = ArtworkCache.shared.fullImage(forKey: key)
    }
}

// MARK: - MetaChip
struct MetaChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.primary.opacity(0.45))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.primary.opacity(0.2), lineWidth: 0.75)
            )
    }
}

// MARK: - DetailTrackRow
struct DetailTrackRow: View {
    let track: Track
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(String(format: "%02d", index))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.2))
                .frame(width: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !track.artist.isEmpty && track.artist != track.albumArtist {
                    Text(track.artist.uppercased())
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(.primary.opacity(0.4))
                }
            }
            Spacer()
            Text(formatDuration(track.durationSeconds))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary.opacity(0.3))
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    private func formatDuration(_ s: Double) -> String {
        String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - ArtistDetailView
struct ArtistDetailView: View {
    let artist: Artist
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel

    var albums: [Album] {
        artist.albumIDs
            .compactMap { id in library.albums.first(where: { $0.id == id }) }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }

    var body: some View {
        List {
            ForEach(albums) { album in
                NavigationLink(destination: AlbumDetailView(album: album)) {
                    AlbumRowView(album: album)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
        .background(Color.kBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(artist.name.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.primary)
            }
        }
        .toolbarBackground(Color.kBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - PlaylistDetailView
struct PlaylistDetailView: View {
    let playlist: Playlist
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.kAccent) var accent
    @State private var isEditing = false

    var tracks: [Track] {
        if playlist.kind == .smart {
            return library.resolve(smartPlaylist: playlist)
        }
        return playlist.trackIDs.compactMap { library.track(for: $0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                playlistHeader
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.bottom, 4)
                LazyVStack(spacing: 0) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                        DetailTrackRow(track: track, index: idx + 1)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(tracks: tracks, startAt: idx) }
                            .contextMenu {
                                Button { player.enqueueNext(track) } label: {
                                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                                }
                                Button { player.enqueueLast(track) } label: {
                                    Label("Add to Queue", systemImage: "text.append")
                                }
                                if playlist.kind == .manual {
                                    Divider()
                                    Button(role: .destructive) {
                                        library.removeTrack(track.id, from: playlist.id)
                                    } label: {
                                        Label("Remove from Playlist", systemImage: "minus.circle")
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
        .background(Color.kBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(playlist.name.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.primary)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { isEditing = true } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.primary)
                }
            }
        }
        .toolbarBackground(Color.kBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $isEditing) {
            SmartPlaylistEditorView(existing: library.playlists.first { $0.id == playlist.id } ?? playlist)
                .environmentObject(library)
        }
    }

    private var playlistHeader: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 120, height: 120)
                .overlay {
                    Image(systemName: playlist.kind == .smart ? "sparkles" : "music.note.list")
                        .font(.system(size: 44))
                        .foregroundStyle(accent)
                }

            Text(playlist.name)
                .font(.system(.title3, design: .default).bold())
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                MetaChip(text: "\(tracks.count) TRACKS")
                MetaChip(text: totalDuration)
            }

            HStack(spacing: 12) {
                Button { player.play(tracks: tracks) } label: {
                    Label("PLAY", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(accent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Button {
                    let shuffled = tracks.shuffled()
                    player.play(tracks: shuffled)
                } label: {
                    Label("SHUFFLE", systemImage: "shuffle")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2)
                        .foregroundStyle(accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(accent.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .labelStyle(.titleOnly)
            .padding(.horizontal, 20)
            .padding(.top, 4)
        }
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private var totalDuration: String {
        let s = tracks.reduce(0) { $0 + $1.durationSeconds }
        let m = Int(s) / 60
        return m < 60 ? "\(m)m" : String(format: "%dh %dm", m / 60, m % 60)
    }
}

// MARK: - FolderBrowserView
struct FolderBrowserView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var player: PlayerViewModel

    private struct FolderEntry: Identifiable {
        let id: String        // full directory path
        let name: String      // last path component
        let tracks: [Track]
    }

    private var folders: [FolderEntry] {
        var dict: [String: [Track]] = [:]
        for track in library.tracks {
            guard case .localFile(let path) = track.uri else { continue }
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
            dict[dir, default: []].append(track)
        }
        return dict
            .map { FolderEntry(id: $0.key,
                               name: URL(fileURLWithPath: $0.key).lastPathComponent,
                               tracks: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        if folders.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 40))
                    .foregroundStyle(.primary.opacity(0.15))
                Text("No local folders")
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(1)
                    .foregroundStyle(.primary.opacity(0.3))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(folders) { folder in
                    NavigationLink(destination: FolderDetailView(name: folder.name, tracks: folder.tracks)) {
                        HStack(spacing: 14) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.kCyan.opacity(0.8))
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.name)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Text("\(folder.tracks.count) TRACK\(folder.tracks.count == 1 ? "" : "S")")
                                    .font(.system(size: 9, weight: .medium))
                                    .tracking(0.5)
                                    .foregroundStyle(.primary.opacity(0.4))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
        }
    }
}

// MARK: - FolderDetailView
struct FolderDetailView: View {
    let name: String
    let tracks: [Track]
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.kAccent) var accent

    private var sortedTracks: [Track] {
        tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                Button { player.play(tracks: sortedTracks) } label: {
                    Text("PLAY ALL")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(2.5)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(accent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                ForEach(Array(sortedTracks.enumerated()), id: \.element.id) { idx, track in
                    DetailTrackRow(track: track, index: idx + 1)
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(tracks: sortedTracks, startAt: idx) }
                }
                .padding(.horizontal, 20)
            }
        }
        .contentMargins(.bottom, player.state.status != .stopped ? 66 : 0, for: .scrollContent)
        .background(Color.kBackground.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(name.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(.primary)
            }
        }
        .toolbarBackground(Color.kBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - AlphabetScrubber
struct AlphabetScrubber: View {
    let letters: [String]
    let onSelect: (String) -> Void
    @State private var lastLetter = ""

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(letters, id: \.self) { letter in
                    Text(letter)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let fraction = value.location.y / max(1, geo.size.height)
                        let idx = max(0, min(letters.count - 1, Int(fraction * CGFloat(letters.count))))
                        let letter = letters[idx]
                        guard letter != lastLetter else { return }
                        lastLetter = letter
                        UISelectionFeedbackGenerator().selectionChanged()
                        onSelect(letter)
                    }
            )
        }
        .frame(width: 18)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.07))
        .clipShape(Capsule())
    }
}

// MARK: - Alpha grouping helpers
private func firstLetter(of string: String) -> String {
    let trimmed = string.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return "#" }
    let folded = trimmed.folding(options: .diacriticInsensitive, locale: .current)
    guard let first = folded.first, first.isLetter else { return "#" }
    return String(first).uppercased()
}

private func alphaGroup<T>(_ items: [T], key: (T) -> String) -> [(letter: String, items: [T])] {
    var dict: [String: [T]] = [:]
    for item in items {
        let letter = firstLetter(of: key(item))
        dict[letter, default: []].append(item)
    }
    return dict.sorted { a, b in
        if a.key == "#" { return false }
        if b.key == "#" { return true }
        return a.key < b.key
    }.map { ($0.key, $0.value) }
}
