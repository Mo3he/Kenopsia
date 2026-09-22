import CarPlay
import Combine
import MediaPlayer
import UIKit

// MARK: - CarPlaySceneDelegate
/// Drives the Kenopsia CarPlay UI.
///
/// Two tabs: Recently Played and Library. Search is *not* a tab — `CPSearchTemplate`
/// cannot be one — so it is pushed from a trailing nav bar button on both. Now Playing
/// is not a tab either; it is the system-managed `CPNowPlayingTemplate`.
/// `CPNowPlayingTemplate` reads from `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`,
/// which `PlaybackService` already publishes. Browse lists, search, and recents drive
/// playback by calling `PlaybackService.shared`.
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var libraryObserver: NSObjectProtocol?
    private var artworkObserver: NSObjectProtocol?
    private var stateObserver: AnyCancellable?
    private var queueObserver: AnyCancellable?

    /// Genres are derived by scanning every track, and `libraryContents()` runs
    /// on each track change as well as on library edits. Cached so a 6000-track
    /// library is not rescanned every time the song changes; invalidated by
    /// `.libraryDidChange`, which is the only thing that can alter it.
    private var cachedGenreCount: Int?
    private var recentsObserver: AnyCancellable?

    /// Persistent root tab templates. Kept across refreshes so we mutate their
    /// sections in place via `updateSections(_:)` rather than swapping templates,
    /// which would pop the CarPlay navigation stack (kicking the user out of
    /// Now Playing on every track change).
    private var recentsTemplate: CPListTemplate?
    private var libraryTemplate: CPListTemplate?

    /// Per-template, the cache keys and weak items that should refresh when artwork arrives.
    private var artworkRefreshers: [ObjectIdentifier: [(String, WeakItem)]] = [:]

    private final class WeakItem {
        weak var item: CPListItem?
        init(_ item: CPListItem) { self.item = item }
    }

    // MARK: - Scene lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(buildRootTemplate(), animated: false, completion: nil)

        libraryObserver = NotificationCenter.default.addObserver(
            forName: .libraryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cachedGenreCount = nil
                self?.refreshTabs()
            }
        }

        artworkObserver = NotificationCenter.default.addObserver(
            forName: ArtworkCache.artworkDidUpdate, object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                guard let key = note.userInfo?["key"] as? String else { return }
                self?.applyArtwork(forKey: key)
            }
        }

        stateObserver = PlaybackService.shared.$state
            .map(\.currentTrackID)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshTabs()
                    self?.refreshNowPlayingButtonAvailability()
                }
            }

        queueObserver = PlaybackService.shared.queue.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshNowPlayingButtonAvailability() }
            }

        recentsObserver = ListeningStatsStore.shared.$recentlyPlayed
            .map(\.first?.trackID)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshTabs() }
            }
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        CPNowPlayingTemplate.shared.remove(self)
        if let obs = libraryObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = artworkObserver { NotificationCenter.default.removeObserver(obs) }
        libraryObserver = nil
        artworkObserver = nil
        stateObserver?.cancel(); stateObserver = nil
        queueObserver?.cancel(); queueObserver = nil
        recentsObserver?.cancel(); recentsObserver = nil
        artworkRefreshers.removeAll()
        recentsTemplate = nil
        libraryTemplate = nil
        self.interfaceController = nil
    }

    // MARK: - Root

    private func buildRootTemplate() -> CPTemplate {
        configureNowPlayingTemplate()
        let recents = makeRecentsTemplate()
        let library = makeLibraryTemplate()
        recentsTemplate = recents
        libraryTemplate = library
        return CPTabBarTemplate(templates: [recents, library])
    }

    private func refreshTabs() {
        // Update sections in place. Replacing the tab templates pops the
        // CarPlay navigation stack, kicking the user out of Now Playing.
        if let recents = recentsTemplate {
            let (sections, info) = recentsContents()
            recents.updateSections(sections)
            recents.emptyViewTitleVariants = info.emptyTitle
            recents.emptyViewSubtitleVariants = info.emptySubtitle
        }
        if let library = libraryTemplate {
            let (sections, info) = libraryContents()
            library.updateSections(sections)
            library.emptyViewTitleVariants = info.emptyTitle
            library.emptyViewSubtitleVariants = info.emptySubtitle
        }
    }

    // MARK: - Now Playing (system-managed; not a tab)

    private func configureNowPlayingTemplate() {
        let np = CPNowPlayingTemplate.shared
        np.upNextTitle = "Up Next"
        np.updateNowPlayingButtons(nowPlayingButtons())
        np.remove(self)
        np.add(self)
        refreshNowPlayingButtonAvailability()
    }

    /// Toggle the Up Next / Album-Artist buttons based on actual queue state.
    /// Tapping Up Next when there are no upcoming tracks (e.g. a single-track
    /// queue or web radio) used to push an empty list, which CarPlay rejects
    /// with an exception that crashes the scene and leaves it unable to
    /// reconnect until the head unit is unplugged.
    private func refreshNowPlayingButtonAvailability() {
        let q = PlaybackService.shared.queue
        let hasUpcoming = q.currentIndex + 1 < q.tracks.count
        let hasAlbumContext = (q.currentTrack?.album.isEmpty == false)
        let np = CPNowPlayingTemplate.shared
        if np.isUpNextButtonEnabled != hasUpcoming { np.isUpNextButtonEnabled = hasUpcoming }
        if np.isAlbumArtistButtonEnabled != hasAlbumContext { np.isAlbumArtistButtonEnabled = hasAlbumContext }
    }

    private func nowPlayingButtons() -> [CPNowPlayingButton] {
        let shuffle = CPNowPlayingShuffleButton { _ in
            Task { @MainActor in
                PlaybackService.shared.queue.toggleShuffle()
                CPNowPlayingTemplate.shared.updateNowPlayingButtons(self.nowPlayingButtons())
            }
        }
        let rpt = CPNowPlayingRepeatButton { _ in
            Task { @MainActor in
                let q = PlaybackService.shared.queue
                switch q.repeatMode {
                case .off: q.repeatMode = .all
                case .all: q.repeatMode = .one
                case .one: q.repeatMode = .off
                }
                CPNowPlayingTemplate.shared.updateNowPlayingButtons(self.nowPlayingButtons())
            }
        }
        return [shuffle, rpt]
    }

    // MARK: - Recently Played

    private struct EmptyInfo {
        let emptyTitle: [String]
        let emptySubtitle: [String]
    }

    private func recentsContents() -> ([CPListSection], EmptyInfo) {
        let store = LibraryStore.shared
        let stats = ListeningStatsStore.shared

        var seen = Set<UUID>()
        var recentTracks: [Track] = []

        if let current = PlaybackService.shared.queue.currentTrack {
            recentTracks.append(current)
            seen.insert(current.id)
        }

        for event in stats.recentlyPlayed {
            if seen.insert(event.trackID).inserted, let t = store.tracks[event.trackID] {
                recentTracks.append(t)
                if recentTracks.count >= CPListTemplate.maximumItemCount { break }
            }
        }

        if recentTracks.count < CPListTemplate.maximumItemCount {
            let history = store.tracks.values
                .filter { $0.lastPlayedAt != nil && !seen.contains($0.id) }
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
            for t in history {
                recentTracks.append(t)
                seen.insert(t.id)
                if recentTracks.count >= CPListTemplate.maximumItemCount { break }
            }
        }

        if recentTracks.isEmpty {
            return ([], EmptyInfo(
                emptyTitle: ["No recent plays"],
                emptySubtitle: ["Songs you play will appear here."]
            ))
        }

        let items = recentTracks.enumerated().map { (i, track) in
            makeTrackItem(track, in: recentTracks, startIndex: i, detailIsArtist: true)
        }
        // Refreshers are scoped per-template; use the persistent recentsTemplate
        // identity if available so artwork updates target the right rows.
        if let template = recentsTemplate {
            registerArtworkRefreshers(
                for: template,
                items: zip(recentTracks, items).map { (trackArtworkKey(for: $0.0), $0.1) }
            )
            fetchMissingArtwork(forTracksIn: template, tracks: recentTracks)
        }
        return ([CPListSection(items: items)], EmptyInfo(emptyTitle: [], emptySubtitle: []))
    }

    private func makeRecentsTemplate() -> CPListTemplate {
        let (sections, info) = recentsContents()
        let template = CPListTemplate(title: "Recently Played", sections: sections)
        template.emptyViewTitleVariants = info.emptyTitle
        template.emptyViewSubtitleVariants = info.emptySubtitle
        template.tabTitle = "Recents"
        template.tabImage = UIImage(systemName: "clock.fill")
        template.trailingNavigationBarButtons = [makeSearchBarButton()]
        return template
    }

    // MARK: - Library tab (Albums / Artists / Playlists / Songs)

    private func libraryContents() -> ([CPListSection], EmptyInfo) {
        let store = LibraryStore.shared
        let albumCount = store.albums.count
        let artistCount = store.artists.count
        let playlistCount = store.playlists.count
        let songCount = store.tracks.count

        let albumsItem = CPListItem(text: "Albums", detailText: "\(albumCount)")
        albumsItem.accessoryType = .disclosureIndicator
        albumsItem.setImage(UIImage(systemName: "square.stack"))
        albumsItem.handler = { [weak self] _, completion in
            self?.pushAlbumsList(); completion()
        }

        let artistsItem = CPListItem(text: "Artists", detailText: "\(artistCount)")
        artistsItem.accessoryType = .disclosureIndicator
        artistsItem.setImage(UIImage(systemName: "music.mic"))
        artistsItem.handler = { [weak self] _, completion in
            self?.pushArtistsList(); completion()
        }

        let playlistsItem = CPListItem(text: "Playlists", detailText: "\(playlistCount)")
        playlistsItem.accessoryType = .disclosureIndicator
        playlistsItem.setImage(UIImage(systemName: "music.note.list"))
        playlistsItem.handler = { [weak self] _, completion in
            self?.pushPlaylistsList(); completion()
        }

        let songsItem = CPListItem(text: "Songs", detailText: "\(songCount)")
        songsItem.accessoryType = .disclosureIndicator
        songsItem.setImage(UIImage(systemName: "music.note"))
        songsItem.handler = { [weak self] _, completion in
            self?.pushSongsList(); completion()
        }

        let genreCount: Int
        if let cached = cachedGenreCount {
            genreCount = cached
        } else {
            genreCount = Self.genreBuckets(in: store.tracks.values).count
            cachedGenreCount = genreCount
        }
        let genresItem = CPListItem(text: "Genres", detailText: "\(genreCount)")
        genresItem.accessoryType = .disclosureIndicator
        genresItem.setImage(UIImage(systemName: "guitars"))
        genresItem.handler = { [weak self] _, completion in
            self?.pushGenresList(); completion()
        }

        // Shuffle the whole library without drilling in first — the one thing
        // you actually want while driving.
        let shuffleAll = CPListItem(
            text: "Shuffle All",
            detailText: "\(songCount) song\(songCount == 1 ? "" : "s")"
        )
        shuffleAll.setImage(UIImage(systemName: "shuffle"))
        shuffleAll.handler = { _, completion in
            Task { @MainActor in
                var all = Array(LibraryStore.shared.tracks.values)
                all.shuffle()
                PlaybackService.shared.queue.shuffleMode = .off
                PlaybackService.shared.replace(with: all, startAt: 0)
                completion()
            }
        }

        var browseItems = [albumsItem, artistsItem, playlistsItem, songsItem]
        if genreCount > 0 { browseItems.append(genresItem) }
        var sections: [CPListSection] = []
        if songCount > 0 { sections.append(CPListSection(items: [shuffleAll])) }
        sections.append(CPListSection(items: browseItems))
        let empty: EmptyInfo
        if songCount == 0 {
            empty = EmptyInfo(
                emptyTitle: ["Library is empty"],
                emptySubtitle: ["Add a music source on your phone."]
            )
        } else {
            empty = EmptyInfo(emptyTitle: [], emptySubtitle: [])
        }
        return (sections, empty)
    }

    private func makeLibraryTemplate() -> CPListTemplate {
        let (sections, info) = libraryContents()
        let template = CPListTemplate(title: "Library", sections: sections)
        template.tabTitle = "Library"
        template.tabImage = UIImage(systemName: "books.vertical.fill")
        template.trailingNavigationBarButtons = [makeSearchBarButton()]
        template.emptyViewTitleVariants = info.emptyTitle
        template.emptyViewSubtitleVariants = info.emptySubtitle
        return template
    }

    private func pushAlbumsList() {
        let store = LibraryStore.shared
        let albums = store.albums.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        let (limited, hiddenCount) = Self.limitedForDisplay(albums)
        let items: [CPListItem] = limited.map { album in
            let item = CPListItem(text: album.title,
                                  detailText: album.artist.isEmpty ? nil : album.artist)
            item.accessoryType = .disclosureIndicator
            applyArtwork(albumArtworkKey(for: album), to: item)
            item.handler = { [weak self] _, completion in
                self?.pushAlbum(album, store: store); completion()
            }
            return item
        }
        var sections = [CPListSection(items: items)]
        if let notice = Self.truncationSection(hidden: hiddenCount) {
            sections.append(notice)
        }
        let template = CPListTemplate(title: "Albums", sections: sections)
        registerArtworkRefreshers(
            for: template,
            items: zip(limited, items).map { (albumArtworkKey(for: $0.0), $0.1) }
        )
        fetchMissingArtwork(forAlbumsIn: template, albums: limited)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func pushArtistsList() {
        let store = LibraryStore.shared
        let artists = store.artists.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let (limited, hiddenCount) = Self.limitedForDisplay(artists)
        let items: [CPListItem] = limited.map { artist in
            let count = artist.albumIDs.count
            let item = CPListItem(
                text: artist.name,
                detailText: "\(count) album\(count == 1 ? "" : "s")"
            )
            item.accessoryType = .disclosureIndicator
            applyArtwork(artistArtworkKey(for: artist), to: item)
            item.handler = { [weak self] _, completion in
                self?.pushArtist(artist, store: store); completion()
            }
            return item
        }
        var sections = [CPListSection(items: items)]
        if let notice = Self.truncationSection(hidden: hiddenCount) {
            sections.append(notice)
        }
        let template = CPListTemplate(title: "Artists", sections: sections)
        registerArtworkRefreshers(
            for: template,
            items: zip(limited, items).map { (artistArtworkKey(for: $0.0), $0.1) }
        )
        fetchMissingArtwork(forArtistsIn: template, artists: limited)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func pushPlaylistsList() {
        let store = LibraryStore.shared
        let playlists = store.playlists.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let (limited, hiddenCount) = Self.limitedForDisplay(playlists)
        let items: [CPListItem] = limited.map { playlist in
            let count = playlist.trackIDs.count
            let item = CPListItem(
                text: playlist.name,
                detailText: "\(count) song\(count == 1 ? "" : "s")"
            )
            item.accessoryType = .disclosureIndicator
            item.setImage(UIImage(systemName: "music.note.list"))
            item.handler = { [weak self] _, completion in
                self?.pushPlaylist(playlist, store: store); completion()
            }
            return item
        }
        var sections = [CPListSection(items: items)]
        if let notice = Self.truncationSection(hidden: hiddenCount) {
            sections.append(notice)
        }
        let template = CPListTemplate(title: "Playlists", sections: sections)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func pushSongsList() {
        let store = LibraryStore.shared
        let tracks = store.tracks.values.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        if tracks.count <= CPListTemplate.maximumItemCount {
            let template = makeFlatSongsTemplate(title: "Songs", tracks: Array(tracks))
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        // Paginate by first letter for large libraries.
        var buckets: [(String, [Track])] = []
        var current: (String, [Track])?
        for t in tracks {
            let letter = firstSortLetter(t.title)
            if current?.0 != letter {
                if let c = current { buckets.append(c) }
                current = (letter, [t])
            } else {
                current?.1.append(t)
            }
        }
        if let c = current { buckets.append(c) }

        let items: [CPListItem] = buckets.map { letter, group in
            let item = CPListItem(text: letter, detailText: "\(group.count)")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                let tpl = self.makeFlatSongsTemplate(title: letter, tracks: group)
                self.interfaceController?.pushTemplate(tpl, animated: true, completion: nil)
                completion()
            }
            return item
        }

        let template = CPListTemplate(title: "Songs", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func makeFlatSongsTemplate(title: String, tracks: [Track]) -> CPListTemplate {
        let (limited, hiddenCount) = Self.limitedForDisplay(tracks)
        let items: [CPListItem] = limited.enumerated().map { i, track in
            makeTrackItem(track, in: limited, startIndex: i, detailIsArtist: true)
        }
        var sections = [CPListSection(items: items)]
        if let notice = Self.truncationSection(hidden: hiddenCount) {
            sections.append(notice)
        }
        let template = CPListTemplate(title: title, sections: sections)
        registerArtworkRefreshers(
            for: template,
            items: zip(limited, items).map { (trackArtworkKey(for: $0.0), $0.1) }
        )
        fetchMissingArtwork(forTracksIn: template, tracks: limited)
        return template
    }

    // MARK: - Genres

    /// Tracks bucketed by genre, ignoring blank tags. Derived on demand —
    /// LibraryStore indexes albums and artists but not genres.
    static func genreBuckets(in tracks: some Collection<Track>) -> [String: [Track]] {
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            let genre = track.genre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !genre.isEmpty else { continue }
            buckets[genre, default: []].append(track)
        }
        return buckets
    }

    private func pushGenresList() {
        let store = LibraryStore.shared
        let buckets = Self.genreBuckets(in: store.tracks.values)
        let names = buckets.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        let (limited, hiddenCount) = Self.limitedForDisplay(names)

        let items: [CPListItem] = limited.map { genre in
            let tracks = buckets[genre] ?? []
            let item = CPListItem(text: genre, detailText: "\(tracks.count)")
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                guard let self else { completion(); return }
                let sorted = tracks.sorted {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                let tpl = self.makeFlatSongsTemplate(title: genre, tracks: sorted)
                self.interfaceController?.pushTemplate(tpl, animated: true, completion: nil)
                completion()
            }
            return item
        }

        var sections = [CPListSection(items: items)]
        if let notice = Self.truncationSection(hidden: hiddenCount) {
            sections.append(notice)
        }
        let template = CPListTemplate(title: "Genres", sections: sections)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Truncation

    /// Trims a collection to CarPlay's row cap, reserving one row for the
    /// "more not shown" notice when trimming is needed.
    ///
    /// `maximumItemCount` applies to the whole template, not to each section, so
    /// taking `prefix(maximumItemCount)` and then appending a notice section
    /// would put the template one row over the limit.
    static func limitedForDisplay<T>(_ all: [T]) -> (shown: [T], hidden: Int) {
        let cap = CPListTemplate.maximumItemCount
        guard all.count > cap else { return (all, 0) }
        let shown = Array(all.prefix(cap - 1))
        return (shown, all.count - shown.count)
    }

    /// Where a list is cut short, say so — silently dropping rows leaves the
    /// user believing a track simply is not in their library.
    private static func truncationSection(hidden: Int) -> CPListSection? {
        guard hidden > 0 else { return nil }
        let item = CPListItem(
            text: "\(hidden) more not shown",
            detailText: "CarPlay limits list length. Use Search to find the rest."
        )
        item.isEnabled = false
        return CPListSection(items: [item])
    }

    // MARK: - Album drill-down

    private func pushAlbum(_ album: Album, store: LibraryStore) {
        let albumTracks = album.trackIDs.compactMap { store.tracks[$0] }
        guard !albumTracks.isEmpty else { return }

        let playAll = CPListItem(
            text: "Play All",
            detailText: "\(albumTracks.count) song\(albumTracks.count == 1 ? "" : "s")"
        )
        playAll.setImage(UIImage(systemName: "play.fill"))
        playAll.handler = { _, completion in
            Task { @MainActor in
                PlaybackService.shared.queue.shuffleMode = .off
                PlaybackService.shared.replace(with: albumTracks, startAt: 0)
                completion()
            }
        }

        let shuffle = CPListItem(text: "Shuffle", detailText: nil)
        shuffle.setImage(UIImage(systemName: "shuffle"))
        shuffle.handler = { _, completion in
            Task { @MainActor in
                var shuffled = albumTracks; shuffled.shuffle()
                PlaybackService.shared.replace(with: shuffled, startAt: 0)
                completion()
            }
        }

        let trackItems: [CPListItem] = albumTracks.enumerated().map { (i, track) in
            let detail = track.durationSeconds > 0 ? formatDuration(track.durationSeconds) : nil
            let item = CPListItem(text: track.title, detailText: detail)
            applyArtwork(trackArtworkKey(for: track) ?? albumArtworkKey(for: album), to: item)
            if PlaybackService.shared.state.currentTrackID == track.id { item.isPlaying = true }
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
        registerArtworkRefreshers(
            for: template,
            items: zip(albumTracks, trackItems).map {
                (trackArtworkKey(for: $0.0) ?? albumArtworkKey(for: album), $0.1)
            }
        )
        fetchMissingArtwork(forTracksIn: template, tracks: albumTracks)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Artist drill-down

    private func pushArtist(_ artist: Artist, store: LibraryStore) {
        let albums = artist.albumIDs
            .compactMap { store.albums[$0] }
            .sorted { ($0.year ?? 0, $0.title) < ($1.year ?? 0, $1.title) }
        guard !albums.isEmpty else { return }

        let items: [CPListItem] = albums.map { album in
            let detail: String? = album.year.map { String($0) }
            let item = CPListItem(text: album.title, detailText: detail)
            item.accessoryType = .disclosureIndicator
            applyArtwork(albumArtworkKey(for: album), to: item)
            item.handler = { [weak self] _, completion in
                self?.pushAlbum(album, store: store); completion()
            }
            return item
        }

        let template = CPListTemplate(title: artist.name, sections: [CPListSection(items: items)])
        registerArtworkRefreshers(
            for: template,
            items: zip(albums, items).map { (albumArtworkKey(for: $0.0), $0.1) }
        )
        fetchMissingArtwork(forAlbumsIn: template, albums: albums)
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
        playAll.setImage(UIImage(systemName: "play.fill"))
        playAll.handler = { _, completion in
            Task { @MainActor in
                PlaybackService.shared.queue.shuffleMode = .off
                PlaybackService.shared.replace(with: playlistTracks, startAt: 0)
                completion()
            }
        }

        let shuffle = CPListItem(text: "Shuffle", detailText: nil)
        shuffle.setImage(UIImage(systemName: "shuffle"))
        shuffle.handler = { _, completion in
            Task { @MainActor in
                var shuffled = playlistTracks; shuffled.shuffle()
                PlaybackService.shared.replace(with: shuffled, startAt: 0)
                completion()
            }
        }

        let trackItems: [CPListItem] = playlistTracks.enumerated().map { (i, track) in
            makeTrackItem(track, in: playlistTracks, startIndex: i, detailIsArtist: true)
        }

        let header = CPListSection(items: [playAll, shuffle])
        let tracks = CPListSection(items: trackItems)
        let template = CPListTemplate(title: playlist.name, sections: [header, tracks])
        registerArtworkRefreshers(
            for: template,
            items: zip(playlistTracks, trackItems).map { (trackArtworkKey(for: $0.0), $0.1) }
        )
        fetchMissingArtwork(forTracksIn: template, tracks: playlistTracks)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Search

    private func makeSearchBarButton() -> CPBarButton {
        if let icon = UIImage(systemName: "magnifyingglass") {
            return CPBarButton(image: icon) { [weak self] _ in
                self?.pushSearchTemplate()
            }
        }
        return CPBarButton(title: "Search") { [weak self] _ in
            self?.pushSearchTemplate()
        }
    }

    private func pushSearchTemplate() {
        let template = CPSearchTemplate()
        template.delegate = self
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    fileprivate func performSearch(_ query: String) -> ([CPListItem], [Track]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }
        let q = trimmed.lowercased()
        let store = LibraryStore.shared

        let hits = store.tracks.values.filter {
            $0.title.lowercased().contains(q)
            || $0.artist.lowercased().contains(q)
            || $0.album.lowercased().contains(q)
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        .prefix(CPListTemplate.maximumItemCount)

        let allTracks = Array(hits)
        let items = allTracks.enumerated().map { (i, track) in
            makeTrackItem(track, in: allTracks, startIndex: i, detailIsArtist: true)
        }
        return (items, allTracks)
    }

    // MARK: - Track item factory

    private func makeTrackItem(
        _ track: Track,
        in queue: [Track],
        startIndex: Int,
        detailIsArtist: Bool
    ) -> CPListItem {
        let detail = detailIsArtist ? track.artist : track.album
        let item = CPListItem(text: displayTitle(for: track), detailText: detail.isEmpty ? nil : detail)
        applyArtwork(trackArtworkKey(for: track), to: item)
        if PlaybackService.shared.state.currentTrackID == track.id {
            item.isPlaying = true
        }
        item.handler = { _, completion in
            Task { @MainActor in
                PlaybackService.shared.replace(with: queue, startAt: startIndex)
                completion()
            }
        }
        return item
    }

    // MARK: - Artwork key helpers

    private func trackArtworkKey(for track: Track) -> String? {
        if let k = track.artworkCacheKey, !k.isEmpty { return k }
        if track.artist.isEmpty || track.album.isEmpty { return nil }
        return ArtworkFetchService.generateCacheKey(artist: track.artist, album: track.album)
    }

    private func albumArtworkKey(for album: Album) -> String? {
        if let k = album.artworkCacheKey, !k.isEmpty { return k }
        if album.artist.isEmpty || album.title.isEmpty { return nil }
        return ArtworkFetchService.generateCacheKey(artist: album.artist, album: album.title)
    }

    private func artistArtworkKey(for artist: Artist) -> String? {
        if let k = artist.artworkCacheKey, !k.isEmpty { return k }
        guard !artist.name.isEmpty else { return nil }
        return ArtworkFetchService.generateArtistPhotoKey(name: artist.name)
    }

    // MARK: - Artwork

    private func applyArtwork(_ key: String?, to item: CPListItem) {
        let placeholder = UIImage(systemName: "music.note")
        guard let key, !key.isEmpty else {
            item.setImage(placeholder)
            return
        }
        if let img = ArtworkCache.shared.thumbnailImage(forKey: key)
            ?? ArtworkCache.shared.gridImage(forKey: key)
            ?? ArtworkCache.shared.fullImage(forKey: key) {
            item.setImage(img)
        } else {
            item.setImage(placeholder)
        }
    }

    private func registerArtworkRefreshers(
        for template: CPTemplate,
        items: [(String?, CPListItem)]
    ) {
        let id = ObjectIdentifier(template)
        let refreshers: [(String, WeakItem)] = items.compactMap { key, item in
            guard let key, !key.isEmpty else { return nil }
            return (key, WeakItem(item))
        }
        artworkRefreshers[id] = refreshers
    }

    /// For each registered cache key, kicks off a background fetch if the
    /// artwork isn't on disk yet. The `ArtworkCache.artworkDidUpdate`
    /// notification will then drive a re-render via `applyArtwork(forKey:)`.
    private func fetchMissingArtwork(forAlbumsIn template: CPTemplate, albums: [Album]) {
        for album in albums {
            let key = album.artworkCacheKey
                ?? ArtworkFetchService.generateCacheKey(artist: album.artist, album: album.title)
            guard !key.isEmpty, !ArtworkCache.shared.hasArtwork(forKey: key) else { continue }
            Task.detached(priority: .utility) {
                await ArtworkFetchService.shared.fetchAlbumArtIfNeeded(
                    artist: album.artist, album: album.title
                )
            }
        }
    }

    private func fetchMissingArtwork(forTracksIn template: CPTemplate, tracks: [Track]) {
        for track in tracks {
            Task.detached(priority: .utility) {
                await ArtworkFetchService.shared.fetchIfNeeded(for: track)
            }
        }
    }

    private func fetchMissingArtwork(forArtistsIn template: CPTemplate, artists: [Artist]) {
        for artist in artists {
            guard !ArtworkCache.shared.hasArtwork(forKey: artist.artworkCacheKey ?? "") else { continue }
            Task.detached(priority: .utility) {
                await ArtworkFetchService.shared.fetchArtistPhotoIfNeeded(name: artist.name)
            }
        }
    }

    private func applyArtwork(forKey key: String) {
        let image = ArtworkCache.shared.thumbnailImage(forKey: key)
            ?? ArtworkCache.shared.gridImage(forKey: key)
            ?? ArtworkCache.shared.fullImage(forKey: key)
        guard let image else { return }
        for (_, refreshers) in artworkRefreshers {
            for (k, weakItem) in refreshers where k == key {
                weakItem.item?.setImage(image)
            }
        }
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func firstSortLetter(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard let scalar = trimmed.unicodeScalars.first else { return "#" }
        if CharacterSet.letters.contains(scalar) {
            return String(scalar).uppercased()
        }
        return "#"
    }
}

// MARK: - CPSearchTemplateDelegate

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        updatedSearchText searchText: String,
        completionHandler: @escaping ([CPListItem]) -> Void
    ) {
        let (items, _) = performSearch(searchText)
        completionHandler(items)
    }

    func searchTemplate(
        _ searchTemplate: CPSearchTemplate,
        selectedResult item: CPListItem,
        completionHandler: @escaping () -> Void
    ) {
        if let handler = item.handler {
            handler(item, completionHandler)
        } else {
            completionHandler()
        }
    }
}

// MARK: - CPNowPlayingTemplateObserver

extension CarPlaySceneDelegate: CPNowPlayingTemplateObserver {
    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in self?.handleUpNextTapped() }
    }

    nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in self?.handleAlbumArtistTapped() }
    }

    private func handleUpNextTapped() {
        guard let interfaceController else { return }
        let q = PlaybackService.shared.queue
        let upcoming = Array(q.tracks.dropFirst(q.currentIndex + 1).prefix(CPListTemplate.maximumItemCount))
        guard !upcoming.isEmpty else {
            refreshNowPlayingButtonAvailability()
            return
        }
        let baseIndex = q.currentIndex + 1
        let items: [CPListItem] = upcoming.enumerated().map { (i, track) in
            let item = CPListItem(text: displayTitle(for: track),
                                  detailText: track.artist.isEmpty ? nil : track.artist)
            applyArtwork(trackArtworkKey(for: track), to: item)
            item.handler = { _, completion in
                Task { @MainActor in
                    PlaybackService.shared.skipTo(index: baseIndex + i)
                    completion()
                }
            }
            return item
        }
        let template = CPListTemplate(title: "Up Next", sections: [CPListSection(items: items)])
        registerArtworkRefreshers(
            for: template,
            items: zip(upcoming, items).map { (trackArtworkKey(for: $0.0), $0.1) }
        )
        fetchMissingArtwork(forTracksIn: template, tracks: upcoming)
        interfaceController.pushTemplate(template, animated: true) { success, error in
            if !success {
                NSLog("[CarPlay] Up Next push failed: %@", error?.localizedDescription ?? "unknown")
            }
        }
    }

    private func displayTitle(for track: Track) -> String {
        let trimmed = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown Track" : trimmed
    }

    private func handleAlbumArtistTapped() {
        guard let track = PlaybackService.shared.queue.currentTrack else { return }
        let store = LibraryStore.shared
        let artist = track.albumArtist.isEmpty ? track.artist : track.albumArtist
        let albumKey = "\(artist)//\(track.album)"
        if let album = store.albums[albumKey] {
            pushAlbum(album, store: store)
        }
    }
}
