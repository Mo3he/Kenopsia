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
    func setVolume(_ v: Float)    { playback.setVolume(v) }

    func play(track: Track) {
        playback.enqueue(tracks: [track], playImmediately: true)
    }

    func play(tracks: [Track], startAt index: Int = 0) {
        playback.replace(with: tracks, startAt: index)
    }

    func enqueueNext(_ track: Track)  { playback.enqueue(track) }

    func apply(eqPreset preset: EQPreset) { playback.apply(preset: preset) }

    // MARK: - Binding
    private func bind() {
        playback.$state.assign(to: &$state)
        playback.$queue.assign(to: &$queue)
        playback.$currentLyrics.assign(to: &$lyrics)
        playback.$currentEQPreset.assign(to: &$eqPreset)
    }
}
