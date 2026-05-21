import Foundation

// MARK: - MusicSource
/// Represents a configured music source (e.g. "My NAS", "Navidrome at home").
/// Sources are persisted to disk and synced via iCloud KV.
struct MusicSource: Identifiable, Codable, Equatable {
    let id: MusicSourceID
    var kind: MusicSourceKind
    var displayName: String
    var isEnabled: Bool
    var isPinnedOffline: Bool    // cache for offline listening

    // Populated after each successful scan so the UI can show a status badge
    // without querying the library.
    var trackCount: Int = 0
    var lastScanDate: Date? = nil

    // MARK: - Kind-specific config stored as opaque data
    // Decoded by each source adapter using MusicSourceConfig.
    var config: MusicSourceConfig

    init(id: MusicSourceID = MusicSourceID(), kind: MusicSourceKind, displayName: String, config: MusicSourceConfig) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.isEnabled = true
        self.isPinnedOffline = false
        self.config = config
    }
}

// MARK: - MusicSourceID
/// Stable opaque identifier for a source.
struct MusicSourceID: Hashable, Codable, CustomStringConvertible {
    let rawValue: UUID
    init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    var description: String { rawValue.uuidString }
}

// MARK: - MusicSourceKind
enum MusicSourceKind: String, Codable, CaseIterable {
    case local          // on-device files
    case nas            // DLNA / UPnP / SMB
    case subsonic       // Subsonic / Navidrome API
    case webRadio       // SHOUTcast, Icecast, raw stream URL
    case cloud          // iCloud Drive, Backblaze B2
    case wifiTransfer   // built-in HTTP server for drag-and-drop uploads
    case appleMusic     // MusicKit: user library + Apple Music catalogue

    var displayName: String {
        switch self {
        case .local:        "Local Library"
        case .nas:          "NAS / DLNA"
        case .subsonic:     "Subsonic / Navidrome"
        case .webRadio:     "Web Radio"
        case .cloud:        "Cloud Drive"
        case .wifiTransfer: "Wi-Fi Transfer"
        case .appleMusic:   "Apple Music"
        }
    }

    var systemImage: String {
        switch self {
        case .local:        "internaldrive"
        case .nas:          "server.rack"
        case .subsonic:     "antenna.radiowaves.left.and.right"
        case .webRadio:     "radio"
        case .cloud:        "icloud"
        case .wifiTransfer: "wifi"
        case .appleMusic:   "music.note"
        }
    }
}

// MARK: - MusicSourceConfig
/// Variant config per source kind. Stored as associated values so each source
/// adapter can decode what it needs without the rest of the app caring.
enum MusicSourceConfig: Codable, Equatable {
    case local(LocalSourceConfig)
    case nas(NASSourceConfig)
    case subsonic(SubsonicSourceConfig)
    case webRadio(WebRadioSourceConfig)
    case cloud(CloudSourceConfig)
    case wifiTransfer(WiFiTransferConfig)
    case appleMusic(AppleMusicSourceConfig)
}

// MARK: - Per-source config types
struct LocalSourceConfig: Codable, Equatable {
    /// Bookmark data for security-scoped access to a user-chosen folder.
    var bookmarkData: Data?
    var watchForChanges: Bool = true
}

struct NASSourceConfig: Codable, Equatable {
    var host: String = ""       // empty = use SSDP auto-discovery at scan time
    var port: Int = 8200        // UPnP default
    var protocol_: NASProtocol = .dlna
    var username: String = ""
    // Password stored in Keychain; only the Keychain key is stored here.
    var keychainKey: String = ""

    enum NASProtocol: String, Codable, Equatable { case dlna, smb }
}

struct SubsonicSourceConfig: Codable, Equatable {
    var serverURL: String       // e.g. "https://music.home.arpa"
    var username: String
    var keychainKey: String     // password / token in Keychain
    /// Accept self-signed / untrusted TLS certificates from this server.
    /// Intended for home Navidrome/Subsonic installs on local networks.
    var allowsSelfSignedCertificate: Bool = false
}

struct WebRadioSourceConfig: Codable, Equatable {
    var stations: [RadioStation]

    struct RadioStation: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var streamURL: String
        var genre: String
        var logoURL: String?
    }
}

struct CloudSourceConfig: Codable, Equatable {
    var provider: CloudProvider
    var rootPath: String = "/"
    var keychainKey: String = ""    // OAuth access token or Backblaze app key in Keychain
    var accountID: String = ""      // Backblaze Key ID, or display name after OAuth
    var isConnected: Bool = false
}

struct WiFiTransferConfig: Codable, Equatable {
    var port: Int = 8383
    var requiresPassword: Bool = false
    var keychainKey: String = ""    // optional upload password in Keychain
}

struct AppleMusicSourceConfig: Codable, Equatable {
    /// Whether the user has granted MusicKit authorisation.
    var isAuthorised: Bool = false
    /// Number of songs last fetched from the library (for the UI badge).
    var lastFetchedCount: Int = 0
}
