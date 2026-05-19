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

    private let resolver: SourceResolver
    private var wifiService: WiFiTransferService?
    private var wifiUploadObserver: NSObjectProtocol?
    private let defaults = UserDefaults(suiteName: "group.net.mohome.kenopsia")

    // Weak ref to library for scanning — injected after init to avoid circular dependency
    weak var libraryViewModel: LibraryViewModel?

    init(resolver: SourceResolver = SourceResolver()) {
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
        sources[idx] = source
        registerAdapter(for: source)
        save()
    }

    func delete(sourceID: MusicSourceID) {
        if let source = sources.first(where: { $0.id == sourceID }),
           let url = localScopeURLs.removeValue(forKey: sourceID) {
            _ = source  // suppress unused warning
            url.stopAccessingSecurityScopedResource()
        }
        sources.removeAll { $0.id == sourceID }
        save()
    }

    // MARK: - Scanning
    /// Scan a source and populate the library. Calls back with a result summary string.
    func scan(source: MusicSource, completion: ((String) -> Void)? = nil) {
        guard source.isEnabled else {
            completion?("Source is disabled")
            return
        }
        Task {
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

                case .subsonic:
                    guard let adapter = await resolver.adapter(for: source.id) as? SubsonicSourceAdapter else {
                        completion?("Adapter not registered — try removing and re-adding this source")
                        return
                    }
                    tracks = try await adapter.fetchTracks()
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                case .nas:
                    guard let adapter = await resolver.adapter(for: source.id) as? NASSourceAdapter else {
                        completion?("Adapter not registered")
                        return
                    }
                    tracks = try await adapter.fetchTracks()
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                case .webRadio(let cfg):
                    // Web radio stations become individual "tracks" in the library
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
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                case .cloud:
                    guard let adapter = await resolver.adapter(for: source.id) as? CloudSourceAdapter else {
                        completion?("Adapter not registered — try removing and re-adding this source")
                        return
                    }
                    tracks = try await adapter.fetchTracks()
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                case .appleMusic:
                    guard let adapter = await resolver.adapter(for: source.id) as? AppleMusicService else {
                        completion?("Adapter not registered — try removing and re-adding this source")
                        return
                    }
                    tracks = try await adapter.fetchTracks()
                    LibraryStore.shared.merge(tracks: tracks, from: source.id)

                default:
                    completion?("This source type does not support scanning")
                    return
                }

                let count = tracks.count
                completion?(count == 0 ? "No tracks found" : "Found \(count) track\(count == 1 ? "" : "s")")

                // If the source is pinned for offline, cache all tracks now.
                if source.isPinnedOffline && !tracks.isEmpty {
                    await OfflineCacheService.shared.pinSource(source, tracks: tracks, resolver: resolver)
                }
            } catch {
                completion?("Error: \(error.localizedDescription)")
            }
        }
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
            wifiTransferURL = "http://\(localIPAddress() ?? "device"):8383"
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
                guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET),
                      String(cString: ifa.ifa_name) == "en0" else { continue }
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                address = String(cString: hostname)
            }
            freeifaddrs(ifaddr)
        }
        return address
    }
}
