import SwiftUI

// MARK: - NowPlayingView
/// The main watchOS view. Shows artwork, track metadata, a progress bar,
/// and transport controls that send commands to the iPhone via WatchConnectivity.
struct NowPlayingView: View {
    @EnvironmentObject var phone: PhoneConnectivityService

    var body: some View {
        VStack(spacing: 6) {
            // Artwork
            artworkView
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Track info
            VStack(spacing: 2) {
                Text(phone.title.isEmpty ? "Not Playing" : phone.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                if !phone.artist.isEmpty {
                    Text(phone.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)

            // Progress bar
            if phone.durationSeconds > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.2))
                            .frame(height: 3)
                        Capsule()
                            .fill(.white)
                            .frame(width: geo.size.width * phone.progress, height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.vertical, 2)
            }

            // Transport controls
            HStack(spacing: 20) {
                Button {
                    phone.sendCommand("previous")
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Button {
                    phone.sendCommand("togglePlayPause")
                } label: {
                    Image(systemName: phone.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)

                Button {
                    phone.sendCommand("next")
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let data = phone.artworkData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.1))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                }
        }
    }
}
