import SwiftUI

// MARK: - DuplicateFinderView
/// Lists songs stored more than once and lets the user drop the copies they
/// don't want.
///
/// Nothing is removed automatically. Each group suggests a keeper — the
/// highest-quality copy — but the user decides, and removal takes the track out
/// of the library index only. `LibraryStore.delete(trackID:)` does not touch
/// the file on disk, which is why every label here says "Remove from library"
/// rather than "Delete".
struct DuplicateFinderView: View {
    @EnvironmentObject var library: LibraryViewModel
    @EnvironmentObject var sources: SourceViewModel
    @EnvironmentObject var player: PlayerViewModel

    @State private var groups: [DuplicateGroup] = []
    @State private var isScanning = false
    @State private var confirmingCleanUp = false
    @State private var removedCount = 0

    var body: some View {
        Group {
            if isScanning {
                ProgressView("Scanning library…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView(
                    "No Duplicates",
                    systemImage: "checkmark.seal.fill",
                    description: Text(removedCount > 0
                                      ? "Removed \(removedCount) \(removedCount == 1 ? "copy" : "copies")."
                                      : "Every song in your library appears once.")
                )
            } else {
                groupList
            }
        }
        .navigationTitle("Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await scan() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isScanning)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !groups.isEmpty { cleanUpBar }
        }
        .confirmationDialog(
            "Remove \(totalRedundant) \(totalRedundant == 1 ? "copy" : "copies")?",
            isPresented: $confirmingCleanUp,
            titleVisibility: .visible
        ) {
            Button("Remove \(totalRedundant) from Library", role: .destructive) { cleanUpAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Keeps the highest-quality copy of each song. This removes the others from your library — the files themselves are left alone.")
        }
        .task { await scan() }
    }

    // MARK: - Summary

    private var totalRedundant: Int {
        groups.reduce(0) { $0 + $1.redundantCopies.count }
    }

    private var totalReclaimable: Int {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    private var cleanUpBar: some View {
        VStack(spacing: 8) {
            Text("\(groups.count) \(groups.count == 1 ? "song" : "songs") with duplicates · \(totalRedundant) extra \(totalRedundant == 1 ? "copy" : "copies")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if totalReclaimable > 0 {
                Text("About \(formattedBytes(totalReclaimable)) of files would become unreferenced.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                confirmingCleanUp = true
            } label: {
                Text("Keep Best, Remove the Rest")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        // Clear the mini player, which floats above the tab bar whenever
        // something is loaded. Without this the action button is completely
        // hidden behind it.
        .padding(.bottom, player.state.status != .stopped ? 66 : 0)
        .background(.regularMaterial)
    }

    // MARK: - List

    private var groupList: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.tracks) { track in
                        copyRow(track: track, isKeeper: track.id == group.suggestedKeeper?.id, in: group)
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(.subheadline.bold())
                            .foregroundStyle(.primary)
                        Text(group.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func copyRow(track: Track, isKeeper: Bool, in group: DuplicateGroup) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(track.format.displayName)
                        .font(.caption.bold())
                    if isKeeper {
                        Text("SUGGESTED KEEP")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(detailLine(for: track))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(role: .destructive) {
                remove(track: track, from: group)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove this \(track.format.displayName) copy from library")
        }
        .padding(.vertical, 2)
    }

    private func detailLine(for track: Track) -> String {
        var parts: [String] = []
        if let bitrate = track.bitrateBps, bitrate > 0 {
            parts.append("\(bitrate / 1000) kbps")
        }
        if let bytes = track.fileSizeBytes, bytes > 0 {
            parts.append(formattedBytes(bytes))
        }
        parts.append(sourceName(for: track.source))
        return parts.joined(separator: " · ")
    }

    private func sourceName(for id: MusicSourceID) -> String {
        sources.sources.first { $0.id == id }?.displayName ?? "Unknown source"
    }

    private func formattedBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // MARK: - Actions

    private func remove(track: Track, from group: DuplicateGroup) {
        library.delete(trackID: track.id)
        removedCount += 1
        // Re-derive the group in place rather than rescanning the whole library,
        // so the list doesn't jump while the user is working through it.
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        let remaining = groups[idx].tracks.filter { $0.id != track.id }
        if remaining.count > 1 {
            groups[idx] = DuplicateGroup(id: group.id, tracks: remaining)
        } else {
            groups.remove(at: idx)
        }
    }

    private func cleanUpAll() {
        let doomed = groups.flatMap(\.redundantCopies)
        for track in doomed {
            library.delete(trackID: track.id)
        }
        removedCount += doomed.count
        groups = []
    }

    // MARK: - Scan

    private func scan() async {
        await MainActor.run { isScanning = true }
        let tracks = await MainActor.run { Array(library.tracks) }
        // Matching is pure string and number work — no artwork decoding — so a
        // 6000-track library stays cheap. Kept off the main actor regardless so
        // the scan never blocks the UI.
        let found = DuplicateFinder.duplicateGroups(in: tracks)
        await MainActor.run {
            groups = found
            isScanning = false
        }
    }
}
