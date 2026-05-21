import Foundation
import Combine

// MARK: - LibraryViewModel
/// Drives the Library tab: albums, artists, tracks, playlists, and smart playlists.
/// Also owns the scan lifecycle.
@MainActor
final class LibraryViewModel: ObservableObject {
    // MARK: - Published
    @Published var sortOrder: LibrarySortOrder = .album
    @Published var filterText = ""
    @Published var selectedSourceID: MusicSourceID? = nil
    @Published var isScanningNow = false
    @Published var scanProgress: Double = 0

    // MARK: - Computed from LibraryStore
    var tracks: [Track] {
        let base = Array(store.tracks.values)
        let filtered = selectedSourceID.map { sid in base.filter { $0.source == sid } } ?? base
        return applyFilter(filtered.sorted(by: sortOrder))
    }

    var albums: [Album] {
        guard let sid = selectedSourceID else {
            return Array(store.albums.values).sorted { $0.title < $1.title }
        }
        let sourceTrackIDs = Set(store.tracks.values.filter { $0.source == sid }.map { $0.id })
        return store.albums.values
            .filter { $0.trackIDs.contains { sourceTrackIDs.contains($0) } }
            .sorted { $0.title < $1.title }
    }

    var artists: [Artist] {
        guard let sid = selectedSourceID else {
            return Array(store.artists.values).sorted { $0.name < $1.name }
        }
        let sourceTrackIDs = Set(store.tracks.values.filter { $0.source == sid }.map { $0.id })
        let filteredAlbumIDs = Set(store.albums.values
            .filter { $0.trackIDs.contains { sourceTrackIDs.contains($0) } }
            .map { $0.id })
        return store.artists.values
            .filter { $0.albumIDs.contains { filteredAlbumIDs.contains($0) } }
            .sorted { $0.name < $1.name }
    }

    var filteredAlbums: [Album] {
        guard !filterText.isEmpty else { return albums }
        let q = filterText.lowercased()
        return albums.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q)
        }
    }

    var filteredArtists: [Artist] {
        guard !filterText.isEmpty else { return artists }
        let q = filterText.lowercased()
        return artists.filter { $0.name.lowercased().contains(q) }
    }

    var playlists: [Playlist] { Array(store.playlists.values).sorted { $0.name < $1.name } }

    /// Source IDs that have at least one track in the library.
    var populatedSourceIDs: Set<MusicSourceID> {
        Set(store.tracks.values.map { $0.source })
    }

    // MARK: - Dependencies
    private let store: LibraryStore
    private let scanner: LibraryScanner
    private var cancellables = Set<AnyCancellable>()

    init(libraryStore: LibraryStore? = nil) {
        let resolvedStore = libraryStore ?? LibraryStore.shared
        self.store = resolvedStore
        self.scanner = LibraryScanner(store: resolvedStore)
        // Forward store mutations so views observing LibraryViewModel re-render immediately.
        resolvedStore.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Accessors
    func track(for id: UUID) -> Track? { store.tracks[id] }

    // MARK: - Scanning
    func scanLocalLibrary(urls: [URL], source: MusicSource) {
        isScanningNow = true
        Task {
            await scanner.scan(source: source, urls: urls)
            isScanningNow = false
        }
    }

    /// Scan a single folder into the library (used after Wi-Fi Transfer uploads).
    func scanFolder(_ folder: URL, for source: MusicSource) {
        Task {
            await scanner.scan(source: source, urls: [folder])
        }
    }

    // MARK: - Editing
    func update(track: Track) { store.update(track: track) }
    func delete(trackID: UUID) { store.delete(trackID: trackID) }

    /// Stamps the canonical artwork cache key onto every track in the given album
    /// so that library rows and the Artwork Fixer both see the artwork immediately.
    func setArtworkCacheKey(_ key: String, forAlbumID albumID: String) {
        store.setArtworkCacheKey(key, forAlbumID: albumID)
    }

    func save(playlist: Playlist) { store.save(playlist: playlist) }
    func delete(playlistID: UUID) { store.delete(playlistID: playlistID) }

    /// Add a track to an existing manual playlist.
    func addTrack(_ trackID: UUID, to playlistID: UUID) {
        guard var playlist = store.playlists[playlistID],
              playlist.kind == .manual else { return }
        guard !playlist.trackIDs.contains(trackID) else { return }
        playlist.trackIDs.append(trackID)
        playlist.dateModified = .now
        store.save(playlist: playlist)
    }

    /// Remove a track from a manual playlist (without deleting from library).
    func removeTrack(_ trackID: UUID, from playlistID: UUID) {
        guard var playlist = store.playlists[playlistID],
              playlist.kind == .manual else { return }
        playlist.trackIDs.removeAll { $0 == trackID }
        playlist.dateModified = .now
        store.save(playlist: playlist)
    }

    // MARK: - Smart playlists
    func resolve(smartPlaylist: Playlist) -> [Track] {
        guard smartPlaylist.kind == .smart else { return [] }
        let allTracks = Array(store.tracks.values)
        let matched = allTracks.filter { track in
            let results = smartPlaylist.rules.map { SmartPlaylistEvaluator.evaluate(rule: $0, track: track) }
            return smartPlaylist.ruleOperator == .all
                ? results.allSatisfy { $0 }
                : results.contains { $0 }
        }
        // Apply sort before the count limit
        let sorted: [Track]
        switch smartPlaylist.limit?.sortBy {
        case .mostPlayed:     sorted = matched.sorted { $0.playCount > $1.playCount }
        case .leastPlayed:    sorted = matched.sorted { $0.playCount < $1.playCount }
        case .recentlyAdded:  sorted = matched.sorted { $0.dateAdded > $1.dateAdded }
        case .recentlyPlayed: sorted = matched.sorted {
            ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast)
        }
        case .title:          sorted = matched.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .random:         sorted = matched.shuffled()
        case nil:             sorted = matched
        }
        return Array(sorted.prefix(smartPlaylist.limit?.count ?? Int.max))
    }

    // MARK: - Filter
    private func applyFilter(_ tracks: [Track]) -> [Track] {
        guard !filterText.isEmpty else { return tracks }
        let q = filterText.lowercased()
        return tracks.filter {
            $0.title.lowercased().contains(q)
            || $0.artist.lowercased().contains(q)
            || $0.album.lowercased().contains(q)
        }
    }
}

// MARK: - LibrarySortOrder
enum LibrarySortOrder: String, CaseIterable {
    case album, artist, title, dateAdded, recentlyPlayed

    var displayName: String {
        switch self {
        case .album:          "Album"
        case .artist:         "Artist"
        case .title:          "Title"
        case .dateAdded:      "Date Added"
        case .recentlyPlayed: "Recently Played"
        }
    }
}

private extension [Track] {
    func sorted(by order: LibrarySortOrder) -> [Track] {
        switch order {
        case .title:          sorted { $0.title < $1.title }
        case .artist:         sorted { $0.artist < $1.artist }
        case .album:          sorted { $0.album < $1.album }
        case .dateAdded:      sorted { $0.dateAdded > $1.dateAdded }
        case .recentlyPlayed: sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        }
    }
}

// MARK: - SmartPlaylistEvaluator
enum SmartPlaylistEvaluator {
    static func evaluate(rule: SmartPlaylistRule, track: Track) -> Bool {
        switch rule.field {
        case .title:        return match(string: track.title,  rule: rule)
        case .artist:       return match(string: track.artist, rule: rule)
        case .album:        return match(string: track.album,  rule: rule)
        case .genre:        return match(string: track.genre,  rule: rule)
        case .acoustID:     return match(string: track.acoustID ?? "", rule: rule)
        case .isLossless:   return matchBool(track.isLossless, rule: rule)
        case .isFavourited: return matchBool(track.isFavourited, rule: rule)
        case .isExplicit:   return matchBool(track.isExplicit, rule: rule)
        case .playCount:    return matchNumeric(Double(track.playCount), rule: rule)
        case .durationSeconds: return matchNumeric(track.durationSeconds, rule: rule)
        case .dateAdded:    return matchDate(track.dateAdded, rule: rule)
        case .lastPlayed:   return matchDate(track.lastPlayedAt ?? .distantPast, rule: rule)
        case .format:       return match(string: track.format.rawValue, rule: rule)
        case .year:         return matchNumeric(Double(track.year ?? 0), rule: rule)
        case .bitrateBps:   return matchNumeric(Double(track.bitrateBps ?? 0), rule: rule)
        case .sampleRateHz: return matchNumeric(Double(track.sampleRateHz ?? 0), rule: rule)
        case .bpm:          return matchNumeric(track.bpm ?? 0, rule: rule)
        case .rating:       return matchNumeric(Double(track.rating), rule: rule)
        }
    }

    private static func match(string: String, rule: SmartPlaylistRule) -> Bool {
        let v = rule.value.lowercased()
        let s = string.lowercased()
        switch rule.condition {
        case .contains:       return s.contains(v)
        case .doesNotContain: return !s.contains(v)
        case .is_:            return s == v
        case .isNot:          return s != v
        case .startsWith:     return s.hasPrefix(v)
        case .endsWith:       return s.hasSuffix(v)
        default:              return false
        }
    }

    private static func matchNumeric(_ value: Double, rule: SmartPlaylistRule) -> Bool {
        guard let threshold = Double(rule.value) else { return false }
        switch rule.condition {
        case .isGreaterThan: return value > threshold
        case .isLessThan:    return value < threshold
        case .is_:           return value == threshold
        case .isNot:         return value != threshold
        default:             return false
        }
    }

    private static func matchBool(_ value: Bool, rule: SmartPlaylistRule) -> Bool {
        switch rule.condition {
        case .isTrue:  return value
        case .isFalse: return !value
        default:       return false
        }
    }

    private static func matchDate(_ date: Date, rule: SmartPlaylistRule) -> Bool {
        guard let days = Double(rule.value) else { return false }
        let cutoff = Date().addingTimeInterval(-days * 86400)
        switch rule.condition {
        case .isInTheLast:    return date >= cutoff
        case .isNotInTheLast: return date < cutoff
        default:              return false
        }
    }
}
