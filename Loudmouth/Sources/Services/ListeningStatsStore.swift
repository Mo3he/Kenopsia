import Foundation
import CryptoKit

// MARK: - ListeningStatsStore
/// Persists play counts, last-played dates, and prepares scrobble payloads for
/// Last.fm and ListenBrainz. Scrobbling itself is fire-and-forget; local stats
/// are always recorded regardless of network availability.
@MainActor
final class ListeningStatsStore: ObservableObject {
    @Published private(set) var recentlyPlayed: [PlayEvent] = []

    private let defaults = UserDefaults(suiteName: "group.net.mohome.loudmouth")
    private let scrobbler: Scrobbler
    private var pendingScrobbles: [PlayEvent] = []

    init(scrobbler: Scrobbler = Scrobbler()) {
        self.scrobbler = scrobbler
        load()
    }

    // MARK: - Record a play
    func record(played track: Track) {
        let event = PlayEvent(trackID: track.id, title: track.title, artist: track.artist,
                              album: track.album, durationSeconds: track.durationSeconds,
                              playedAt: Date())
        recentlyPlayed.insert(event, at: 0)
        if recentlyPlayed.count > 1000 { recentlyPlayed.removeLast() }
        save()

        // Persist play count and last-played date on the track itself so that
        // smart playlists (mostPlayed, recentlyPlayed) and LibrarySortOrder work.
        if var updated = LibraryStore.shared.tracks[track.id] {
            updated.playCount += 1
            updated.lastPlayedAt = event.playedAt
            LibraryStore.shared.update(track: updated)
        }

        pendingScrobbles.append(event)
        Task { await flushScrobbles() }
    }

    // MARK: - Scrobbling
    private func flushScrobbles() async {
        let toSend = pendingScrobbles
        pendingScrobbles = []
        await scrobbler.submit(events: toSend)
    }

    // MARK: - Persistence
    private func load() {
        guard let data = defaults?.data(forKey: "recentlyPlayed"),
              let events = try? JSONDecoder().decode([PlayEvent].self, from: data) else { return }
        recentlyPlayed = events
    }

    private func save() {
        if let data = try? JSONEncoder().encode(recentlyPlayed) {
            defaults?.set(data, forKey: "recentlyPlayed")
        }
    }
    // MARK: - Public auth helpers (called from SettingsView)
    func connectLastFm(username: String, password: String) async throws -> String {
        try await scrobbler.getMobileSession(username: username, password: password)
    }

    func verifyListenBrainzToken(_ token: String) async throws {
        try await scrobbler.verifyListenBrainzToken(token)
    }
}

// MARK: - PlayEvent
struct PlayEvent: Identifiable, Codable {
    let id: UUID
    let trackID: UUID
    let title: String
    let artist: String
    let album: String
    let durationSeconds: Double
    let playedAt: Date

    init(trackID: UUID, title: String, artist: String, album: String,
         durationSeconds: Double, playedAt: Date) {
        self.id = UUID()
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.playedAt = playedAt
    }
}

// MARK: - Scrobbler
/// Submits play events to Last.fm and/or ListenBrainz.
actor Scrobbler {
    private let session = URLSession.shared

    // Register your app at https://www.last.fm/api/account/create to get these values.
    private enum Config {
        static let lastFmAPIKey    = "1b26a89f8c82a74c59162ff3a51f9145"
        static let lastFmAPISecret = "2140d7adfb1ec7ef1a1c4a26a0a7c22b"
        static let lastFmEndpoint  = "https://ws.audioscrobbler.com/2.0/"
        static let lbEndpoint      = "https://api.listenbrainz.org/1/submit-listens"
        static let lbValidateURL   = "https://api.listenbrainz.org/1/validate-token"
    }

    func submit(events: [PlayEvent]) async {
        guard !events.isEmpty else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "lastFmEnabled"),
           let key = try? KeychainHelper.shared.read(key: "lastfm_session_key") {
            await submitToLastFm(events: events, sessionKey: key)
        }
        if defaults.bool(forKey: "listenBrainzEnabled"),
           let token = try? KeychainHelper.shared.read(key: "listenbrainz_token") {
            await submitToListenBrainz(events: events, token: token)
        }
    }

    // MARK: - Last.fm auth
    func getMobileSession(username: String, password: String) async throws -> String {
        var params: [String: String] = [
            "method":   "auth.getMobileSession",
            "username": username,
            "password": md5(password),
            "api_key":  Config.lastFmAPIKey,
        ]
        params["api_sig"] = apiSig(params)
        params["format"]  = "json"

        var req = URLRequest(url: URL(string: Config.lastFmEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = urlEncode(params)
        let (data, _) = try await session.data(for: req)

        struct Response: Decodable {
            let session: SessionData?
            let error: Int?
            let message: String?
            struct SessionData: Decodable { let key: String }
        }
        let resp = try JSONDecoder().decode(Response.self, from: data)
        if let err = resp.error { throw ScrobblerError.lastFmError(code: err, message: resp.message ?? "") }
        guard let key = resp.session?.key else { throw ScrobblerError.invalidResponse }
        return key
    }

    // MARK: - Last.fm scrobble
    private func submitToLastFm(events: [PlayEvent], sessionKey: String) async {
        // Last.fm accepts up to 50 tracks per call.
        for batchStart in stride(from: 0, to: events.count, by: 50) {
            let batch = Array(events[batchStart..<min(batchStart + 50, events.count)])
            var params: [String: String] = [
                "method":  "track.scrobble",
                "api_key": Config.lastFmAPIKey,
                "sk":      sessionKey,
            ]
            for (i, e) in batch.enumerated() {
                params["artist[\(i)]"]    = e.artist
                params["track[\(i)]"]     = e.title
                params["album[\(i)]"]     = e.album
                params["timestamp[\(i)]"] = "\(Int(e.playedAt.timeIntervalSince1970))"
                params["duration[\(i)]"]  = "\(Int(e.durationSeconds))"
            }
            params["api_sig"] = apiSig(params)
            params["format"]  = "json"

            var req = URLRequest(url: URL(string: Config.lastFmEndpoint)!)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = urlEncode(params)
            _ = try? await session.data(for: req)
        }
    }

    // MARK: - ListenBrainz
    func verifyListenBrainzToken(_ token: String) async throws {
        var req = URLRequest(url: URL(string: Config.lbValidateURL)!)
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: req)
        struct ValidateResp: Decodable { let valid: Bool; let user_name: String? }
        let resp = try JSONDecoder().decode(ValidateResp.self, from: data)
        if !resp.valid { throw ScrobblerError.invalidToken }
    }

    private func submitToListenBrainz(events: [PlayEvent], token: String) async {
        for event in events {
            let payload: [String: Any] = [
                "listen_type": "single",
                "payload": [[
                    "listened_at": Int(event.playedAt.timeIntervalSince1970),
                    "track_metadata": [
                        "artist_name": event.artist,
                        "track_name":  event.title,
                        "release_name": event.album,
                        "additional_info": [
                            "duration_ms": Int(event.durationSeconds * 1000),
                            "submission_client": "Loudmouth",
                        ] as [String: Any]
                    ] as [String: Any]
                ] as [String: Any]]
            ]
            guard let body = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            var req = URLRequest(url: URL(string: Config.lbEndpoint)!)
            req.httpMethod = "POST"
            req.setValue("application/json",    forHTTPHeaderField: "Content-Type")
            req.setValue("Token \(token)",       forHTTPHeaderField: "Authorization")
            req.httpBody = body
            _ = try? await session.data(for: req)
        }
    }

    // MARK: - Helpers
    private func apiSig(_ params: [String: String]) -> String {
        let sorted = params
            .filter { $0.key != "format" && $0.key != "callback" }
            .sorted { $0.key < $1.key }
            .map { $0.key + $0.value }
            .joined()
        return md5(sorted + Config.lastFmAPISecret)
    }

    private func urlEncode(_ params: [String: String]) -> Data? {
        params.map { k, v in
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(k)=\(ev)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }

    private func md5(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ScrobblerError: LocalizedError {
    case lastFmError(code: Int, message: String)
    case invalidResponse
    case invalidToken

    var errorDescription: String? {
        switch self {
        case .lastFmError(_, let msg): return msg
        case .invalidResponse:         return "Unexpected response from server"
        case .invalidToken:            return "Invalid token"
        }
    }
}

// MARK: - KeychainHelper
/// Thin wrapper around Security framework for storing sensitive credentials.
/// Uses kSecClassGenericPassword with the app's bundle ID as service name.
final class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "net.mohome.loudmouth"

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecValueData:        data,
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)     // remove old entry first
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { throw KeychainError.unhandledError(status: status) }
    }

    func read(key: String) throws -> String {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      key,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }
        return value
    }

    func delete(key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case itemNotFound
    case unhandledError(status: OSStatus)
}
