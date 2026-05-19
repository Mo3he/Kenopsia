import Foundation

// MARK: - Subsonic API response envelope
/// All Subsonic responses are wrapped in a "subsonic-response" container.
struct SubsonicResponse<T: Decodable>: Decodable {
    let subsonicResponse: SubsonicResponseBody

    struct SubsonicResponseBody: Decodable {
        let status: String
        let version: String
        // Payload — present only when status == "ok"
        let albumList2: T? // only present in getAlbumList2
        let album: T?      // only present in getAlbum (song list)

        enum CodingKeys: String, CodingKey {
            case status, version, albumList2, album
        }
    }

    var isOK: Bool { subsonicResponse.status == "ok" }

    enum CodingKeys: String, CodingKey {
        case subsonicResponse = "subsonic-response"
    }
}

// MARK: - Album list
struct AlbumList2: Decodable {
    let album: [SubsonicAlbum]?
}

struct SubsonicAlbum: Decodable {
    let id: String
    let name: String
    let artist: String?
    let artistId: String?
    let coverArt: String?
    let songCount: Int?
    let year: Int?
    let genre: String?
}

// MARK: - Album detail (song list)
struct AlbumDetail: Decodable {
    let song: [SubsonicSong]?
}

struct SubsonicSong: Decodable {
    let id: String
    let title: String
    let album: String?
    let artist: String?
    let albumArtist: String?
    let track: Int?
    let discNumber: Int?
    let year: Int?
    let genre: String?
    let coverArt: String?
    let duration: Int?      // seconds
    let bitRate: Int?       // kbps
    let suffix: String?     // file extension e.g. "flac"
    let contentType: String?
    let size: Int?
}
