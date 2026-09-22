import Foundation
import Testing
@testable import Kenopsia

// MARK: - Helpers

private func dupTrack(
    title: String = "Song",
    artist: String = "Artist",
    format: AudioFormat = .mp3,
    durationSeconds: Double = 180,
    bitrateBps: Int? = nil,
    fileSizeBytes: Int? = nil
) -> Track {
    Track(
        title: title,
        artist: artist,
        source: MusicSourceID(),
        uri: .remoteURL(url: URL(string: "https://example.com/\(UUID().uuidString).mp3")!),
        format: format,
        durationSeconds: durationSeconds,
        fileSizeBytes: fileSizeBytes,
        bitrateBps: bitrateBps
    )
}

// MARK: - Normalisation

@Suite("Duplicate normalisation")
struct DuplicateNormalisationTests {

    @Test func foldsCaseAndDiacritics() {
        #expect(DuplicateFinder.normalize("Cafe\u{301} DEL MAR") == DuplicateFinder.normalize("café del mar"))
    }

    @Test func stripsPunctuation() {
        #expect(DuplicateFinder.normalize("Don't Stop!") == DuplicateFinder.normalize("Dont Stop"))
    }

    @Test func collapsesWhitespace() {
        #expect(DuplicateFinder.normalize("  Blue   Monday  ") == "blue monday")
    }

    @Test func stripsParentheticalFeature() {
        #expect(DuplicateFinder.normalize("Midnight (feat. Someone)") == DuplicateFinder.normalize("Midnight"))
    }

    @Test func stripsTrailingFeature() {
        #expect(DuplicateFinder.normalize("Midnight ft. Someone") == DuplicateFinder.normalize("Midnight"))
    }

    @Test func keepsDistinctTitlesDistinct() {
        #expect(DuplicateFinder.normalize("Live Forever") != DuplicateFinder.normalize("Life Forever"))
    }

    @Test func matchKeyIsNilWithoutEnoughMetadata() {
        #expect(DuplicateFinder.matchKey(for: dupTrack(title: "", artist: "Artist")) == nil)
        #expect(DuplicateFinder.matchKey(for: dupTrack(title: "Song", artist: "")) == nil)
        #expect(DuplicateFinder.matchKey(for: dupTrack()) != nil)
    }
}

// MARK: - Grouping

@Suite("Duplicate grouping")
struct DuplicateGroupingTests {

    @Test func findsTheSameSongStoredTwice() {
        let groups = DuplicateFinder.duplicateGroups(in: [
            dupTrack(title: "Blue Monday", artist: "New Order"),
            dupTrack(title: "blue monday!", artist: "new order"),
            dupTrack(title: "Ceremony", artist: "New Order")
        ])
        #expect(groups.count == 1)
        #expect(groups[0].tracks.count == 2)
    }

    @Test func ignoresUniqueTracks() {
        let groups = DuplicateFinder.duplicateGroups(in: [
            dupTrack(title: "A", artist: "X"),
            dupTrack(title: "B", artist: "X")
        ])
        #expect(groups.isEmpty)
    }

    @Test func sameTitleDifferentArtistIsNotADuplicate() {
        let groups = DuplicateFinder.duplicateGroups(in: [
            dupTrack(title: "Crazy", artist: "Gnarls Barkley"),
            dupTrack(title: "Crazy", artist: "Patsy Cline")
        ])
        #expect(groups.isEmpty)
    }

    @Test func durationSeparatesDifferentRecordings() {
        // A studio cut and a long live version share a title but are not copies.
        let groups = DuplicateFinder.duplicateGroups(in: [
            dupTrack(title: "Marquee Moon", artist: "Television", durationSeconds: 590),
            dupTrack(title: "Marquee Moon", artist: "Television", durationSeconds: 180)
        ])
        #expect(groups.isEmpty)
    }

    @Test func toleratesSmallDurationDrift() {
        let groups = DuplicateFinder.duplicateGroups(in: [
            dupTrack(title: "Teardrop", artist: "Massive Attack", durationSeconds: 330),
            dupTrack(title: "Teardrop", artist: "Massive Attack", durationSeconds: 331.5)
        ])
        #expect(groups.count == 1)
    }

    @Test func tracksWithoutMetadataAreSkipped() {
        // Otherwise every untitled track looks like a duplicate of every other.
        let groups = DuplicateFinder.duplicateGroups(in: [
            dupTrack(title: "", artist: ""),
            dupTrack(title: "", artist: "")
        ])
        #expect(groups.isEmpty)
    }

    @Test func groupsWithMostCopiesComeFirst() {
        let groups = DuplicateFinder.duplicateGroups(in: [
            dupTrack(title: "Twice", artist: "A"), dupTrack(title: "Twice", artist: "A"),
            dupTrack(title: "Thrice", artist: "B"), dupTrack(title: "Thrice", artist: "B"),
            dupTrack(title: "Thrice", artist: "B")
        ])
        #expect(groups.count == 2)
        #expect(groups[0].tracks.count == 3)
    }
}

// MARK: - Keeper selection

@Suite("Duplicate keeper selection")
struct DuplicateKeeperTests {

    @Test func losslessBeatsLossy() {
        let group = DuplicateGroup(id: "k", tracks: [
            dupTrack(format: .mp3, bitrateBps: 320_000),
            dupTrack(format: .flac, bitrateBps: 900_000)
        ])
        #expect(group.suggestedKeeper?.format == .flac)
        #expect(group.redundantCopies.count == 1)
    }

    @Test func higherBitrateWinsWithinSameQualityTier() {
        let group = DuplicateGroup(id: "k", tracks: [
            dupTrack(format: .mp3, bitrateBps: 128_000),
            dupTrack(format: .mp3, bitrateBps: 320_000)
        ])
        #expect(group.suggestedKeeper?.bitrateBps == 320_000)
    }

    @Test func fileSizeBreaksTies() {
        let group = DuplicateGroup(id: "k", tracks: [
            dupTrack(format: .mp3, bitrateBps: 320_000, fileSizeBytes: 5_000_000),
            dupTrack(format: .mp3, bitrateBps: 320_000, fileSizeBytes: 9_000_000)
        ])
        #expect(group.suggestedKeeper?.fileSizeBytes == 9_000_000)
    }

    @Test func reclaimableBytesCountsOnlyRedundantCopies() {
        let group = DuplicateGroup(id: "k", tracks: [
            dupTrack(format: .flac, fileSizeBytes: 30_000_000),
            dupTrack(format: .mp3, fileSizeBytes: 5_000_000),
            dupTrack(format: .mp3, fileSizeBytes: 4_000_000)
        ])
        #expect(group.reclaimableBytes == 9_000_000)
    }

    @Test func unknownFileSizesContributeNothing() {
        let group = DuplicateGroup(id: "k", tracks: [
            dupTrack(format: .flac, fileSizeBytes: 30_000_000),
            dupTrack(format: .mp3, fileSizeBytes: nil)
        ])
        #expect(group.reclaimableBytes == 0)
    }
}
