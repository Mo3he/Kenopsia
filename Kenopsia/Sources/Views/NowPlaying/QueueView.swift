import SwiftUI

// MARK: - QueueView
/// Editable now-playing queue. Supports reorder and swipe-to-remove.
struct QueueView: View {
    @EnvironmentObject var player: PlayerViewModel

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.tracks.enumerated()), id: \.element.id) { i, track in
                    QueueRowView(
                        track: track,
                        isCurrent: i == player.queue.currentIndex,
                        index: i
                    )
                    .listRowBackground(i == player.queue.currentIndex
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear)
                    .onTapGesture {
                        player.skipTo(index: i)
                    }
                }
                .onDelete { player.queue.remove(at: $0) }
                .onMove { player.queue.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.kBackground.ignoresSafeArea())
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.kBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear") { player.clearQueue() }
                        .disabled(player.queue.tracks.isEmpty)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
    }
}

struct QueueRowView: View {
    let track: Track
    let isCurrent: Bool
    let index: Int

    var body: some View {
        HStack(spacing: 12) {
            MiniArtworkView(cacheKey: track.artworkCacheKey)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.subheadline.weight(isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "waveform")
                    .foregroundStyle(Color.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }
            Text(formatDuration(track.durationSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
