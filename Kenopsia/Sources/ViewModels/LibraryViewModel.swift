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
    @Published var isScanningNow = false
    @Published var scanProgress: Double = 0

    // MARK: - Computed from LibraryStore
    var tracks: [Track]   { applyFilter(Array(store.tracks.values).sorted(by: sortOrder)) }
    var albums: [Album]   { Array(store.albums.values).sorted { $0.title < $1.title } }
    var artists: [Artist] { Array(store.artists.values).sorted { $0.name < $1.name } }
    var playlists: [Playlist] { Array(store.playlists.values).sorted { $0.name < $1.name } }

    // MARK: - Dependencies
    private let store: LibraryStore
    private let scanner: LibraryScanner
    private var cancellables = Set<AnyCancellable>()

    init(libraryStore: LibraryStore? = nil) {
        let resolvedStore = libraryStore ?? LibraryStore.shared
        self.store = resolvedStore
        self.scanner = LibraryScanner(store: resolvedStore)
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

    func save(playlist: Playlist) { store.save(playlist: playlist) }
    func delete(playlistID: UUID) { store.delete(playlistID: playlistID) }

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
        case .isLossless:   return matchBool(track.isLossless, rule: rule)
        case .isFavourited: return matchBool(track.isFavourited, rule: rule)
        case .playCount:    return matchNumeric(Double(track.playCount), rule: rule)
        case .durationSeconds: return matchNumeric(track.durationSeconds, rule: rule)
        case .dateAdded:    return matchDate(track.dateAdded, rule: rule)
        case .lastPlayed:   return matchDate(track.lastPlayedAt ?? .distantPast, rule: rule)
        case .format:       return match(string: track.format.rawValue, rule: rule)
        default:            return false
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
