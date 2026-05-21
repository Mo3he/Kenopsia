import Foundation
import Combine
import Darwin

// MARK: - SourceViewModel
/// Manages the list of configured music sources and delegates scanning to LibraryViewModel.
@MainActor
final class SourceViewModel: ObservableObject {
    @Published private(set) var sources: [MusicSource] = []
    @Published var isAddingSource = false
    @Published var wifiTransferActive = false
    @Published private(set) var wifiTransferURL: String?

    // Keeps security-scoped folder URLs alive so AVAudioFile can open files
    // in user-selected local folders throughout the app's lifetime.
    private var localScopeURLs: [MusicSourceID: URL] = [:]
    // Active scan tasks — stored so they can be cancelled by the user.
    private var scanTasks: [MusicSourceID: Task<Void, Never>] = [:]
    private let resolver: SourceResolver
    private var wifiService: WiFiTransferService?
    private var wifiUploadObserver: NSObjectProtocol?
    private let defaults = UserDefaults(suiteName: "group.net.mohome.kenopsia")

    // Weak ref to library for scanning — injected after init to avoid circular dependency
    weak var libraryViewModel: LibraryViewModel?

    init(resolver: SourceResolver = .shared) {
        self.resolver = resolver
        load()
    }

    // MARK: - CRUD
    func add(source: MusicSource) {
        sources.append(source)
        registerAdapter(for: source)
        activateSecurityScope(for: source)
        save()
        // Auto-scan immediately if enabled
        if source.isEnabled { scan(source: source) }
    }

    func update(source: MusicSource) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        let old = sources[idx]
        sources[idx] = source
        registerAdapter(for: source)
        // If the pin was toggled off, evict all cached files for this source.
        if old.isPinnedOffline && !source.isPinnedOffline {
            Task { await OfflineCacheService.shared.unpinSource(sourceID: source.id) }
        }
        // If the pin was just toggled ON, start caching tracks for offline use.
        if !old.isPinnedOffline && source.isPinnedOffline {
            let src = source
            Task { [weak self] in
                guard let self else { return }
                let tracks = Array(LibraryStore.shared.tracks.values.filter { $0.source == src.id })
                if !tracks.isEmpty {
                    await OfflineCacheService.shared.pinSource(src, tracks: tracks, resolver: self.resolver)
                } else {
                    // No tracks yet — trigger a scan which will pin at the end.
                    self.scan(source: src)
                }
            }
        }
        save()
    }

    /// Cancel an in-progress scan for the given source.
    func cancelScan(for sourceID: MusicSourceID) {
        scanTasks[sourceID]?.cancel()
        scanTasks.removeValue(forKey: sourceID)
    }

    func delete(sourceID: MusicSourceID) {
        cancelScan(for: sourceID)
        if let source = sources.first(where: { $0.id == sourceID }) {
            // Revoke security-scoped access for local sources.
            localScopeURLs.removeValue(forKey: sourceID)?.stopAccessingSecurityScopedResource()
            // Delete Keychain entries so credentials are not orphaned.
            switch source.config {
            case .subsonic(let c):     if !c.keychainKey.isEmpty { KeychainHelper.shared.delete(key: c.keychainKey) }
            case .nas(let c):          if !c.keychainKey.isEmpty { KeychainHelper.shared.delete(key: c.keychainKey) }
            case .cloud(let c):        if !c.keychainKey.isEmpty { KeychainHelper.shared.delete(key: c.keychainKey) }
            case .wifiTransfer(let c): if !c.keychainKey.isEmpty { KeychainHelper.shared.delete(key: c.keychainKey) }
            default: break
            }
            // Evict offline cache.
            Task { await OfflineCacheService.shared.unpinSource(sourceID: sourceID) }
        }
        sources.removeAll { $0.id == sourceID }
        LibraryStore.shared.removeTracks(from: sourceID)
        save()
    }

    // MARK: - Scanning
    /// Scan a source and populate the library. Calls back with a result summary string.
    func scan(source: MusicSource, completion: ((String) -> Void)? = nil) {
        guard source.isEnabled else {
            completion?("Source is disabled")
            return
        }
        // Cancel any existing scan for this source before starting a new one.
        scanTasks[source.id]?.cancel()
        let task = Task {
            defer { scanTasks.removeValue(forKey: source.id) }
            do {
                let tracks: [Track]
                switch source.config {
                case .local(let cfg):
                    guard let bookmark = cfg.bookmarkData else {
                        completion?("No folder selected — tap 'Choose Folder' first")
                        return
                    }
                    var stale = false
                    let url = try URL(
                        resolvingBookmarkData: bookmark,
                        options: .withoutUI,
                        relativeTo: nil,
                        bookmarkDataIsStale: &stale
                    )
                    if localScopeURLs[source.id] == nil {
                        _ = url.startAccessingSecurityScopedResource()
                        localScopeURLs[source.id] = url
                    }
                    let scopeURL = localScopeURLs[source.id] ?? url
                    let scanner = LibraryScanner(store: LibraryStore.shared)
                    tracks = await scanner.scan(source: source, urls: [scopeURL])
                    // LibraryScanner.scan() calls store.merge() internally before returning.
                    // If the source was deleted while the scan was running, undo that merge now.
                    if !self.sources.contains(where: { $0.id == source.id }) {
                        LibraryStore.shared.removeTracks(from: source.id)
                        return
                    }

                case .subsonic:
                    guard let adapter = await resolver.adapter(for: source.id) as? SubsonicSourceAdapter else {
                        completion?("Adapter not registered — try removing and re-adding this source")
                        return
                    }
                    tracks = try await adapter.fetchTracks()
                    try Task.checkCancellation()
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                case .nas:
                    guard let adapter = await resolver.adapter(for: source.id) as? NASSourceAdapter else {
                        completion?("Adapter not registered")
                        return
                    }
                    tracks = try await adapter.fetchTracks()
                    try Task.checkCancellation()
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                case .webRadio(let cfg):
                    // Web radio stations become individual "tracks" in the library.
                    // Always replace — merge would leave removed stations as stale tracks.
                    tracks = cfg.stations.compactMap { station in
                        guard let url = URL(string: station.streamURL) else { return nil }
                        return Track(
                            title: station.name,
                            artist: "Web Radio",
                            albumArtist: "Web Radio",
                            album: station.genre.isEmpty ? "Web Radio" : station.genre,
                            genre: station.genre,
                            source: source.id,
                            uri: .webRadio(streamURL: url),
                            format: .mp3,
                            durationSeconds: 0   // live stream — duration unknown
                        )
                    }
                    try Task.checkCancellation()
                    LibraryStore.shared.removeTracks(from: source.id)  // prune removed stations
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                case .cloud:
                    guard let adapter = await resolver.adapter(for: source.id) as? CloudSourceAdapter else {
                        completion?("Adapter not registered — try removing and re-adding this source")
                        return
                    }
                    tracks = try await adapter.fetchTracks()
                    try Task.checkCancellation()
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                case .appleMusic:
                    guard let adapter = await resolver.adapter(for: source.id) as? AppleMusicService else {
                        completion?("Adapter not registered — try removing and re-adding this source")
                        return
                    }
                    tracks = try await adapter.fetchTracks()
                    try Task.checkCancellation()
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                default:
                    completion?("This source type does not support scanning")
                    return
                }

                let count = tracks.count
                completion?(count == 0 ? "No tracks found" : "Found \(count) track\(count == 1 ? "" : "s")")

                // Persist the track count and scan timestamp so the source row can
                // show status without querying the full library each render.
                if let idx = self.sources.firstIndex(where: { $0.id == source.id }) {
                    self.sources[idx].trackCount = count
                    self.sources[idx].lastScanDate = Date()
                    self.save()
                }

                // If the source is pinned for offline, cache all tracks now.
                if source.isPinnedOffline && !tracks.isEmpty {
                    await OfflineCacheService.shared.pinSource(source, tracks: tracks, resolver: resolver)
                }
            } catch is CancellationError {
                completion?("Scan cancelled")
            } catch {
                completion?("Error: \(error.localizedDescription)")
            }
        }
        scanTasks[source.id] = task
    }

    // MARK: - Wi-Fi Transfer
    func startWiFiTransfer() {
        guard let source = sources.first(where: { $0.kind == .wifiTransfer }),
              case .wifiTransfer(let config) = source.config else { return }
        let svc = WiFiTransferService(sourceID: source.id, config: config)
        wifiService = svc
        Task {
            await svc.start()
            wifiTransferActive = true
            let port = config.port
            wifiTransferURL = "http://\(localIPAddress() ?? "device"):\(port)"
        }
        // Observe uploads so we auto-scan newly received files into the library.
        // Remove any existing observer first to avoid stacking duplicates on restart.
        if let existing = wifiUploadObserver {
            NotificationCenter.default.removeObserver(existing)
        }
        // The notification is always posted on the main thread (see SimpleHTTPServer),
        // so MainActor.assumeIsolated is safe here.
        wifiUploadObserver = NotificationCenter.default.addObserver(
            forName: .wifiTransferDidReceiveFiles, object: nil, queue: .main
        ) { [weak self] notification in
            guard let folder = notification.object as? URL else { return }
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                guard let wifiSource = self.sources.first(where: { $0.kind == .wifiTransfer }) else { return }
                self.libraryViewModel?.scanFolder(folder, for: wifiSource)
            }
        }
    }

    func stopWiFiTransfer() {
        guard let svc = wifiService else { return }
        Task { await svc.stop(); wifiTransferActive = false; wifiTransferURL = nil }
        wifiService = nil
    }

    /// Update Wi-Fi Transfer password settings. Restarts the service if it is active.
    func updateWiFiTransferConfig(requiresPassword: Bool, password: String) {
        guard let idx = sources.firstIndex(where: { $0.kind == .wifiTransfer }),
              case .wifiTransfer(var cfg) = sources[idx].config else { return }
        cfg.requiresPassword = requiresPassword
        if requiresPassword {
            let key = cfg.keychainKey.isEmpty ? "wifi_\(sources[idx].id.rawValue)" : cfg.keychainKey
            try? KeychainHelper.shared.save(key: key, value: password)
            cfg.keychainKey = key
        }
        sources[idx].config = .wifiTransfer(cfg)
        save()
        // If the server is running, restart it so the new password takes effect.
        if wifiTransferActive { stopWiFiTransfer(); startWiFiTransfer() }
    }

    // MARK: - Apple Music
    /// Requests MusicKit authorisation and imports the user's library into the store.
    func connectAppleMusic(source: MusicSource) async {
        let authorised = await AppleMusicService.requestAuthorisation()
        guard authorised else { return }

        // Update the source config to mark it as authorised.
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        if case .appleMusic(var cfg) = sources[idx].config {
            cfg.isAuthorised = true
            sources[idx].config = .appleMusic(cfg)
            save()
        }

        // Scan the library — reuse the existing scan pipeline.
        scan(source: sources[idx]) { [weak self] result in
            guard let self else { return }
            if let idx = self.sources.firstIndex(where: { $0.id == source.id }),
               case .appleMusic(var cfg) = self.sources[idx].config,
               let count = Int(result.components(separatedBy: " ").first ?? "") {
                cfg.lastFetchedCount = count
                self.sources[idx].config = .appleMusic(cfg)
                self.save()
            }
        }
    }

    // MARK: - Adapters
    private func registerAdapter(for source: MusicSource) {
        switch source.config {
        case .subsonic(let config):
            let adapter = SubsonicSourceAdapter(sourceID: source.id, config: config)
            Task { await resolver.register(adapter: adapter, for: source.id) }
        case .nas(let config):
            let adapter = NASSourceAdapter(sourceID: source.id, config: config)
            Task { await resolver.register(adapter: adapter, for: source.id) }
        case .cloud(let config):
            let adapter = CloudSourceAdapter(sourceID: source.id, config: config)
            Task { await resolver.register(adapter: adapter, for: source.id) }
        case .appleMusic(let config):
            let adapter = AppleMusicService(sourceID: source.id, config: config)
            Task { await resolver.register(adapter: adapter, for: source.id) }
        default:
            break
        }
    }

    // MARK: - Persistence
    private func save() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults?.set(data, forKey: "sources")
        }
    }

    private func load() {
        guard let data = defaults?.data(forKey: "sources"),
              let saved = try? JSONDecoder().decode([MusicSource].self, from: data) else {
            sources = [
                MusicSource(kind: .local, displayName: "On This iPhone", config: .local(LocalSourceConfig())),
                MusicSource(kind: .wifiTransfer, displayName: "Wi-Fi Transfer", config: .wifiTransfer(WiFiTransferConfig())),
            ]
            return
        }
        sources = saved
        // Ensure the built-in Wi-Fi Transfer source always exists
        if !sources.contains(where: { $0.kind == .wifiTransfer }) {
            sources.append(MusicSource(kind: .wifiTransfer, displayName: "Wi-Fi Transfer", config: .wifiTransfer(WiFiTransferConfig())))
            save()
        }
        sources.forEach { registerAdapter(for: $0) }
        // Re-activate security scopes for all local sources so files are accessible
        // immediately on launch (not only after the user triggers a scan).
        sources.filter { $0.kind == .local }.forEach { activateSecurityScope(for: $0) }
    }

    private func activateSecurityScope(for source: MusicSource) {
        guard case .local(let cfg) = source.config,
              let bookmark = cfg.bookmarkData,
              localScopeURLs[source.id] == nil else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: .withoutUI,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        _ = url.startAccessingSecurityScopedResource()
        localScopeURLs[source.id] = url
    }

    // MARK: - Helpers
    private func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0 {
            var ptr = ifaddr
            while let ifa = ptr?.pointee {
                defer { ptr = ifa.ifa_next }
                let name = String(cString: ifa.ifa_name)
                // Accept any IPv4 interface that is not the loopback adapter.
                // This covers en0 (Wi-Fi), en1 (Ethernet/USB), bridge0, etc.
                guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                      name != "lo0" else { continue }
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
                // Prefer en0/en1 over bridge/virtual interfaces but don't abort early;
                // keep iterating so the last non-loopback address wins if nothing else matches.
                if name.hasPrefix("en") { break }
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
