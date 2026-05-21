import SwiftUI
import AVKit
import MediaPlayer

// MARK: - NowPlayingView
struct NowPlayingView: View {
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.kAccent) var accent
    @AppStorage("vuMeterEnabled") var vuMeterEnabled = true
    @State private var showingLyrics = false
    @State private var showingEQ = false
    @State private var vuLevels: [CGFloat] = Array(repeating: 0, count: 14)
    @State private var peakLevels: [CGFloat] = Array(repeating: 0, count: 14)
    @State private var peakDecayCounters: [Int] = Array(repeating: 0, count: 14)

    var body: some View {
        ZStack {
            Color.kBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                handleBar
                breadcrumb
                    .padding(.top, 4)

                if showingLyrics {
                    if player.lyrics.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "text.quote")
                                .font(.system(size: 32))
                                .foregroundStyle(.white.opacity(0.2))
                            Text("No lyrics available")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.35))
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { showingLyrics = false } }
                        .transition(.opacity)
                    } else {
                        LyricsView(lines: player.lyrics, position: player.state.positionSeconds)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                            .padding(.horizontal, 24)
                    }
                } else {
                    artworkDisplay
                }

                trackInfo

                Spacer(minLength: 0)

                audioInfoRow

                progressSection
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                if vuMeterEnabled, !isAppleMusicTrack {
                    vuMeter
                        .padding(.horizontal, 24)
                        .padding(.bottom, 14)
                }

                TransportControls()
                    .environmentObject(player)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)

                volumeRow
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)

                bottomToolbar
            }
        }
        .foregroundStyle(.white)
        .sheet(isPresented: $showingEQ) {
            EQView().environmentObject(player)
        }
        .sheet(isPresented: $player.showingQueue) {
            QueueView().environmentObject(player)
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            updateVULevels()
        }
    }

    // MARK: - Sub-views

    private var handleBar: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(Color.white.opacity(0.18))
            .frame(width: 36, height: 4)
            .padding(.top, 12)
            .padding(.bottom, 6)
    }

    private var breadcrumb: some View {
        HStack(spacing: 6) {
            Text("NOW PLAYING")
                .foregroundStyle(.white.opacity(0.75))
            Spacer()
        }
        .font(.system(size: 12, weight: .bold))
        .tracking(1.5)
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private var artworkDisplay: some View {
        AlbumArtView(
            cacheKey: player.queue.currentTrack?.artworkCacheKey ?? player.state.nowPlayingArtworkCacheKey
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { showingLyrics.toggle() } }
        .transition(.opacity)
    }

    private var trackInfo: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(player.queue.currentTrack?.title ?? "NOT PLAYING")
                    .font(.system(.title3, design: .default).bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text((player.queue.currentTrack?.artist ?? "").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(.white.opacity(0.4))
                    if let year = player.queue.currentTrack?.year {
                        Text("·").foregroundStyle(.white.opacity(0.2))
                        Text(String(year))
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            Spacer()
            Button {
                player.toggleFavourite()
            } label: {
                Image(systemName: player.queue.currentTrack?.isFavourited == true ? "heart.fill" : "heart")
                    .foregroundStyle(
                        player.queue.currentTrack?.isFavourited == true ? accent : Color.white.opacity(0.35)
                    )
            }
            .font(.title2)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private var progressSection: some View {
        VStack(spacing: 6) {
            ScrubBar()
                .environmentObject(player)
            HStack {
                Text(formatTime(player.state.positionSeconds))
                    .foregroundStyle(accent)
                Spacer()
                Text("-\(formatTime(max(player.state.durationSeconds - player.state.positionSeconds, 0)))")
                    .foregroundStyle(.white.opacity(0.3))
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }

    private var audioInfoRow: some View {
        Group {
            if let track = player.queue.currentTrack {
                HStack(spacing: 8) {
                    FormatBadge(track: track)
                    if track.isLossless {
                        audioChip("LOSSLESS")
                    } else if let bps = track.bitrateBps, bps > 0 {
                        audioChip("\(bps / 1000) KBPS")
                    }
                    if let rate = track.sampleRateHz {
                        audioChip(String(format: "%.1f KHZ", Double(rate) / 1000.0))
                    }
                    if let depth = track.bitDepth {
                        audioChip("\(depth)-BIT")
                    }
                    if let channels = track.channelCount {
                        audioChip(channels == 1 ? "MONO" : "STEREO")
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 10)
            }
        }
    }

    private func audioChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.3))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )
    }

    private var vuMeter: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<vuLevels.count, id: \.self) { i in
                    RetroVUBar(level: vuLevels[i], peak: peakLevels[i])
                }
            }
            .frame(height: 40)
            // Frequency labels
            HStack(alignment: .top, spacing: 0) {
                Text("32").frame(maxWidth: .infinity, alignment: .leading)
                Text("100").frame(maxWidth: .infinity)
                Text("500").frame(maxWidth: .infinity)
                Text("2K").frame(maxWidth: .infinity)
                Text("8K").frame(maxWidth: .infinity)
                Text("16K").frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.system(size: 7, weight: .semibold, design: .monospaced))
            .tracking(0.3)
            .foregroundStyle(.white.opacity(0.2))
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
            SystemVolumeSlider(tintColor: UIColor(accent))
                .frame(height: 28)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var bottomToolbar: some View {
        HStack {
            Button { showingEQ.toggle() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3")
                    Text("EQ")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1)
                }
            }
            Spacer()
            Button { player.showingQueue.toggle() } label: {
                VStack(spacing: 3) {
                    Image(systemName: "list.bullet")
                    Text("QUEUE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1)
                }
            }
            Spacer()
            VStack(spacing: 3) {
                AirPlayButtonView()
                    .frame(width: 22, height: 20)
                Text("OUTPUT")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            ShareLink(
                item: shareText,
                subject: Text("Listening to")
            ) {
                VStack(spacing: 3) {
                    Image(systemName: "square.and.arrow.up")
                    Text("SHARE")
                        .font(.system(size: 8, weight: .bold))
                        .tracking(1)
                }
            }
        }
        .font(.system(size: 18))
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
    }

    // MARK: - VU animation

    private var shareText: String {
        guard let track = player.queue.currentTrack else { return "" }
        if track.artist.isEmpty { return track.title }
        return "\(track.title) by \(track.artist)"
    }

    private var isAppleMusicTrack: Bool {
        if case .appleMusicID = player.queue.currentTrack?.uri { return true }
        return false
    }

    private func updateVULevels() {
        let rawLevels = player.meterLevels
        let isPlaying = player.state.status == .playing

        for i in 0..<vuLevels.count {
            let raw = i < rawLevels.count ? Double(rawLevels[i]) : 0
            // Low-frequency bands contain only 1-5 FFT bins, so their mean IS a raw
            // bin magnitude that can easily reach -6 dBFS for any strong bass note.
            // Use a full 90 dB window [−90 dBFS, 0 dBFS] → [0, 1] so the ceiling
            // is true full-scale digital and nothing maxes out during normal playback.
            let dbfs = raw > 0 ? 20.0 * log10(raw) : -100.0
            let normalized = CGFloat(max(0, min(1, (dbfs + 90.0) / 90.0)))

            if isPlaying {
                // Fast attack, slow decay
                if normalized > vuLevels[i] {
                    vuLevels[i] = normalized * 0.65 + vuLevels[i] * 0.35
                } else {
                    vuLevels[i] = vuLevels[i] * 0.72
                }
            } else {
                vuLevels[i] = max(0, vuLevels[i] * 0.78)
            }

            // Peak hold
            if vuLevels[i] > peakLevels[i] {
                peakLevels[i] = vuLevels[i]
                peakDecayCounters[i] = 10
            } else if peakDecayCounters[i] > 0 {
                peakDecayCounters[i] -= 1
            } else {
                peakLevels[i] = max(0, peakLevels[i] - 0.025)
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - FormatBadge
struct FormatBadge: View {
    let track: Track
    @Environment(\.kAccent) var accent
    var body: some View {
        Text(track.format.displayName)
            .font(.system(size: 8, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(track.isLossless ? accent : Color.white.opacity(0.4))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(
                        track.isLossless ? accent.opacity(0.5) : Color.white.opacity(0.2),
                        lineWidth: 0.75
                    )
            )
    }
}

// MARK: - ScrubBar
/// Progress bar with drag-to-seek. Displays the drag position while scrubbing
/// so the position timer doesn't fight the gesture.
struct ScrubBar: View {
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.kAccent) var accent
    @State private var isDragging = false
    @State private var dragRatio: Double = 0

    private var displayRatio: Double {
        isDragging ? dragRatio : player.state.progress
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule()
                    .fill(accent)
                    .frame(width: max(0, geo.size.width * CGFloat(displayRatio)))
            }
            .frame(height: isDragging ? 5 : 3)
            .animation(.easeInOut(duration: 0.1), value: isDragging)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        isDragging = true
                        dragRatio = min(1, max(0, Double(v.location.x / geo.size.width)))
                    }
                    .onEnded { v in
                        let ratio = min(1, max(0, Double(v.location.x / geo.size.width)))
                        player.seek(to: player.state.durationSeconds * ratio)
                        isDragging = false
                    }
            )
        }
        .frame(height: 10)   // generous tap target; visual bar is smaller via frame(height:) inside
        .contentShape(Rectangle())
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
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.07))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 48))
                            .foregroundStyle(.white.opacity(0.2))
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.45), radius: 28, x: 0, y: 10)
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

// MARK: - RetroVUBar
/// Segmented LED-style column for the retro spectrum analyzer.
struct RetroVUBar: View {
    let level: CGFloat   // 0...1 smoothed RMS
    let peak: CGFloat    // 0...1 peak hold

    private let segments = 10

    private var litCount: Int { Int(level * CGFloat(segments)) }
    private var peakIdx: Int  { min(Int(peak * CGFloat(segments)), segments - 1) }

    var body: some View {
        VStack(spacing: 1) {
            ForEach((0..<segments).reversed(), id: \.self) { i in
                let isLit     = i < litCount
                let isPeakDot = i == peakIdx && peakIdx > litCount
                Rectangle()
                    .fill(
                        isLit      ? segmentColor(i) :
                        isPeakDot  ? segmentColor(i).opacity(0.75) :
                                     Color.white.opacity(0.05)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func segmentColor(_ index: Int) -> Color {
        let n = CGFloat(index) / CGFloat(segments - 1)
        if n < 0.60 { return Color(red: 0.10, green: 0.95, blue: 0.30) }  // phosphor green
        if n < 0.85 { return Color(red: 1.00, green: 0.75, blue: 0.00) }  // amber
        return            Color(red: 1.00, green: 0.20, blue: 0.10)        // red
    }
}

// MARK: - AirPlayButtonView
struct AirPlayButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = UIColor.white.withAlphaComponent(0.45)
        picker.activeTintColor = UIColor(red: 0.0, green: 0.85, blue: 0.90, alpha: 1.0)
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - SystemVolumeSlider
struct SystemVolumeSlider: UIViewRepresentable {
    let tintColor: UIColor
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView()
        // showsRouteButton is deprecated in iOS 13; suppress via KVC to avoid the warning.
        view.setValue(false, forKey: "showsRouteButton")
        view.tintColor = tintColor
        return view
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.tintColor = tintColor
    }
}

// MARK: - TransportControls
struct TransportControls: View {
    @EnvironmentObject var player: PlayerViewModel
    @Environment(\.kAccent) var accent

    var body: some View {
        HStack(spacing: 0) {
            Button { player.queue.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .opacity(player.queue.shuffleMode == .on ? 1 : 0.35)
                    .foregroundStyle(player.queue.shuffleMode == .on ? accent : .white)
            }
            Spacer()
            Button { player.previous() } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 72, height: 72)
                    Image(systemName: player.state.status == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                        .offset(x: player.state.status == .playing ? 0 : 2)
                }
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
            Spacer()
            Button {
                let modes: [RepeatMode] = [.off, .all, .one]
                let idx = ((modes.firstIndex(of: player.queue.repeatMode) ?? 0) + 1) % modes.count
                player.queue.repeatMode = modes[idx]
            } label: {
                Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat")
                    .opacity(player.queue.repeatMode == .off ? 0.35 : 1)
                    .foregroundStyle(player.queue.repeatMode == .off ? .white : accent)
            }
        }
        .font(.title2)
    }
}

// MARK: - ProgressSlider (retained for backward compatibility)
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
            .tint(.kCyan)
            HStack {
                Text(formatTime(displayValue))
                Spacer()
                Text("-\(formatTime(max(total - displayValue, 0)))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - VolumeSlider (retained for backward compatibility)
struct VolumeSlider: View {
    let volume: Float
    let onChange: (Float) -> Void
    @Environment(\.kAccent) var accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.white.opacity(0.4))
            Slider(
                value: Binding(get: { Double(volume) }, set: { onChange(Float($0)) }),
                in: 0...1
            )
            .tint(accent)
            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.white.opacity(0.4))
        }
        .font(.caption)
    }
}

// MARK: - TrackMetadataRow (retained for potential external use)
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
                    .foregroundStyle(track?.isFavourited == true ? Color.kCyan : Color.white.opacity(0.6))
            }
        }
    }
}

// MARK: - SpinningArtworkView (stub - retained to avoid breaking existing references)
struct SpinningArtworkView: View {
    let cacheKey: String?
    let isPlaying: Bool

    var body: some View {
        AlbumArtView(cacheKey: cacheKey)
    }
}

// MARK: - UIImage dominant colour helper (retained for potential use)
extension UIImage {
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
        return UIColor(red: r / pf / 255 * 0.6, green: g / pf / 255 * 0.6, blue: b / pf / 255 * 0.6, alpha: 1)
    }
}
