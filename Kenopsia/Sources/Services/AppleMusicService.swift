import Foundation
import MusicKit

// MARK: - AppleMusicService
/// MusicSourceAdapter that integrates with the user's Apple Music library
/// and the Apple Music catalogue via MusicKit.
///
/// Playback is delegated to ApplicationMusicPlayer (see PlaybackService);
/// this service only handles authorisation and library scanning.
actor AppleMusicService: MusicSourceAdapter {
    let sourceID: MusicSourceID
    private let config: AppleMusicSourceConfig

    init(sourceID: MusicSourceID, config: AppleMusicSourceConfig) {
        self.sourceID = sourceID
        self.config = config
    }

    // MARK: - Authorisation

    /// Requests MusicKit access if not already granted.
    /// Returns true when the app is authorised to read the music library.
    static func requestAuthorisation() async -> Bool {
        let status = await MusicAuthorization.request()
        return status == .authorized
    }

    static var authorizationStatus: MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }

    // MARK: - MusicSourceAdapter

    /// Fetches all songs from the user's Apple Music library and maps them to Track.
    func fetchTracks() async throws -> [Track] {
        guard MusicAuthorization.currentStatus == .authorized else {
            throw SourceError.authenticationFailed
        }

        var request = MusicLibraryRequest<Song>()
        request.sort(by: \.title, ascending: true)
        let response = try await request.response()

        return response.items.map { Self.track(from: $0, sourceID: sourceID) }
    }

    // MARK: - Song lookup for playback

    /// Looks up a single library song by its MusicItemID for playback.
    static func song(for musicItemID: MusicItemID) async throws -> Song? {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, equalTo: musicItemID)
        let response = try await request.response()
        return response.items.first
    }

    // MARK: - Mapping

    private static func track(from song: Song, sourceID: MusicSourceID) -> Track {
        Track(
            title:           song.title,
            artist:          song.artistName,
            albumArtist:     song.artistName,
            album:           song.albumTitle ?? "",
            genre:           song.genreNames.first ?? "",
            year:            song.releaseDate.flatMap { Calendar.current.component(.year, from: $0) as Int? },
            trackNumber:     song.trackNumber,
            discNumber:      song.discNumber,
            composer:        song.composerName ?? "",
            comment:         "",
            source:          sourceID,
            uri:             .appleMusicID(id: song.id.rawValue),
            format:          .m4a,          // Apple Music streams are AAC / ALAC in M4A container
            durationSeconds: song.duration ?? 0,
            fileSizeBytes:   nil,
            bitrateBps:      nil,
            sampleRateHz:    nil,
            bitDepth:        nil,
            channelCount:    nil,
            artworkCacheKey: "applemusic:\(song.id.rawValue)",
            replayGainTrack: nil,
            replayGainAlbum: nil
        )
    }

    // MARK: - Artwork

    /// Fetches and caches the artwork for a MusicKit song.
    static func cacheArtwork(for song: Song, key: String) async {
        guard let artwork = song.artwork else { return }
        let size = CGSize(width: 600, height: 600)
        guard let url = artwork.url(width: Int(size.width), height: Int(size.height)),
              let data = try? Data(contentsOf: url) else { return }
        ArtworkCache.shared.store(imageData: data, forKey: key)
    }
}
