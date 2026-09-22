import Foundation

// MARK: - DuplicateFinder
/// Finds tracks that are the same song stored more than once — the same album
/// ripped twice, or a track present in both a local folder and a NAS.
///
/// `LibraryStore` already dedupes by `TrackURI.stableKey` on rescan, so the same
/// *file* is never added twice. This catches the different-file case, which
/// needs tag matching instead.
///
/// Deliberately conservative: matching is by normalised artist + title, then
/// confirmed by duration. Aggressive normalisation (stripping "(Live)",
/// "(Remastered)", and so on) would collapse genuinely different recordings
/// into one group, and a false positive here means the user throws away a track
/// they wanted to keep.
enum DuplicateFinder {

    /// Seconds two copies may differ by and still count as the same recording.
    /// Encoders disagree slightly on padding and gapless trimming, so exact
    /// equality is too strict.
    static let defaultDurationTolerance: Double = 3

    // MARK: - Normalisation

    /// Case, accent, punctuation and "feat." differences are tagging noise, so
    /// they are folded away before comparison. Word order and content are not.
    static func normalize(_ raw: String) -> String {
        var s = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        // Drop featured-artist segments: they are routinely present on one rip
        // and absent on another. Handles "feat.", "ft.", "featuring", whether
        // parenthesised, bracketed or trailing after a dash.
        let featPatterns = [
            #"\s*[\(\[]\s*(feat|ft|featuring)\b[^\)\]]*[\)\]]"#,
            #"\s+-\s+(feat|ft|featuring)\b.*$"#,
            #"\s+(feat|ft|featuring)\.\s+.*$"#
        ]
        for pattern in featPatterns {
            s = s.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }

        // Punctuation carries no meaning for matching ("Don't" vs "Dont").
        s = s.replacingOccurrences(of: #"[\p{P}\p{S}]"#, with: "", options: .regularExpression)
        // Collapse runs of whitespace left behind by the removals above.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The grouping key for a track. Empty when there is not enough metadata to
    /// match on — those tracks are skipped rather than lumped together, since
    /// every untitled track would otherwise look like a duplicate of every other.
    static func matchKey(for track: Track) -> String? {
        let title = normalize(track.title)
        let artist = normalize(track.artist)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
        return "\(artist)\u{1F}\(title)"
    }

    // MARK: - Grouping

    /// Groups of two or more tracks that look like the same recording.
    ///
    /// Tracks are bucketed by `matchKey`, then each bucket is clustered by
    /// duration so that a studio cut and a ten-minute live version sharing a
    /// title do not end up in the same group.
    static func duplicateGroups(
        in tracks: [Track],
        durationTolerance: Double = defaultDurationTolerance
    ) -> [DuplicateGroup] {
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            guard let key = matchKey(for: track) else { continue }
            buckets[key, default: []].append(track)
        }

        var groups: [DuplicateGroup] = []
        for (key, candidates) in buckets where candidates.count > 1 {
            for cluster in clusterByDuration(candidates, tolerance: durationTolerance) where cluster.count > 1 {
                groups.append(DuplicateGroup(id: "\(key)#\(Int(cluster[0].durationSeconds))",
                                             tracks: cluster))
            }
        }

        // Most copies first, then alphabetical, so the biggest wins are on top.
        return groups.sorted {
            $0.tracks.count != $1.tracks.count
                ? $0.tracks.count > $1.tracks.count
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Splits tracks sharing a key into runs whose durations are within
    /// `tolerance` of the previous member.
    private static func clusterByDuration(_ tracks: [Track], tolerance: Double) -> [[Track]] {
        let sorted = tracks.sorted { $0.durationSeconds < $1.durationSeconds }
        var clusters: [[Track]] = []
        var current: [Track] = []
        for track in sorted {
            if let last = current.last, track.durationSeconds - last.durationSeconds > tolerance {
                clusters.append(current)
                current = [track]
            } else {
                current.append(track)
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }
}

// MARK: - DuplicateGroup
/// One set of tracks believed to be the same recording.
struct DuplicateGroup: Identifiable, Equatable {
    let id: String
    /// Sorted best-quality-first, so `tracks[0]` is the suggested keeper.
    var tracks: [Track]

    init(id: String, tracks: [Track]) {
        self.id = id
        self.tracks = tracks.sorted(by: DuplicateGroup.isHigherQuality)
    }

    var title: String { tracks.first?.title ?? "" }
    var artist: String { tracks.first?.artist ?? "" }

    /// The copy worth keeping: lossless beats lossy, then higher bitrate, then
    /// larger file. Only a suggestion — the user chooses.
    var suggestedKeeper: Track? { tracks.first }
    var redundantCopies: [Track] { Array(tracks.dropFirst()) }

    /// Bytes reclaimed by removing everything but the keeper. Tracks with an
    /// unknown file size contribute nothing rather than a guess.
    var reclaimableBytes: Int {
        redundantCopies.reduce(0) { $0 + ($1.fileSizeBytes ?? 0) }
    }

    private static func isHigherQuality(_ a: Track, _ b: Track) -> Bool {
        if a.isLossless != b.isLossless { return a.isLossless }
        let aRate = a.bitrateBps ?? 0
        let bRate = b.bitrateBps ?? 0
        if aRate != bRate { return aRate > bRate }
        return (a.fileSizeBytes ?? 0) > (b.fileSizeBytes ?? 0)
    }
}
