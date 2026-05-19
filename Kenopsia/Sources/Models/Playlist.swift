import Foundation

// MARK: - Playlist
/// A user-created or smart playlist.
struct Playlist: Identifiable, Codable {
    let id: UUID
    var name: String
    var kind: PlaylistKind
    var dateCreated: Date
    var dateModified: Date

    // For .manual playlists
    var trackIDs: [UUID]

    // For .smart playlists
    var rules: [SmartPlaylistRule]
    var ruleOperator: SmartPlaylistOperator   // match ALL or ANY rules
    var limit: SmartPlaylistLimit?

    init(id: UUID = UUID(), name: String, kind: PlaylistKind = .manual) {
        self.id = id
        self.name = name
        self.kind = kind
        self.dateCreated = .now
        self.dateModified = .now
        self.trackIDs = []
        self.rules = []
        self.ruleOperator = .all
        self.limit = nil
    }
}

enum PlaylistKind: String, Codable {
    case manual
    case smart
}

// MARK: - Smart Playlist
struct SmartPlaylistRule: Identifiable, Codable {
    let id: UUID
    var field: SmartPlaylistField
    var condition: SmartPlaylistCondition
    var value: String    // always stored as String, parsed per field type

    init(id: UUID = UUID(), field: SmartPlaylistField, condition: SmartPlaylistCondition, value: String) {
        self.id = id
        self.field = field
        self.condition = condition
        self.value = value
    }
}

enum SmartPlaylistField: String, Codable, CaseIterable {
    case title, artist, album, genre, year, format
    case playCount, lastPlayed, dateAdded
    case rating, isFavourited
    case durationSeconds, isLossless
    case bitrateBps, sampleRateHz
}

enum SmartPlaylistCondition: String, Codable, CaseIterable {
    // String
    case contains, doesNotContain, is_, isNot, startsWith, endsWith
    // Numeric / date
    case isGreaterThan, isLessThan, isInTheLast, isNotInTheLast
    // Boolean
    case isTrue, isFalse
}

enum SmartPlaylistOperator: String, Codable {
    case all, any
}

struct SmartPlaylistLimit: Codable {
    var count: Int
    var sortBy: SmartPlaylistSortField

    enum SmartPlaylistSortField: String, Codable {
        case random, mostPlayed, leastPlayed, recentlyAdded, recentlyPlayed, title
    }
}
