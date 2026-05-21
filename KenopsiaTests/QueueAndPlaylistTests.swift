import Foundation
import Testing
@testable import Kenopsia

// MARK: - Helpers

private func makeTrack(title: String, artist: String = "Artist") -> Track {
    Track(
        title: title,
        artist: artist,
        source: MusicSourceID(),
        uri: .remoteURL(url: URL(string: "https://example.com/song.mp3")!),
        format: .mp3,
        durationSeconds: 180
    )
}

// MARK: - Navigation

@Suite("Queue navigation")
struct QueueNavigationTests {

    @Test func nextIndexLinear() {
        let q = Queue()
        let tracks = (1...3).map { makeTrack(title: "Track \($0)") }
        q.replace(with: tracks, startAt: 0)
        #expect(q.nextIndex == 1)
        q.moveToNext()
        #expect(q.currentIndex == 1)
        #expect(q.nextIndex == 2)
        q.moveToNext()
        #expect(q.nextIndex == nil)  // end of queue, repeat off
    }

    @Test func nextIndexRepeatAll() {
        let q = Queue()
        q.replace(with: (1...3).map { makeTrack(title: "T\($0)") }, startAt: 2)
        q.repeatMode = .all
        #expect(q.nextIndex == 0)    // wraps around
    }

    @Test func nextIndexRepeatOne() {
        let q = Queue()
        q.replace(with: [makeTrack(title: "Only")], startAt: 0)
        q.repeatMode = .one
        #expect(q.nextIndex == 0)
    }

    @Test func previousClampsAtZero() {
        let q = Queue()
        q.replace(with: [makeTrack(title: "A"), makeTrack(title: "B")], startAt: 0)
        q.moveToPrevious()
        #expect(q.currentIndex == 0)  // stays at 0
    }

    @Test func previousMovesBack() {
        let q = Queue()
        q.replace(with: [makeTrack(title: "A"), makeTrack(title: "B")], startAt: 1)
        q.moveToPrevious()
        #expect(q.currentIndex == 0)
    }
}

// MARK: - Mutations

@Suite("Queue mutations")
struct QueueMutationTests {

    @Test func enqueueInsertsAfterCurrent() {
        let q = Queue()
        let a = makeTrack(title: "A")
        let b = makeTrack(title: "B")
        let c = makeTrack(title: "C")
        q.replace(with: [a, c], startAt: 0)
        q.enqueue(b)
        // After current (index 0): [A, B, C]
        #expect(q.tracks[1].title == "B")
    }

    @Test func enqueueLastAppendsToEnd() {
        let q = Queue()
        let a = makeTrack(title: "A")
        let z = makeTrack(title: "Z")
        q.replace(with: [a], startAt: 0)
        q.enqueueLast(z)
        #expect(q.tracks.last?.title == "Z")
    }

    @Test func removeUpdateCurrentIndex() {
        let q = Queue()
        let tracks = (1...4).map { makeTrack(title: "T\($0)") }
        q.replace(with: tracks, startAt: 2)  // playing T3
        q.remove(at: IndexSet(integer: 0))   // remove T1
        #expect(q.currentIndex == 1)          // T3 shifted from idx 2 to idx 1
        #expect(q.currentTrack?.title == "T3")
    }

    @Test func replaceResetsIndex() {
        let q = Queue()
        q.replace(with: [makeTrack(title: "Old")], startAt: 0)
        q.replace(with: [makeTrack(title: "A"), makeTrack(title: "B")], startAt: 1)
        #expect(q.currentIndex == 1)
        #expect(q.currentTrack?.title == "B")
    }
}

// MARK: - Codable round-trip

@Suite("Queue Codable")
struct QueueCodableTests {

    @Test func roundTrip() throws {
        let q = Queue()
        let tracks = (1...3).map { makeTrack(title: "T\($0)") }
        q.replace(with: tracks, startAt: 1)
        q.repeatMode = .all

        let data = try JSONEncoder().encode(q)
        let restored = try JSONDecoder().decode(Queue.self, from: data)

        #expect(restored.currentIndex == 1)
        #expect(restored.repeatMode == .all)
        #expect(restored.tracks.count == 3)
        #expect(restored.currentTrack?.title == "T2")
    }

    @Test func shuffleOrderPreserved() throws {
        let q = Queue()
        q.replace(with: (1...5).map { makeTrack(title: "T\($0)") }, startAt: 0)
        q.toggleShuffle()
        #expect(q.shuffleMode == .on)
        // nextIndex should always be non-nil when shuffle is on (there are unplayed tracks)
        #expect(q.nextIndex != nil)

        let data = try JSONEncoder().encode(q)
        let restored = try JSONDecoder().decode(Queue.self, from: data)

        #expect(restored.shuffleMode == .on)
        // Shuffle next should still be available after restore
        #expect(restored.nextIndex != nil)
    }
}

// MARK: - Playlist Codable

@Suite("Playlist Codable")
struct PlaylistCodableTests {

    @Test func manualRoundTrip() throws {
        var p = Playlist(name: "Favourites")
        let id = UUID()
        p.trackIDs = [id]

        let data = try JSONEncoder().encode(p)
        let restored = try JSONDecoder().decode(Playlist.self, from: data)

        #expect(restored.name == "Favourites")
        #expect(restored.kind == .manual)
        #expect(restored.trackIDs == [id])
    }

    @Test func smartRoundTrip() throws {
        var p = Playlist(name: "Hi-Res", kind: .smart)
        p.ruleOperator = .all
        p.rules = [SmartPlaylistRule(field: .bitrateBps, condition: .isGreaterThan, value: "320000")]
        p.limit = SmartPlaylistLimit(count: 50, sortBy: .recentlyAdded)

        let data = try JSONEncoder().encode(p)
        let restored = try JSONDecoder().decode(Playlist.self, from: data)

        #expect(restored.kind == .smart)
        #expect(restored.rules.count == 1)
        #expect(restored.rules[0].field == .bitrateBps)
        #expect(restored.limit?.count == 50)
        #expect(restored.limit?.sortBy == .recentlyAdded)
    }
}
