import Foundation

// MARK: - GenreIndex
/// Groups tracks by genre tag.
///
/// `LibraryStore` maintains indexes for albums and artists but not genres, so
/// these are derived on demand. Shared by the library UI and CarPlay so the two
/// can't drift apart on what counts as a genre.
enum GenreIndex {

    /// Tracks bucketed by genre, ignoring blank tags. Keys are trimmed but
    /// otherwise left exactly as tagged — "Hip-Hop" and "Hip Hop" stay separate,
    /// because collapsing them would mean guessing at the user's taxonomy.
    static func buckets(in tracks: some Collection<Track>) -> [String: [Track]] {
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            let genre = track.genre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !genre.isEmpty else { continue }
            buckets[genre, default: []].append(track)
        }
        return buckets
    }

    /// Genres in display order: alphabetical, each with its tracks sorted by title.
    static func sortedGenres(in tracks: some Collection<Track>) -> [Genre] {
        buckets(in: tracks)
            .map { name, tracks in
                Genre(name: name, tracks: tracks.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                })
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Genre
struct Genre: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let tracks: [Track]
}
