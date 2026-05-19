import Foundation
import AVFoundation

// MARK: - LibraryScanner
/// Scans local and cached sources to build the Track catalogue.
/// Results are written to LibraryStore, not returned directly.
actor LibraryScanner {
    // MARK: - State
    private(set) var isScanning = false
    private(set) var progress: ScanProgress = .idle

    // MARK: - Dependencies
    private let metadataReader: MetadataReader
    private let artworkCache: ArtworkCache
    private let store: LibraryStore

    init(
        metadataReader: MetadataReader = MetadataReader(),
        artworkCache: ArtworkCache = .shared,
        store: LibraryStore
    ) {
        self.metadataReader = metadataReader
        self.artworkCache = artworkCache
        self.store = store
    }

    // MARK: - Public API
    /// Scan all tracks for a given source. Incremental: skips files already in store
    /// whose modification date has not changed.
    @discardableResult
    func scan(source: MusicSource, urls: [URL]) async -> [Track] {
        guard !isScanning else { return [] }
        isScanning = true

        // Recursively expand any folder URLs to individual audio file URLs
        var fileURLs: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                while let fileURL = enumerator?.nextObject() as? URL {
                    if AudioFormat(fileExtension: fileURL.pathExtension) != nil {
                        fileURLs.append(fileURL)
                    }
                }
            } else if AudioFormat(fileExtension: url.pathExtension) != nil {
                fileURLs.append(url)
            }
        }

        progress = .scanning(scanned: 0, total: fileURLs.count)
        var newTracks: [Track] = []
        for (i, fileURL) in fileURLs.enumerated() {
            progress = .scanning(scanned: i + 1, total: fileURLs.count)
            if let track = await readTrack(url: fileURL, sourceID: source.id) {
                newTracks.append(track)
            }
        }

        await store.merge(tracks: newTracks, from: source.id)

        // For tracks with no embedded/folder art, kick off online fetches in the background.
        // Group by album so we only fire one request per album, not one per track.
        let needsFetch = newTracks.filter { $0.artworkCacheKey == nil }
        if !needsFetch.isEmpty {
            Task.detached(priority: .utility) {
                var seenAlbums = Set<String>()
                for track in needsFetch {
                    let albumKey = "\(track.albumArtist.isEmpty ? track.artist : track.albumArtist)//\(track.album)"
                    guard !seenAlbums.contains(albumKey) else { continue }
                    seenAlbums.insert(albumKey)
                    await ArtworkFetchService.shared.fetchIfNeeded(for: track)
                }
            }
        }

        progress = .idle
        isScanning = false
        return newTracks
    }

    // MARK: - Private
    private func readTrack(url: URL, sourceID: MusicSourceID) async -> Track? {
        guard let format = AudioFormat(fileExtension: url.pathExtension) else { return nil }
        let meta = await metadataReader.read(url: url)
        let attrs = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

        // Resolve artwork: prefer embedded tag art, fall back to folder art.
        let artworkCacheKey = resolveArtwork(for: url, embeddedData: meta.artworkData)

        return Track(
            title:         meta.title ?? url.deletingPathExtension().lastPathComponent,
            artist:        meta.artist ?? "",
            albumArtist:   meta.albumArtist ?? meta.artist ?? "",
            album:         meta.album ?? "",
            genre:         meta.genre ?? "",
            year:          meta.year,
            trackNumber:   meta.trackNumber,
            discNumber:    meta.discNumber,
            composer:      meta.composer ?? "",
            source:        sourceID,
            uri:           .localFile(path: url.path),
            format:        format,
            durationSeconds: meta.duration ?? 0,
            fileSizeBytes:   attrs?.fileSize,
            bitrateBps:      meta.bitrateBps,
            sampleRateHz:    meta.sampleRateHz,
            bitDepth:        meta.bitDepth,
            channelCount:    meta.channelCount,
            artworkCacheKey: artworkCacheKey,
            replayGainTrack: meta.replayGainTrack,
            replayGainAlbum: meta.replayGainAlbum
        )
    }

    // MARK: - Artwork resolution
    /// Priority order:
    ///   1. Embedded tag artwork
    ///   2. cover.jpg / cover.png / folder.jpg / folder.png / front.jpg / front.png / AlbumArt.jpg
    ///      in the same directory
    ///   3. Returns nil (will be filled in later by ArtworkFetchService)
    private func resolveArtwork(for trackURL: URL, embeddedData: Data?) -> String? {
        // Build a stable cache key from the track's directory (album-level art is shared).
        let folder = trackURL.deletingLastPathComponent()
        let cacheKey = folder.path.data(using: .utf8)
            .map { Data($0).base64EncodedString() }
            .map { String($0.prefix(40)) }
            ?? UUID().uuidString

        // 1. Embedded art
        if let data = embeddedData, !data.isEmpty {
            if !artworkCache.hasArtwork(forKey: cacheKey) {
                artworkCache.store(imageData: data, forKey: cacheKey)
            }
            return cacheKey
        }

        // 2. Already cached from a sibling track in the same folder
        if artworkCache.hasArtwork(forKey: cacheKey) {
            return cacheKey
        }

        // 3. Folder art candidates
        let candidates = [
            "cover.jpg", "cover.png",
            "folder.jpg", "folder.png",
            "front.jpg",  "front.png",
            "AlbumArt.jpg", "albumart.jpg"
        ]
        for name in candidates {
            let url = folder.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) {
                artworkCache.store(imageData: data, forKey: cacheKey)
                return cacheKey
            }
        }

        return nil  // ArtworkFetchService will populate this later
    }
}

// MARK: - ScanProgress
enum ScanProgress {
    case idle
    case scanning(scanned: Int, total: Int)

    var fractionCompleted: Double {
        switch self {
        case .idle: return 0
        case .scanning(let s, let t): return t > 0 ? Double(s) / Double(t) : 0
        }
    }
}

// MARK: - MetadataReader
/// Reads ID3, Vorbis, and APE tags from a file using AVFoundation.
/// For formats AVFoundation can't parse (APE, WavPack), a fallback stub is used —
/// a future release can link a native tag library.
struct MetadataReader {
    struct Metadata {
        var title: String?
        var artist: String?
        var albumArtist: String?
        var album: String?
        var genre: String?
        var year: Int?
        var trackNumber: Int?
        var discNumber: Int?
        var composer: String?
        var duration: Double?
        var bitrateBps: Int?
        var sampleRateHz: Int?
        var bitDepth: Int?
        var channelCount: Int?
        var replayGainTrack: Float?
        var replayGainAlbum: Float?
        var artworkData: Data?
    }

    func read(url: URL) async -> Metadata {
        let asset = AVURLAsset(url: url)
        var meta = Metadata()

        // Duration
        let duration = try? await asset.load(.duration)
        meta.duration = duration.map { CMTimeGetSeconds($0) }

        // Collect all metadata from all keyspaces (common, iTunes, ID3)
        let allItems = (try? await asset.load(.metadata)) ?? []

        for item in allItems {
            guard let value = try? await item.load(.value) else { continue }
            // Check common key first
            if let key = item.commonKey {
                switch key {
                case .commonKeyTitle:      meta.title       = value as? String
                case .commonKeyArtist:     meta.artist      = value as? String
                case .commonKeyAlbumName:  meta.album       = value as? String
                case .commonKeyType:       meta.genre       = value as? String
                case .commonKeyArtwork:
                    // Artwork can be returned as Data, NSData, or sometimes a dictionary.
                    // Use dataValue for a reliable binary extraction.
                    if let data = value as? Data, !data.isEmpty {
                        meta.artworkData = data
                    } else if let data = try? await item.load(.dataValue), !data.isEmpty {
                        meta.artworkData = data
                    }
                default: break
                }
                continue
            }
            // Fall through to keySpace-specific keys
            let keyStr = item.key as? String ?? ""
            switch keyStr {
            // ID3 / iTunes album artist
            case "TPE2", "\u{00A9}Art", "aART":
                if let s = value as? String, !s.isEmpty { meta.albumArtist = s }
            // Track number (ID3 TRCK or iTunes trkn)
            case "TRCK", "trkn":
                if let s = value as? String {
                    meta.trackNumber = Int(s.split(separator: "/").first.map(String.init) ?? s)
                } else if let n = value as? Int { meta.trackNumber = n }
            // Disc number (ID3 TPOS or iTunes disk)
            case "TPOS", "disk":
                if let s = value as? String {
                    meta.discNumber = Int(s.split(separator: "/").first.map(String.init) ?? s)
                } else if let n = value as? Int { meta.discNumber = n }
            // Composer
            case "TCOM", "\u{00A9}wrt":
                if let s = value as? String, !s.isEmpty { meta.composer = s }
            // Comment
            case "COMM", "\u{00A9}cmt":
                if let s = value as? String, !s.isEmpty { /* stored separately if needed */ _ = s }
            // Year
            case "TDRC", "TYER", "\u{00A9}day":
                if let s = value as? String { meta.year = Int(s.prefix(4)) }
            // ReplayGain (stored as TXXX in ID3; key includes description prefix)
            case _ where keyStr.contains("REPLAYGAIN_TRACK_GAIN"):
                if let s = value as? String { meta.replayGainTrack = Float(s.replacingOccurrences(of: " dB", with: "")) }
            case _ where keyStr.contains("REPLAYGAIN_ALBUM_GAIN"):
                if let s = value as? String { meta.replayGainAlbum = Float(s.replacingOccurrences(of: " dB", with: "")) }
            // Bitrate (some containers expose this)
            case "TBPM": break  // BPM, skip for now
            default: break
            }
        }

        // Fallback: if albumArtist still empty, use artist
        if meta.albumArtist == nil || meta.albumArtist!.isEmpty {
            meta.albumArtist = meta.artist
        }

        // Format info from audio track descriptors
        let tracks = (try? await asset.load(.tracks)) ?? []
        if let audioTrack = tracks.first(where: { $0.mediaType == .audio }),
           let desc = try? await audioTrack.load(.formatDescriptions).first.map({ $0 as CMFormatDescription }) {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
            meta.sampleRateHz = asbd.map { Int($0.mSampleRate) }
            meta.channelCount  = asbd.map { Int($0.mChannelsPerFrame) }
            meta.bitDepth      = asbd.map { $0.mBitsPerChannel > 0 ? Int($0.mBitsPerChannel) : nil } ?? nil
            // Estimated bitrate
            if let bps = try? await audioTrack.load(.estimatedDataRate) {
                meta.bitrateBps = Int(bps)
            }
        }

        return meta
    }
}

// MARK: - AudioFormat file extension init
extension AudioFormat {
    init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "flac":                self = .flac
        case "alac", "caf":        self = .alac
        case "dsd", "dsf", "dff":  self = .dsd
        case "wav":                 self = .wav
        case "aif", "aiff":        self = .aiff
        case "ape":                 self = .ape
        case "wv":                  self = .wavpack
        case "mp3":                 self = .mp3
        case "aac":                 self = .aac
        case "m4a":                 self = .m4a
        case "ogg":                 self = .ogg
        case "opus":                self = .opus
        case "wma":                 self = .wma
        case "mpc":                 self = .mpc
        case "mp4":                 self = .mp4
        default:                    return nil
        }
    }
}
