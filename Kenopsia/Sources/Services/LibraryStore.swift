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
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    func update(track: Track) {
        tracks[track.id] = track
        rebuildDerivedCollections()
        save()
    }

    /// Updates `artworkCacheKey` on every track that belongs to the given album.
    /// Called after ArtworkFixer stores art under the canonical key so library
    /// rows and the Fixer's own scan both find the artwork on the next refresh.
    func setArtworkCacheKey(_ key: String, forAlbumID albumID: String) {
        guard let album = albums[albumID] else { return }
        for trackID in album.trackIDs {
            tracks[trackID]?.artworkCacheKey = key
        }
        rebuildDerivedCollections()
        save()
    }

    func delete(trackID: UUID) {
        tracks.removeValue(forKey: trackID)
        rebuildDerivedCollections()
        save()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
    }

    func removeTracks(from sourceID: MusicSourceID) {
        tracks = tracks.filter { $0.value.source != sourceID }
        rebuildDerivedCollections()
        save()
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
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

        // Sort each album's tracks by disc number then track number so the
        // order is deterministic regardless of dictionary-iteration order.
        for key in albums.keys {
            albums[key]?.trackIDs.sort { lhsID, rhsID in
                guard let lhs = tracks[lhsID], let rhs = tracks[rhsID] else { return false }
                let lDisc = lhs.discNumber ?? 1
                let rDisc = rhs.discNumber ?? 1
                if lDisc != rDisc { return lDisc < rDisc }
                return (lhs.trackNumber ?? 0) < (rhs.trackNumber ?? 0)
            }
        }

        // Artists
        var artistMap: [String: Artist] = [:]
        for album in albumMap.values {
            let key = album.artist.lowercased()
            if var artist = artistMap[key] {
                if !artist.albumIDs.contains(album.id) { artist.albumIDs.append(album.id) }
                // Prefer an album that has artwork over one that doesn't.
                if artist.artworkCacheKey == nil { artist.artworkCacheKey = album.artworkCacheKey }
                artistMap[key] = artist
            } else {
                artistMap[key] = Artist(id: key, name: album.artist, albumIDs: [album.id],
                                        artworkCacheKey: album.artworkCacheKey)
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

extension Notification.Name {
    static let libraryDidChange = Notification.Name("net.mohome.kenopsia.libraryDidChange")
}
