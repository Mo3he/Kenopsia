import CarPlay
import UIKit

// MARK: - CarPlaySceneDelegate
/// Manages the Loudmouth UI on the CarPlay screen.
///
/// The Now Playing tab is driven entirely by `MPNowPlayingInfoCenter` and
/// `MPRemoteCommandCenter`, which PlaybackService already keeps up to date.
/// No extra plumbing is needed for that screen.
///
/// The Library tab lets the driver browse Albums, Playlists, and All Songs
/// and start playback via PlaybackService.shared.
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    // MARK: - Scene lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(buildRootTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Root template

    private func buildRootTemplate() -> CPTemplate {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.tabTitle = "Now Playing"
        nowPlaying.tabImage = UIImage(systemName: "play.circle.fill")

        let library = buildLibraryTemplate()
        return CPTabBarTemplate(templates: [nowPlaying, library])
    }

    // MARK: - Library browse template

    private func buildLibraryTemplate() -> CPListTemplate {
        let store = LibraryStore.shared
        let maxItems = CPListTemplate.maximumItemCount

        // Albums — alphabetical
        let sortedAlbums = store.albums.values.sorted { $0.title < $1.title }
        let albumItems: [CPListItem] = sortedAlbums.prefix(maxItems).map { album in
            let detail = album.artist.isEmpty ? nil : album.artist
            let item = CPListItem(text: album.title, detailText: detail)
            item.handler = { [weak self] _, completion in
                self?.pushAlbum(album, store: store)
                completion()
            }
            return item
        }

        // Playlists — alphabetical
        let sortedPlaylists = store.playlists.values.sorted { $0.name < $1.name }
        let playlistItems: [CPListItem] = sortedPlaylists.prefix(maxItems).map { playlist in
            let item = CPListItem(
                text: playlist.name,
                detailText: "\(playlist.trackIDs.count) song\(playlist.trackIDs.count == 1 ? "" : "s")"
            )
            item.handler = { [weak self] _, completion in
                self?.pushPlaylist(playlist, store: store)
                completion()
            }
            return item
        }

        // All songs — alphabetical
        let sortedTracks = store.tracks.values.sorted { $0.title < $1.title }
        let songItems: [CPListItem] = sortedTracks.prefix(maxItems).map { track in
            let item = CPListItem(text: track.title, detailText: track.artist)
            item.handler = { _, completion in
                Task { @MainActor in
                    let idx = sortedTracks.firstIndex(where: { $0.id == track.id }) ?? 0
                    PlaybackService.shared.replace(with: sortedTracks, startAt: idx)
                    completion()
                }
            }
            return item
        }

        var sections: [CPListSection] = []
        if !albumItems.isEmpty {
            sections.append(CPListSection(items: albumItems, header: "Albums", sectionIndexTitle: nil))
        }
        if !playlistItems.isEmpty {
            sections.append(CPListSection(items: playlistItems, header: "Playlists", sectionIndexTitle: nil))
        }
        if !songItems.isEmpty {
            sections.append(CPListSection(items: songItems, header: "Songs", sectionIndexTitle: nil))
        }

        let template = CPListTemplate(title: "Library", sections: sections)
        template.tabTitle = "Library"
        template.tabImage = UIImage(systemName: "music.note.list")
        return template
    }

    // MARK: - Album drill-down

    private func pushAlbum(_ album: Album, store: LibraryStore) {
        let albumTracks = album.trackIDs.compactMap { store.tracks[$0] }
        guard !albumTracks.isEmpty else { return }

        // "Play All" item
        let playAll = CPListItem(
            text: "Play All",
            detailText: "\(albumTracks.count) song\(albumTracks.count == 1 ? "" : "s")"
        )
        playAll.handler = { _, completion in
            Task { @MainActor in
                PlaybackService.shared.replace(with: albumTracks, startAt: 0)
                completion()
            }
        }

        // "Shuffle" item
        let shuffle = CPListItem(text: "Shuffle", detailText: nil)
        shuffle.handler = { _, completion in
            Task { @MainActor in
                var shuffled = albumTracks; shuffled.shuffle()
                PlaybackService.shared.replace(with: shuffled, startAt: 0)
                completion()
            }
        }

        // Individual tracks
        let trackItems: [CPListItem] = albumTracks.enumerated().map { (i, track) in
            let detail = track.durationSeconds > 0 ? formatDuration(track.durationSeconds) : nil
            let item = CPListItem(text: track.title, detailText: detail)
            item.handler = { _, completion in
                Task { @MainActor in
                    PlaybackService.shared.replace(with: albumTracks, startAt: i)
                    completion()
                }
            }
            return item
        }

        let header = CPListSection(items: [playAll, shuffle])
        let tracks = CPListSection(items: trackItems)
        let template = CPListTemplate(title: album.title, sections: [header, tracks])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Playlist drill-down

    private func pushPlaylist(_ playlist: Playlist, store: LibraryStore) {
        let playlistTracks = playlist.trackIDs.compactMap { store.tracks[$0] }
        guard !playlistTracks.isEmpty else { return }

        let playAll = CPListItem(
            text: "Play All",
            detailText: "\(playlistTracks.count) song\(playlistTracks.count == 1 ? "" : "s")"
        )
        playAll.handler = { _, completion in
            Task { @MainActor in
                PlaybackService.shared.replace(with: playlistTracks, startAt: 0)
                completion()
            }
        }

        let trackItems: [CPListItem] = playlistTracks.enumerated().map { (i, track) in
            let item = CPListItem(text: track.title, detailText: track.artist)
            item.handler = { _, completion in
                Task { @MainActor in
                    PlaybackService.shared.replace(with: playlistTracks, startAt: i)
                    completion()
                }
            }
            return item
        }

        let header = CPListSection(items: [playAll])
        let tracks = CPListSection(items: trackItems)
        let template = CPListTemplate(title: playlist.name, sections: [header, tracks])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
