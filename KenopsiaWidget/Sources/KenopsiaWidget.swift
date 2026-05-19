import WidgetKit
import SwiftUI

// MARK: - NowPlayingEntry
struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let title: String
    let artist: String
    let album: String
    let isPlaying: Bool
    let artworkData: Data?

    static let placeholder = NowPlayingEntry(
        date: .now,
        title: "Track Title",
        artist: "Artist Name",
        album: "Album",
        isPlaying: true,
        artworkData: nil
    )

    static let empty = NowPlayingEntry(
        date: .now,
        title: "Nothing Playing",
        artist: "",
        album: "",
        isPlaying: false,
        artworkData: nil
    )
}

// MARK: - Provider
struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = readEntry()
        // Refresh every 30 seconds to keep progress roughly in sync
        let next = Calendar.current.date(byAdding: .second, value: 30, to: entry.date)!
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func readEntry() -> NowPlayingEntry {
        let defaults = UserDefaults(suiteName: "group.net.mohome.kenopsia")
        guard let data = defaults?.data(forKey: "playerState"),
              let state = try? JSONDecoder().decode(PlayerState.self, from: data),
              state.status == "playing" || state.status == "paused"
        else { return .empty }

        // Read artwork from shared cache folder
        let artworkData: Data? = {
            guard let key = state.nowPlayingArtworkCacheKey else { return nil }
            let base = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.kenopsia")
            let url = base?
                .appendingPathComponent("ArtworkCache")
                .appendingPathComponent(key + "_grid")
                .appendingPathExtension("jpg")
            return url.flatMap { try? Data(contentsOf: $0) }
        }()

        return NowPlayingEntry(
            date: .now,
            title: state.nowPlayingTitle,
            artist: state.nowPlayingArtist,
            album: state.nowPlayingAlbum,
            isPlaying: state.status == "playing",
            artworkData: artworkData
        )
    }
}

// MARK: - Widget
struct KenopsiaWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KenopsiaWidget", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("See what Kenopsia is currently playing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Widget Views
struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:  SmallNowPlayingView(entry: entry)
        case .systemMedium: MediumNowPlayingView(entry: entry)
        case .accessoryRectangular: LockScreenRectangularView(entry: entry)
        case .accessoryInline:      LockScreenInlineView(entry: entry)
        default:            SmallNowPlayingView(entry: entry)
        }
    }
}

// MARK: - Small widget
struct SmallNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtworkImageView(data: entry.artworkData, size: 60)
            Spacer()
            Text(entry.title)
                .font(.caption.bold())
                .lineLimit(1)
            Text(entry.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: entry.isPlaying ? "pause.fill" : "play.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Medium widget
struct MediumNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImageView(data: entry.artworkData, size: 80)
            VStack(alignment: .leading, spacing: 4) {
                Spacer()
                Text(entry.isPlaying ? "Now Playing" : "Paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(entry.title)
                    .font(.subheadline.bold())
                    .lineLimit(2)
                Text(entry.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.album)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }
}

// MARK: - Lock screen widgets
struct LockScreenRectangularView: View {
    let entry: NowPlayingEntry
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isPlaying ? "music.note" : "pause")
            VStack(alignment: .leading) {
                Text(entry.title).font(.headline).lineLimit(1)
                Text(entry.artist).font(.subheadline).lineLimit(1)
            }
        }
    }
}

struct LockScreenInlineView: View {
    let entry: NowPlayingEntry
    var body: some View {
        Label(entry.title, systemImage: entry.isPlaying ? "music.note" : "pause")
    }
}

// MARK: - Artwork helper
struct ArtworkImageView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - PlayerState stub (mirrored from main app via Codable)
// The widget target cannot import the main app module, so we re-declare the
// minimum needed to decode the shared App Group data.
private struct PlayerState: Decodable {
    var status: String
    var nowPlayingTitle: String
    var nowPlayingArtist: String
    var nowPlayingAlbum: String
    var nowPlayingArtworkCacheKey: String?
}
