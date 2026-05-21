import Foundation
import Combine

// MARK: - PlayerViewModel
/// The single @EnvironmentObject for all playback UI.
/// Thin bridge between PlaybackService and the SwiftUI layer.
@MainActor
final class PlayerViewModel: ObservableObject {
    // MARK: - Published (forwarded from PlaybackService)
    @Published var state = PlayerState()
    @Published var queue = Queue()
    @Published var lyrics: [LyricsLine] = []
    @Published var eqPreset: EQPreset = .flat
    @Published var showingNowPlaying = false
    @Published var showingQueue = false

    // MARK: - Services
    private let playback: PlaybackService
    private var cancellables = Set<AnyCancellable>()

    init(playback: PlaybackService? = nil) {
        self.playback = playback ?? PlaybackService.shared
        bind()
    }

    // MARK: - Playback commands (forwarded to service)
    func togglePlayPause() { playback.togglePlayPause() }
    func next()            { playback.next() }
    func previous()        { playback.previous() }
    func seek(to seconds: Double) { playback.seek(to: seconds) }

    func toggleFavourite() { toggleFavourite(track: queue.currentTrack) }

    func toggleFavourite(track: Track?) {
        guard let track,
              let idx = queue.tracks.firstIndex(where: { $0.id == track.id }) else { return }
        queue.tracks[idx].isFavourited.toggle()
        LibraryStore.shared.update(track: queue.tracks[idx])
    }

    var meterLevels: [Float] { playback.meterLevels }

    func play(track: Track) {
        playback.enqueue(tracks: [track], playImmediately: true)
    }

    func play(tracks: [Track], startAt index: Int = 0) {
        playback.replace(with: tracks, startAt: index)
    }

    /// Jump to a specific index within the current queue without rebuilding it.
    func skipTo(index: Int) {
        playback.skipTo(index: index)
    }

    func enqueueNext(_ track: Track)  { playback.enqueue(track) }
    func enqueueLast(_ track: Track) { queue.enqueueLast(track) }

    /// Clear the queue and stop all playback.
    func clearQueue() {
        playback.stop()
        queue.replace(with: [])
    }

    func apply(eqPreset preset: EQPreset) { playback.apply(preset: preset) }

    // MARK: - Binding
    private func bind() {
        playback.$state.assign(to: &$state)
        playback.$queue.assign(to: &$queue)
        playback.$currentLyrics.assign(to: &$lyrics)
        playback.$currentEQPreset.assign(to: &$eqPreset)
        // Queue is a class; its internal @Published properties don't propagate through
        // our @Published var queue wrapper. Forward its objectWillChange so SwiftUI
        // views that read queue.currentTrack, queue.tracks, etc. always re-render.
        playback.queue.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }
}
