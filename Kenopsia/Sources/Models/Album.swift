import Foundation

/// An album assembled from the library — derived from tracks, never stored independently.
struct Album: Identifiable, Hashable {
    let id: String   // "\(albumArtist)//\(album)" — stable across rescans

    var title: String
    var artist: String      // album artist
    var year: Int?
    var genre: String
    var trackIDs: [UUID]    // ordered by disc + track number
    var artworkCacheKey: String?

    var trackCount: Int { trackIDs.count }
}

/// An artist assembled from the library — derived, never stored independently.
struct Artist: Identifiable, Hashable {
    let id: String           // normalised artist name
    var name: String
    var albumIDs: [String]
    var artworkCacheKey: String?   // artist banner (MusicBrainz / Last.fm)
}
