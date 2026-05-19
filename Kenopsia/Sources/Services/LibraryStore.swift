import Foundation
import Observation

// MARK: - LibraryStore
/// In-memory library, persisted to disk as JSON in the App Group container.
/// All mutations happen on the MainActor; reads are safe from any context.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var tracks: [UUID: Track] = [:]
    @Published private(set) var albums: [String: Album] = [:]
    @Published private(set) var artists: [String: Artist] = [:]
    @Published private(set) var playlists: [UUID: Playlist] = [:]

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let storageURL: URL

    private init() {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.kenopsia")
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        storageURL = container.appendingPathComponent("library.json")
        load()
    }

    // MARK: - Mutations
    /// Merge a batch of newly scanned tracks from a source.
    /// Existing tracks with the same URI path are updated in-place; new ones are inserted.
    func merge(tracks newTracks: [Track], from sourceID: MusicSourceID) {
        // Build a URI-keyed lookup of existing tracks for this source so rescans update rather than duplicate.
        var byURI: [String: UUID] = [:]
        for (id, track) in tracks where track.source == sourceID {
            byURI[track.uri.stableKey] = id
        }
        for var track in newTracks {
            if let existingID = byURI[track.uri.stableKey] {
                // Preserve accumulated stats from the existing record.
                if let existing = tracks[existingID] {
                    track = Track(
                        id: existingID,
                        title: track.title, artist: track.artist, albumArtist: track.albumArtist,
                        album: track.album, genre: track.genre, year: track.year,
                        trackNumber: track.trackNumber, discNumber: track.discNumber,
                        composer: track.composer, comment: track.comment,
                        source: track.source, uri: track.uri, format: track.format,
                        durationSeconds: track.durationSeconds, fileSizeBytes: track.fileSizeBytes,
                        bitrateBps: track.bitrateBps, sampleRateHz: track.sampleRateHz,
                        bitDepth: track.bitDepth, channelCount: track.channelCount,
                        artworkCacheKey: track.artworkCacheKey,
                        replayGainTrack: track.replayGainTrack, replayGainAlbum: track.replayGainAlbum,
                        playCount: existing.playCount, lastPlayedAt: existing.lastPlayedAt,
                        dateAdded: existing.dateAdded,
                        isFavourited: existing.isFavourited, isExplicit: existing.isExplicit,
                        bpm: track.bpm, acoustID: track.acoustID
                    )
                }
                tracks[existingID] = track
            } else {
                tracks[track.id] = track
            }
        }
        rebuildDerivedCollections()
        save()
    }

    func update(track: Track) {
        tracks[track.id] = track
        rebuildDerivedCollections()
        save()
    }

    func delete(trackID: UUID) {
        tracks.removeValue(forKey: trackID)
        rebuildDerivedCollections()
        save()
    }

    func save(playlist: Playlist) {
        playlists[playlist.id] = playlist
        save()
    }

    func delete(playlistID: UUID) {
        playlists.removeValue(forKey: playlistID)
        save()
    }

    // MARK: - Derived collections
    private func rebuildDerivedCollections() {
        // Albums
        var albumMap: [String: Album] = [:]
        for track in tracks.values {
            let key = "\(track.albumArtist.isEmpty ? track.artist : track.albumArtist)//\(track.album)"
            if var album = albumMap[key] {
                if !album.trackIDs.contains(track.id) { album.trackIDs.append(track.id) }
                albumMap[key] = album
            } else {
                albumMap[key] = Album(
                    id: key,
                    title: track.album,
                    artist: track.albumArtist.isEmpty ? track.artist : track.albumArtist,
                    year: track.year,
                    genre: track.genre,
                    trackIDs: [track.id],
                    artworkCacheKey: track.artworkCacheKey
                )
            }
        }
        albums = albumMap

        // Artists
        var artistMap: [String: Artist] = [:]
        for album in albumMap.values {
            let key = album.artist.lowercased()
            if var artist = artistMap[key] {
                if !artist.albumIDs.contains(album.id) { artist.albumIDs.append(album.id) }
                artistMap[key] = artist
            } else {
                artistMap[key] = Artist(id: key, name: album.artist, albumIDs: [album.id])
            }
        }
        artists = artistMap
    }

    // MARK: - Persistence
    private struct StoragePayload: Codable {
        var tracks: [Track]
        var playlists: [Playlist]
    }

    private func save() {
        let payload = StoragePayload(
            tracks: Array(tracks.values),
            playlists: Array(playlists.values)
        )
        if let data = try? encoder.encode(payload) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let payload = try? decoder.decode(StoragePayload.self, from: data) else { return }
        tracks = Dictionary(uniqueKeysWithValues: payload.tracks.map { ($0.id, $0) })
        playlists = Dictionary(uniqueKeysWithValues: payload.playlists.map { ($0.id, $0) })
        rebuildDerivedCollections()
    }
}
