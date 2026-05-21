import Foundation
import Testing
@testable import Kenopsia

// MARK: - Helpers

private func track(
    title: String = "Song",
    artist: String = "Artist",
    album: String = "Album",
    genre: String = "Rock",
    year: Int? = 2020,
    format: AudioFormat = .mp3,
    playCount: Int = 0,
    rating: Int = 0,
    isFavourited: Bool = false,
    isExplicit: Bool = false,
    bpm: Double? = nil,
    bitrateBps: Int? = nil,
    sampleRateHz: Int? = nil,
    durationSeconds: Double = 180,
    isLossless: Bool = false,
    lastPlayedAt: Date? = nil,
    dateAdded: Date = .now
) -> Track {
    Track(
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        source: MusicSourceID(),
        uri: .remoteURL(url: URL(string: "https://example.com/song.mp3")!),
        format: format,
        durationSeconds: durationSeconds,
        bitrateBps: bitrateBps,
        sampleRateHz: sampleRateHz,
        playCount: playCount,
        lastPlayedAt: lastPlayedAt,
        dateAdded: dateAdded,
        isFavourited: isFavourited,
        isExplicit: isExplicit,
        bpm: bpm,
        rating: rating
    )
}

private func rule(_ field: SmartPlaylistField, _ condition: SmartPlaylistCondition, _ value: String) -> SmartPlaylistRule {
    SmartPlaylistRule(field: field, condition: condition, value: value)
}

private func eval(_ rule: SmartPlaylistRule, _ track: Track) -> Bool {
    SmartPlaylistEvaluator.evaluate(rule: rule, track: track)
}

// MARK: - String fields

@Suite("String fields")
struct StringFieldTests {

    @Test func titleContains() {
        #expect(eval(rule(.title, .contains, "Song"), track(title: "A Song")))
        #expect(!eval(rule(.title, .contains, "xyz"), track(title: "A Song")))
    }

    @Test func titleIs() {
        #expect(eval(rule(.title, .is_, "a song"), track(title: "A Song")))
        #expect(!eval(rule(.title, .is_, "other"), track(title: "A Song")))
    }

    @Test func artistStartsWith() {
        #expect(eval(rule(.artist, .startsWith, "The"), track(artist: "The Beatles")))
        #expect(!eval(rule(.artist, .startsWith, "Bea"), track(artist: "The Beatles")))
    }

    @Test func genreDoesNotContain() {
        #expect(eval(rule(.genre, .doesNotContain, "Jazz"), track(genre: "Rock")))
        #expect(!eval(rule(.genre, .doesNotContain, "Rock"), track(genre: "Rock")))
    }
}

// MARK: - Numeric fields

@Suite("Numeric fields")
struct NumericFieldTests {

    @Test func yearGreaterThan() {
        #expect(eval(rule(.year, .isGreaterThan, "2019"), track(year: 2020)))
        #expect(!eval(rule(.year, .isGreaterThan, "2020"), track(year: 2020)))
    }

    @Test func yearLessThan() {
        #expect(eval(rule(.year, .isLessThan, "2021"), track(year: 2020)))
        #expect(!eval(rule(.year, .isLessThan, "2020"), track(year: 2020)))
    }

    @Test func yearEquals() {
        #expect(eval(rule(.year, .is_, "2020"), track(year: 2020)))
        #expect(!eval(rule(.year, .is_, "2019"), track(year: 2020)))
    }

    @Test func yearNotEqual() {
        #expect(eval(rule(.year, .isNot, "2019"), track(year: 2020)))
        #expect(!eval(rule(.year, .isNot, "2020"), track(year: 2020)))
    }

    @Test func ratingEquals() {
        #expect(eval(rule(.rating, .is_, "5"), track(rating: 5)))
        #expect(!eval(rule(.rating, .is_, "5"), track(rating: 4)))
    }

    @Test func playCountGreaterThan() {
        #expect(eval(rule(.playCount, .isGreaterThan, "9"), track(playCount: 10)))
        #expect(!eval(rule(.playCount, .isGreaterThan, "10"), track(playCount: 10)))
    }

    @Test func bpmLessThan() {
        #expect(eval(rule(.bpm, .isLessThan, "120"), track(bpm: 90)))
        #expect(!eval(rule(.bpm, .isLessThan, "90"), track(bpm: 90)))
    }

    @Test func bitrateGreaterThan() {
        #expect(eval(rule(.bitrateBps, .isGreaterThan, "192000"), track(bitrateBps: 320000)))
        #expect(!eval(rule(.bitrateBps, .isGreaterThan, "320000"), track(bitrateBps: 320000)))
    }

    @Test func sampleRateEquals() {
        #expect(eval(rule(.sampleRateHz, .is_, "44100"), track(sampleRateHz: 44100)))
        #expect(!eval(rule(.sampleRateHz, .is_, "48000"), track(sampleRateHz: 44100)))
    }

    @Test func durationLessThan() {
        #expect(eval(rule(.durationSeconds, .isLessThan, "200"), track(durationSeconds: 180)))
        #expect(!eval(rule(.durationSeconds, .isLessThan, "180"), track(durationSeconds: 180)))
    }
}

// MARK: - Boolean fields

@Suite("Boolean fields")
struct BoolFieldTests {

    @Test func isFavouritedTrue() {
        #expect(eval(rule(.isFavourited, .isTrue, ""), track(isFavourited: true)))
        #expect(!eval(rule(.isFavourited, .isTrue, ""), track(isFavourited: false)))
    }

    @Test func isExplicitFalse() {
        #expect(eval(rule(.isExplicit, .isFalse, ""), track(isExplicit: false)))
        #expect(!eval(rule(.isExplicit, .isFalse, ""), track(isExplicit: true)))
    }

    @Test func isLosslessTrue() {
        #expect(eval(rule(.isLossless, .isTrue, ""), track(format: .flac)))
        #expect(!eval(rule(.isLossless, .isTrue, ""), track(format: .mp3)))
    }
}

// MARK: - Date fields

@Suite("Date fields")
struct DateFieldTests {

    @Test func dateAddedInTheLast7Days() {
        let recent = Date().addingTimeInterval(-3 * 86400)  // 3 days ago
        let old    = Date().addingTimeInterval(-10 * 86400) // 10 days ago
        #expect(eval(rule(.dateAdded, .isInTheLast, "7"),  track(dateAdded: recent)))
        #expect(!eval(rule(.dateAdded, .isInTheLast, "7"), track(dateAdded: old)))
    }

    @Test func lastPlayedNotInTheLast30Days() {
        let recent = Date().addingTimeInterval(-5 * 86400)
        let old    = Date().addingTimeInterval(-40 * 86400)
        #expect(eval(rule(.lastPlayed, .isNotInTheLast, "30"),  track(lastPlayedAt: old)))
        #expect(!eval(rule(.lastPlayed, .isNotInTheLast, "30"), track(lastPlayedAt: recent)))
    }
}

// MARK: - Playlist rule operator

@Suite("Playlist rule operator")
struct PlaylistRuleOperatorTests {

    @Test func matchAll_bothMustPass() {
        let t = track(artist: "Radiohead", year: 2000)
        let r1 = rule(.artist, .contains, "Radiohead")
        let r2 = rule(.year, .isGreaterThan, "2005")  // fails
        // Using resolve logic inline since LibraryViewModel is @MainActor
        let results = [r1, r2].map { SmartPlaylistEvaluator.evaluate(rule: $0, track: t) }
        #expect(!results.allSatisfy { $0 })  // not all pass
        #expect(results.contains { $0 })     // at least one passes
    }
}
