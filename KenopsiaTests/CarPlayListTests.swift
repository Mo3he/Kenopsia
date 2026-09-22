import CarPlay
import Foundation
import Testing
@testable import Kenopsia

private func cpTrack(genre: String = "Rock") -> Track {
    Track(
        title: "Song",
        artist: "Artist",
        genre: genre,
        source: MusicSourceID(),
        uri: .remoteURL(url: URL(string: "https://example.com/\(UUID().uuidString).mp3")!),
        format: .mp3,
        durationSeconds: 180
    )
}

@Suite("CarPlay list truncation")
@MainActor
struct CarPlayTruncationTests {

    @Test func shortListsArePassedThroughUntouched() {
        let all = Array(1...5)
        let (shown, hidden) = CarPlaySceneDelegate.limitedForDisplay(all)
        #expect(shown.count == 5)
        #expect(hidden == 0)
    }

    @Test func aListExactlyAtTheCapIsNotTrimmed() {
        let all = Array(1...CPListTemplate.maximumItemCount)
        let (shown, hidden) = CarPlaySceneDelegate.limitedForDisplay(all)
        #expect(shown.count == CPListTemplate.maximumItemCount)
        #expect(hidden == 0)
    }

    /// The notice row counts toward `maximumItemCount`, which applies to the
    /// whole template rather than to each section. Taking a full cap's worth and
    /// then appending the notice would put the template one row over the limit.
    @Test func trimmingReservesARowForTheNotice() {
        let all = Array(1...(CPListTemplate.maximumItemCount + 50))
        let (shown, hidden) = CarPlaySceneDelegate.limitedForDisplay(all)
        #expect(shown.count == CPListTemplate.maximumItemCount - 1)
        #expect(shown.count + 1 <= CPListTemplate.maximumItemCount)
        #expect(hidden == 51)
    }

    @Test func hiddenCountAccountsForEveryDroppedRow() {
        let total = CPListTemplate.maximumItemCount + 1
        let (shown, hidden) = CarPlaySceneDelegate.limitedForDisplay(Array(1...total))
        #expect(shown.count + hidden == total)
    }

    @Test func emptyListsAreHandled() {
        let (shown, hidden) = CarPlaySceneDelegate.limitedForDisplay([Int]())
        #expect(shown.isEmpty)
        #expect(hidden == 0)
    }
}

@Suite("CarPlay genre buckets")
@MainActor
struct CarPlayGenreTests {

    @Test func groupsTracksByGenre() {
        let buckets = CarPlaySceneDelegate.genreBuckets(in: [
            cpTrack(genre: "Rock"), cpTrack(genre: "Rock"), cpTrack(genre: "Jazz")
        ])
        #expect(buckets.count == 2)
        #expect(buckets["Rock"]?.count == 2)
        #expect(buckets["Jazz"]?.count == 1)
    }

    @Test func blankGenresAreIgnored() {
        let buckets = CarPlaySceneDelegate.genreBuckets(in: [
            cpTrack(genre: ""), cpTrack(genre: "   "), cpTrack(genre: "Rock")
        ])
        #expect(buckets.count == 1)
        #expect(buckets["Rock"]?.count == 1)
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let buckets = CarPlaySceneDelegate.genreBuckets(in: [
            cpTrack(genre: "Rock"), cpTrack(genre: "  Rock  ")
        ])
        #expect(buckets.count == 1)
        #expect(buckets["Rock"]?.count == 2)
    }

    @Test func noTracksMeansNoGenres() {
        #expect(CarPlaySceneDelegate.genreBuckets(in: [Track]()).isEmpty)
    }
}
