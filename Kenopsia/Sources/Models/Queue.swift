import Foundation

// MARK: - Queue
/// The active playback queue. Tracks can come from any source.
/// This is the "source-agnostic queue" differentiator.
final class Queue: ObservableObject, Codable {
    /// All tracks in queue order.
    @Published var tracks: [Track] = []
    /// Index of the currently playing (or about-to-play) track.
    @Published var currentIndex: Int = 0
    /// Shuffle state — mirrors shuffledOrder when active.
    @Published var shuffleMode: ShuffleMode = .off
    /// Repeat state.
    @Published var repeatMode: RepeatMode = .off

    private var shuffledOrder: [Int] = []   // indices into `tracks`

    // MARK: - Computed
    var currentTrack: Track? {
        guard !tracks.isEmpty, tracks.indices.contains(currentIndex) else { return nil }
        return tracks[currentIndex]
    }

    var nextTrack: Track? {
        let next = nextIndex
        guard let next, tracks.indices.contains(next) else { return nil }
        return tracks[next]
    }

    var nextIndex: Int? {
        if shuffleMode == .on, !shuffledOrder.isEmpty {
            guard let pos = shuffledOrder.firstIndex(of: currentIndex) else { return nil }
            let nextPos = pos + 1
            if nextPos < shuffledOrder.count { return shuffledOrder[nextPos] }
            return repeatMode == .all ? shuffledOrder.first : nil
        }
        switch repeatMode {
        case .one:  return currentIndex
        case .all:  return (currentIndex + 1) % max(tracks.count, 1)
        case .off:
            let next = currentIndex + 1
            return next < tracks.count ? next : nil
        }
    }

    // MARK: - Mutations
    func play(track: Track) {
        if let idx = tracks.firstIndex(of: track) {
            currentIndex = idx
        } else {
            tracks.insert(track, at: currentIndex + 1)
            currentIndex += 1
        }
    }

    func enqueue(_ track: Track) {
        let insertAt = min(currentIndex + 1, tracks.count)
        tracks.insert(track, at: insertAt)
    }

    func enqueueLast(_ track: Track) {
        tracks.append(track)
    }

    func enqueue(tracks newTracks: [Track], playImmediately: Bool = false) {
        if playImmediately {
            let insertAt = min(currentIndex + 1, tracks.count)
            tracks.insert(contentsOf: newTracks, at: insertAt)
            currentIndex = insertAt
        } else {
            tracks.append(contentsOf: newTracks)
        }
    }

    func replace(with newTracks: [Track], startAt index: Int = 0) {
        tracks = newTracks
        currentIndex = index.clamped(to: 0 ..< max(newTracks.count, 1))
        if shuffleMode != .off { rebuildShuffle() }
    }

    func remove(at offsets: IndexSet) {
        let wasPlaying = offsets.contains(currentIndex)
        tracks.remove(atOffsets: offsets)
        if wasPlaying {
            currentIndex = currentIndex.clamped(to: 0 ..< max(tracks.count, 1))
        } else {
            let removed = offsets.filter { $0 < currentIndex }.count
            currentIndex = max(0, currentIndex - removed)
        }
        if shuffleMode == .on { rebuildShuffle() }
    }

    /// Move tracks within the queue (drag-and-drop reorder).
    /// Also updates shuffledOrder so shuffle doesn't reference stale indices.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let playingID = currentTrack?.id
        tracks.move(fromOffsets: source, toOffset: destination)
        // Re-locate the current track after the move.
        if let id = playingID, let newIdx = tracks.firstIndex(where: { $0.id == id }) {
            currentIndex = newIdx
        }
        if shuffleMode == .on { rebuildShuffle() }
    }

    func moveToNext() {
        guard let next = nextIndex else { return }
        currentIndex = next
    }

    func moveToPrevious() {
        if repeatMode == .one { return }
        if shuffleMode == .on, !shuffledOrder.isEmpty,
           let pos = shuffledOrder.firstIndex(of: currentIndex), pos > 0 {
            currentIndex = shuffledOrder[pos - 1]
            return
        }
        if currentIndex == 0 { return }
        currentIndex -= 1
    }

    func toggleShuffle() {
        shuffleMode = shuffleMode == .off ? .on : .off
        if shuffleMode == .on { rebuildShuffle() }
    }

    /// Restore all queue state from a decoded queue (used at app launch to resume where the user left off).
    /// This copies the internal shuffledOrder so the shuffle position is preserved across launches.
    func restore(from other: Queue) {
        tracks = other.tracks
        currentIndex = other.currentIndex
        shuffleMode = other.shuffleMode
        repeatMode = other.repeatMode
        shuffledOrder = other.shuffledOrder
    }

    // MARK: - Shuffle helpers
    private func rebuildShuffle() {
        var order = Array(tracks.indices)
        order.remove(at: currentIndex)
        order.shuffle()
        shuffledOrder = [currentIndex] + order
    }

    // MARK: - Codable (manual because @Published + generic)
    enum CodingKeys: String, CodingKey {
        case tracks, currentIndex, shuffleMode, repeatMode, shuffledOrder
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = try c.decode([Track].self, forKey: .tracks)
        currentIndex = try c.decode(Int.self, forKey: .currentIndex)
        shuffleMode = try c.decode(ShuffleMode.self, forKey: .shuffleMode)
        repeatMode = try c.decode(RepeatMode.self, forKey: .repeatMode)
        shuffledOrder = (try? c.decode([Int].self, forKey: .shuffledOrder)) ?? []
        // If shuffle is on but order wasn't persisted (legacy data), rebuild it.
        if shuffleMode == .on && shuffledOrder.isEmpty && !tracks.isEmpty {
            rebuildShuffle()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tracks, forKey: .tracks)
        try c.encode(currentIndex, forKey: .currentIndex)
        try c.encode(shuffleMode, forKey: .shuffleMode)
        try c.encode(repeatMode, forKey: .repeatMode)
        try c.encode(shuffledOrder, forKey: .shuffledOrder)
    }
}

// MARK: - Modes
enum ShuffleMode: String, Codable { case off, on }
enum RepeatMode: String, Codable  { case off, one, all }

// MARK: - Clamp helper (avoids importing Darwin just for this)
private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1))
    }
}
