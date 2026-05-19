import Foundation

// MARK: - OfflineCacheService
/// Downloads and pins remote tracks for offline listening.
/// When a source has `isPinnedOffline = true`, all its tracks are cached locally.
/// Cached files live in the App Group container under OfflineCache/<sourceID>/<trackID>.<ext>
actor OfflineCacheService {
    static let shared = OfflineCacheService()

    // Foreground session — background sessions don't support async/await download(from:).
    private let session = URLSession.shared
    private let cacheRoot: URL

    // Progress tracking — keyed by track ID
    private var inProgress: [UUID: Progress] = [:]
    private(set) var cachedTrackIDs: Set<UUID> = []

    private init() {
        let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.kenopsia")
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        cacheRoot = container.appendingPathComponent("OfflineCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        self.cachedTrackIDs = Self.loadCachedIDsFrom(
            cacheRoot: cacheRoot.appendingPathComponent("index.json")
        )
    }

    // MARK: - Public API
    func isCached(_ track: Track) -> Bool { cachedTrackIDs.contains(track.id) }

    func localURL(for track: Track) -> URL? {
        let url = path(for: track)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Download all tracks from a source and cache them.
    /// `resolver` must be the PlaybackService's resolver so adapters are registered.
    func pinSource(_ source: MusicSource, tracks: [Track], resolver: SourceResolver) async {
        for track in tracks {
            guard !isCached(track) else { continue }
            await download(track: track, resolver: resolver)
        }
    }

    /// Remove all cached files for a source.
    func unpinSource(sourceID: MusicSourceID) {
        let dir = cacheRoot.appendingPathComponent(sourceID.rawValue.uuidString)
        try? FileManager.default.removeItem(at: dir)
        // Remove IDs whose files are now gone (the directory was deleted above).
        cachedTrackIDs = cachedTrackIDs.filter {
            FileManager.default.fileExists(
                atPath: cacheRoot
                    .appendingPathComponent(sourceID.rawValue.uuidString)
                    .appendingPathComponent($0.uuidString).path
            )
        }
        persistCachedIDs()
    }

    func delete(track: Track) {
        let url = path(for: track)
        try? FileManager.default.removeItem(at: url)
        cachedTrackIDs.remove(track.id)
        persistCachedIDs()
    }

    // MARK: - Download
    private func download(track: Track, resolver: SourceResolver) async {
        do {
            let remoteURL = try await resolver.localURL(for: track)
            // For tracks already on-device (local files), just record them as cached.
            if case .localFile = track.uri {
                cachedTrackIDs.insert(track.id)
                persistCachedIDs()
                return
            }

            let dest = path(for: track)
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let (tempURL, response) = try await session.download(from: remoteURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tempURL, to: dest)

            cachedTrackIDs.insert(track.id)
            persistCachedIDs()
        } catch {
            // Download failures are silently skipped; will retry on next pin.
        }
    }

    // MARK: - Paths
    private func path(for track: Track) -> URL {
        let ext = track.format.rawValue
        return cacheRoot
            .appendingPathComponent(track.source.rawValue.uuidString)
            .appendingPathComponent(track.id.uuidString)
            .appendingPathExtension(ext)
    }

    // MARK: - Persistence
    nonisolated private static func loadCachedIDsFrom(cacheRoot: URL) -> Set<UUID> {
        guard let data = try? Data(contentsOf: cacheRoot),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }

    private func persistCachedIDs() {
        let index = cacheRoot.appendingPathComponent("index.json")
        if let data = try? JSONEncoder().encode(Array(cachedTrackIDs)) {
            try? data.write(to: index, options: .atomic)
        }
    }
}
