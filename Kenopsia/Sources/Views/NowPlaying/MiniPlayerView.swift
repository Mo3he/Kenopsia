import SwiftUI

// MARK: - MiniPlayerView
/// Compact now-playing bar that sits above the tab bar.
struct MiniPlayerView: View {
    @EnvironmentObject var player: PlayerViewModel

    var body: some View {
        if player.state.status != .stopped {
            VStack(spacing: 0) {
                // Thin progress line at the top
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * player.state.progress)
                }
                .frame(height: 2)

                HStack(spacing: 12) {
                    // Artwork thumbnail
                    MiniArtworkView(cacheKey: player.queue.currentTrack?.artworkCacheKey ?? player.state.nowPlayingArtworkCacheKey)

                    // Title + artist
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.queue.currentTrack?.title ?? "")
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(player.queue.currentTrack?.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Controls
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.state.status == .playing ? "pause.fill" : "play.fill")
                            .font(.title2)
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 8)
            .shadow(radius: 4)
            .onTapGesture { player.showingNowPlaying = true }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring, value: player.state.status)
        }
    }
}

struct MiniArtworkView: View {
    let cacheKey: String?
    @State private var artworkImage: UIImage?

    var body: some View {
        Group {
            if let img = artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onAppear { loadArtwork() }
        .onChange(of: cacheKey) { _, _ in loadArtwork() }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkCache.artworkDidUpdate)) { notification in
            guard let updatedKey = notification.userInfo?["key"] as? String,
                  updatedKey == cacheKey else { return }
            loadArtwork()
        }
    }

    private func loadArtwork() {
        guard let key = cacheKey else { artworkImage = nil; return }
        artworkImage = ArtworkCache.shared.thumbnailImage(forKey: key)
    }
}
