import SwiftUI

// MARK: - NowPlayingView
/// Full-screen Now Playing. Adaptive colour theming from album art.
struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerViewModel
    @State private var dominantColor: Color = .black
    @State private var showingLyrics = false
    @State private var showingEQ = false

    var body: some View {
        ZStack {
            // Full-bleed background tinted by artwork palette
            dominantColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: dominantColor)

            VStack(spacing: 0) {
                // Dismiss handle
                RoundedRectangle(cornerRadius: 3)
                    .frame(width: 36, height: 5)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.top, 12)

                // Artwork / Lyrics toggle
                if showingLyrics {
                    LyricsView(lines: player.lyrics, position: player.state.positionSeconds)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    SpinningArtworkView(
                        cacheKey: player.queue.currentTrack?.artworkCacheKey ?? player.state.nowPlayingArtworkCacheKey,
                        isPlaying: player.state.status == .playing
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { withAnimation { showingLyrics.toggle() } }
                    .transition(.opacity)
                }

                // Metadata
                TrackMetadataRow(track: player.queue.currentTrack)
                    .padding(.horizontal, 24)

                // Progress bar
                ProgressSlider(
                    value: player.state.positionSeconds,
                    total: player.state.durationSeconds
                ) { player.seek(to: $0) }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

                // Transport controls
                TransportControls()
                    .environmentObject(player)
                    .padding(.horizontal, 24)

                // Volume
                VolumeSlider(volume: player.state.volume) { player.setVolume($0) }
                    .padding(.horizontal, 32)
                    .padding(.top, 8)

                // Bottom toolbar
                HStack {
                    Button { showingEQ.toggle() } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    Spacer()
                    Button { player.showingQueue.toggle() } label: {
                        Image(systemName: "list.bullet")
                    }
                    Spacer()
                    ShareLink(
                        item: player.queue.currentTrack?.title ?? "",
                        subject: Text("Listening to")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .font(.title2)
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
            }
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showingEQ) {
            EQView().environmentObject(player)
        }
        .sheet(isPresented: $player.showingQueue) {
            QueueView().environmentObject(player)
        }
        .onChange(of: player.queue.currentTrack?.artworkCacheKey) {
            updateDominantColor()
        }
        .onChange(of: player.state.nowPlayingArtworkCacheKey) {
            updateDominantColor()
        }
    }

    private func updateDominantColor() {
        let key = player.queue.currentTrack?.artworkCacheKey ?? player.state.nowPlayingArtworkCacheKey
        guard let key, let image = ArtworkCache.shared.fullImage(forKey: key) else {
            dominantColor = .black
            return
        }
        Task.detached(priority: .userInitiated) {
            let color = image.dominantColor()
            await MainActor.run { dominantColor = Color(color) }
        }
    }
}

// MARK: - AlbumArtView
struct AlbumArtView: View {
    let cacheKey: String?
    @State private var artworkImage: UIImage?

    var body: some View {
        Group {
            if let image = artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.15))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.4))
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .padding(32)
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
        artworkImage = ArtworkCache.shared.fullImage(forKey: key)
    }
}

// MARK: - TrackMetadataRow
struct TrackMetadataRow: View {
    let track: Track?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "Not Playing")
                    .font(.title3.bold())
                    .lineLimit(1)
                Text(track?.artist ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            Button {
                guard var t = track else { return }
                t.isFavourited.toggle()
                LibraryStore.shared.update(track: t)
            } label: {
                Image(systemName: track?.isFavourited == true ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(track?.isFavourited == true ? .pink : .white.opacity(0.6))
            }
        }
    }
}

// MARK: - TransportControls
struct TransportControls: View {
    @EnvironmentObject var player: PlayerViewModel

    var body: some View {
        HStack(spacing: 0) {
            Button { player.queue.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .opacity(player.queue.shuffleMode == .on ? 1 : 0.4)
                    .foregroundStyle(player.queue.shuffleMode == .on ? Color.accentColor : .white)
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.state.status == .playing ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
            }
            Spacer()
            Button {
                let modes: [RepeatMode] = [.off, .all, .one]
                let idx = ((modes.firstIndex(of: player.queue.repeatMode) ?? 0) + 1) % modes.count
                player.queue.repeatMode = modes[idx]
            } label: {
                Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .opacity(player.queue.repeatMode == .off ? 0.4 : 1)
            }
        }
        .font(.title2)
        .foregroundStyle(.white)
    }
}

// MARK: - ProgressSlider
struct ProgressSlider: View {
    let value: Double
    let total: Double
    let onSeek: (Double) -> Void
    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var displayValue: Double { isDragging ? dragValue : value }

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { displayValue },
                    set: { dragValue = $0; isDragging = true }
                ),
                in: 0...max(total, 1)
            ) { editing in
                if !editing { onSeek(dragValue); isDragging = false }
            }
            .tint(.white)
            HStack {
                Text(formatTime(displayValue))
                Spacer()
                Text("-\(formatTime(max(total - displayValue, 0)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - VolumeSlider
struct VolumeSlider: View {
    let volume: Float
    let onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.white.opacity(0.5))
            Slider(
                value: Binding(get: { Double(volume) }, set: { onChange(Float($0)) }),
                in: 0...1
            )
            .tint(.white)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.white.opacity(0.5))
        }
        .font(.caption)
    }
}

// MARK: - UIImage dominant colour helper
extension UIImage {
    /// Returns a rough dominant colour by downsampling and averaging pixels.
    func dominantColor() -> UIColor {
        let size = CGSize(width: 20, height: 20)
        let renderer = UIGraphicsImageRenderer(size: size)
        let scaled = renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
        guard let cgImg = scaled.cgImage,
              let data = cgImg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return .black }
        let count = Int(CFDataGetLength(data))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        let pixels = count / 4
        for i in stride(from: 0, to: count, by: 4) {
            r += CGFloat(ptr[i])
            g += CGFloat(ptr[i + 1])
            b += CGFloat(ptr[i + 2])
        }
        let pf = CGFloat(pixels)
        // Darken for background use
        return UIColor(red: r / pf / 255 * 0.6, green: g / pf / 255 * 0.6, blue: b / pf / 255 * 0.6, alpha: 1)
    }
}

// MARK: - SpinningArtworkView
/// Displays album art. When vinylAnimation is enabled in Settings, the artwork spins
/// on a vinyl record platter while playing and pauses when stopped.
/// Toggleable for battery-conscious users (Settings -> Now Playing).
struct SpinningArtworkView: View {
    let cacheKey: String?
    let isPlaying: Bool

    @AppStorage("vinylAnimation") private var vinylEnabled: Bool = true
    @State private var rotation: Double = 0
    @State private var timerTask: Task<Void, Never>?
    @State private var artworkImage: UIImage?

    var body: some View {
        ZStack {
            if vinylEnabled {
                // Vinyl platter
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.black, Color(white: 0.12), .black, Color(white: 0.08), .black],
                            center: .center,
                            startRadius: 0,
                            endRadius: 160
                        )
                    )
                    .overlay {
                        // Groove rings
                        ForEach(0..<8) { i in
                            Circle()
                                .stroke(Color.white.opacity(0.04), lineWidth: 1)
                                .padding(CGFloat(i) * 18 + 20)
                        }
                    }
                    .overlay {
                        // Center label — the album artwork
                        artworkCircle
                            .frame(width: 130, height: 130)
                    }
                    .rotationEffect(.degrees(rotation))
                    .frame(width: 280, height: 280)
                    .shadow(radius: 20)
                    .padding(20)
            } else {
                // Plain square artwork
                artworkSquare
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 20)
                    .padding(32)
            }
        }
        .onChange(of: isPlaying) { _, playing in
            if playing { startSpinning() } else { stopSpinning() }
        }
        .onChange(of: cacheKey) { _, _ in loadArtwork() }
        .onAppear { loadArtwork(); if isPlaying { startSpinning() } }
        .onDisappear { stopSpinning() }
        .onReceive(NotificationCenter.default.publisher(for: ArtworkCache.artworkDidUpdate)) { notification in
            guard let updatedKey = notification.userInfo?["key"] as? String,
                  updatedKey == cacheKey else { return }
            loadArtwork()
        }
    }

    private func loadArtwork() {
        guard let key = cacheKey else { artworkImage = nil; return }
        artworkImage = ArtworkCache.shared.fullImage(forKey: key)
    }

    private var artworkCircle: some View {
        Group {
            if let image = artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color(white: 0.2))
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.white.opacity(0.4))
                            .font(.title2)
                    }
            }
        }
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 2))
    }

    private var artworkSquare: some View {
        Group {
            if let image = artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(0.15))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.4))
                    }
            }
        }
    }

    // MARK: - Spin control
    /// Continuously increments rotation at ~33.3 RPM (vinyl speed) = 0.555 degrees/frame at 60fps.
    private func startSpinning() {
        timerTask?.cancel()
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))  // ~60fps
                await MainActor.run {
                    rotation = rotation.truncatingRemainder(dividingBy: 360) + 0.32
                }
            }
        }
    }

    private func stopSpinning() {
        timerTask?.cancel()
        timerTask = nil
        // Rotation stays at current angle — resumes from where it stopped.
    }
}

