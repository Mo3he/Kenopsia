import Foundation
import CryptoKit
import Network

// MARK: - SourceResolver
/// Translates a TrackURI into a local URL that AVFoundation can open.
/// For remote tracks, this may involve downloading or generating a temp auth URL.
actor SourceResolver {
    private var adapters: [MusicSourceID: any MusicSourceAdapter] = [:]

    func register(adapter: some MusicSourceAdapter, for sourceID: MusicSourceID) {
        adapters[sourceID] = adapter
    }

    func adapter(for sourceID: MusicSourceID) -> (any MusicSourceAdapter)? {
        adapters[sourceID]
    }

    func localURL(for track: Track) async throws -> URL {
        // Check offline cache first — works for any source type
        if let cachedURL = await OfflineCacheService.shared.localURL(for: track) {
            return cachedURL
        }

        switch track.uri {
        case .localFile(let path):
            return URL(fileURLWithPath: path)

        case .remoteURL(let url):
            return url
        case .dlnaURL(let url):
            return url
        case .webRadio(let streamURL):
            return streamURL

        case .subsonicID(let serverID, let trackID):
            guard let adapter = adapters[MusicSourceID(serverID)] as? SubsonicSourceAdapter else {
                throw SourceError.adapterNotFound
            }
            return try await adapter.streamURL(for: trackID)

        case .cloudFile(let provider, let fileID):
            guard let adapter = adapters.values.first(where: {
                ($0 as? CloudSourceAdapter)?.provider == provider
            }) as? CloudSourceAdapter else {
                throw SourceError.adapterNotFound
            }
            return try await adapter.downloadURL(for: fileID)

        case .appleMusicID:
            // Apple Music tracks are played via ApplicationMusicPlayer in PlaybackService.
            // There is no local URL — throw so PlaybackService knows to take that path.
            throw SourceError.appleMusicTrack
        }
    }
}

enum SourceError: Error {
    case adapterNotFound
    case authenticationFailed
    case networkUnavailable
    case fileNotFound
    /// Sentinel: Apple Music tracks have no local URL; PlaybackService handles them via ApplicationMusicPlayer.
    case appleMusicTrack
}

// MARK: - MusicSourceAdapter protocol
protocol MusicSourceAdapter: Actor {
    var sourceID: MusicSourceID { get }
    /// Enumerate all tracks available from this source.
    func fetchTracks() async throws -> [Track]
}

// MARK: - Concrete adapters (stubs — each filled in with full logic)

// LocalSource is handled directly by LibraryScanner + SourceResolver (local file path).
// Adapters below handle sources that require network or auth.

actor SubsonicSourceAdapter: MusicSourceAdapter {
    let sourceID: MusicSourceID
    private let config: SubsonicSourceConfig
    private var session: URLSession

    init(sourceID: MusicSourceID, config: SubsonicSourceConfig) {
        self.sourceID = sourceID
        self.config = config
        self.session = URLSession.shared
    }

    func fetchTracks() async throws -> [Track] {
        let tracks = try await fetchAlbumList()
        return tracks
    }

    func streamURL(for trackID: String) async throws -> URL {
        let (salt, token) = try makeAuthTokens()
        var comps = URLComponents(string: config.serverURL)!
        comps.path = "/rest/stream.view"
        comps.queryItems = authQueryItems(salt: salt, token: token) + [
            URLQueryItem(name: "id",           value: trackID),
            URLQueryItem(name: "maxBitRate",   value: "0"),    // 0 = original quality
            URLQueryItem(name: "format",       value: "raw")
        ]
        guard let url = comps.url else { throw SourceError.networkUnavailable }
        return url
    }

    // MARK: - Library fetch
    /// Fetches all albums via getAlbumList2, then each album's tracks via getAlbum.
    private func fetchAlbumList() async throws -> [Track] {
        var offset = 0
        let size = 500
        var allTracks: [Track] = []

        while true {
            let (salt, token) = try makeAuthTokens()
            var comps = URLComponents(string: config.serverURL)!
            comps.path = "/rest/getAlbumList2.view"
            comps.queryItems = authQueryItems(salt: salt, token: token) + [
                URLQueryItem(name: "type",   value: "alphabeticalByArtist"),
                URLQueryItem(name: "size",   value: "\(size)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
            guard let url = comps.url else { break }
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(SubsonicResponse<AlbumList2>.self, from: data)
            guard response.isOK else { throw SourceError.authenticationFailed }
            let albums = response.subsonicResponse.albumList2?.album ?? []
            if albums.isEmpty { break }

            for album in albums {
                let tracks = try await fetchAlbumTracks(albumID: album.id)
                allTracks.append(contentsOf: tracks)
            }
            offset += albums.count
            if albums.count < size { break }
        }
        return allTracks
    }

    private func fetchAlbumTracks(albumID: String) async throws -> [Track] {
        let (salt, token) = try makeAuthTokens()
        var comps = URLComponents(string: config.serverURL)!
        comps.path = "/rest/getAlbum.view"
        comps.queryItems = authQueryItems(salt: salt, token: token) + [
            URLQueryItem(name: "id", value: albumID)
        ]
        guard let url = comps.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let response = try JSONDecoder().decode(SubsonicResponse<AlbumDetail>.self, from: data)
        guard response.isOK else { return [] }
        return (response.subsonicResponse.album?.song ?? []).map { song in
            Track(
                title:           song.title,
                artist:          song.artist ?? "",
                albumArtist:     song.albumArtist ?? song.artist ?? "",
                album:           song.album ?? "",
                genre:           song.genre ?? "",
                year:            song.year,
                trackNumber:     song.track,
                discNumber:      song.discNumber,
                source:          sourceID,
                uri:             .subsonicID(serverID: sourceID.rawValue, trackID: song.id),
                format:          AudioFormat(fileExtension: song.suffix ?? "") ?? .mp3,
                durationSeconds: Double(song.duration ?? 0),
                bitrateBps:      song.bitRate.map { $0 * 1000 },
                artworkCacheKey: song.coverArt.map { "subsonic_\(sourceID.rawValue)_\($0)" }
            )
        }
    }

    // MARK: - Token-based auth (Subsonic API 1.13.0+)
    /// Generates a cryptographically random salt and computes MD5(password + salt).
    /// The password is never transmitted in plain text.
    private func makeAuthTokens() throws -> (salt: String, token: String) {
        let password = try KeychainHelper.shared.read(key: config.keychainKey)
        // Random hex salt (16 bytes)
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let salt = bytes.map { String(format: "%02x", $0) }.joined()
        let token = md5(password + salt)
        return (salt, token)
    }

    private func authQueryItems(salt: String, token: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "u", value: config.username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "c", value: "Kenopsia"),
            URLQueryItem(name: "v", value: "1.16.1"),
            URLQueryItem(name: "f", value: "json")
        ]
    }

    /// MD5 via CryptoKit — Subsonic API spec requires it.
    private func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

actor NASSourceAdapter: MusicSourceAdapter {
    let sourceID: MusicSourceID
    private let config: NASSourceConfig
    private let browser = DLNABrowser()

    init(sourceID: MusicSourceID, config: NASSourceConfig) {
        self.sourceID = sourceID
        self.config = config
    }

    func fetchTracks() async throws -> [Track] {
        // Build the device description URL from host + port.
        // Real DLNA servers advertise their description URL via SSDP;
        // here we accept a direct host:port as a fallback for manual NAS config.
        let scheme = "http"
        guard let descURL = URL(string: "\(scheme)://\(config.host):\(config.port)/description.xml") else {
            throw SourceError.networkUnavailable
        }
        return try await browser.browse(serverURL: descURL, sourceID: sourceID)
    }
}

actor CloudSourceAdapter: MusicSourceAdapter {
    let sourceID: MusicSourceID
    let provider: CloudProvider
    private var config: CloudSourceConfig

    init(sourceID: MusicSourceID, config: CloudSourceConfig) {
        self.sourceID = sourceID
        self.provider = config.provider
        self.config = config
    }

    func updateConfig(_ newConfig: CloudSourceConfig) {
        config = newConfig
    }

    func fetchTracks() async throws -> [Track] {
        switch config.provider {
        case .iCloud:      return try await fetchICloudTracks()
        case .backblaze:   return try await fetchBackblazeTracks()
        }
    }

    func downloadURL(for fileID: String) async throws -> URL {
        switch config.provider {
        case .iCloud:
            return URL(fileURLWithPath: fileID)

        case .backblaze:
            // fileID is the full HTTPS download URL stored during fetchBackblazeTracks
            guard let url = URL(string: fileID) else { throw SourceError.fileNotFound }
            return url
        }
    }

    // MARK: - iCloud Drive
    private func fetchICloudTracks() async throws -> [Track] {
        return try await withCheckedThrowingContinuation { continuation in
            let query = NSMetadataQuery()
            query.searchScopes = [
                NSMetadataQueryUbiquitousDocumentsScope,
                NSMetadataQueryAccessibleUbiquitousExternalDocumentsScope
            ]
            let exts = ["mp3", "flac", "m4a", "aac", "wav", "aiff", "ogg", "opus", "wv", "dsf"]
            query.predicate = NSCompoundPredicate(orPredicateWithSubpredicates:
                exts.map { NSPredicate(format: "%K ENDSWITH[c] '.%@'", NSMetadataItemFSNameKey, $0) }
            )

            var observer: Any?
            observer = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
            ) { [weak query] _ in
                guard let q = query else { continuation.resume(returning: []); return }
                q.stop()
                if let obs = observer { NotificationCenter.default.removeObserver(obs) }

                let sid = self.sourceID
                let tracks: [Track] = (0..<q.resultCount).compactMap { i in
                    guard let item = q.result(at: i) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                    let url = URL(fileURLWithPath: path)
                    // Trigger download of the stub if not local yet
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                    return Track(
                        title: url.deletingPathExtension().lastPathComponent,
                        source: sid,
                        uri: .cloudFile(provider: .iCloud, fileID: path),
                        format: AudioFormat(fileExtension: url.pathExtension) ?? .mp3,
                        durationSeconds: 0
                    )
                }
                continuation.resume(returning: tracks)
            }
            DispatchQueue.main.async { query.start() }
        }
    }

    // MARK: - Backblaze B2
    // Uses the B2 Native API: https://www.backblaze.com/b2/docs/
    private func fetchBackblazeTracks() async throws -> [Track] {
        guard !config.accountID.isEmpty,
              let appKey = try? KeychainHelper.shared.read(key: config.keychainKey) else {
            throw SourceError.authenticationFailed
        }

        // 1. Authorize
        let credential = Data("\(config.accountID):\(appKey)".utf8).base64EncodedString()
        var authReq = URLRequest(url: URL(string: "https://api.backblazeb2.com/b2api/v3/b2_authorize_account")!)
        authReq.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        let (authData, _) = try await URLSession.shared.data(for: authReq)

        struct B2Auth: Decodable {
            let apiInfo: APIInfo
            let authorizationToken: String
            struct APIInfo: Decodable {
                let storageApi: StorageAPI
                struct StorageAPI: Decodable { let apiUrl: String; let bucketId: String? }
            }
        }
        let auth = try JSONDecoder().decode(B2Auth.self, from: authData)
        let apiURL = auth.apiInfo.storageApi.apiUrl
        let authToken = auth.authorizationToken

        // 2. List buckets to find audio files
        var listReq = URLRequest(url: URL(string: "\(apiURL)/b2api/v3/b2_list_buckets")!)
        listReq.setValue(authToken, forHTTPHeaderField: "Authorization")
        let (bucketsData, _) = try await URLSession.shared.data(for: listReq)

        struct B2Buckets: Decodable { let buckets: [B2Bucket] }
        struct B2Bucket: Decodable { let bucketId: String; let bucketName: String }
        let buckets = (try? JSONDecoder().decode(B2Buckets.self, from: bucketsData))?.buckets ?? []

        // 3. List files in each bucket
        let audioExts = Set(["mp3", "flac", "m4a", "aac", "wav", "aiff", "ogg", "opus", "wv"])
        var tracks: [Track] = []
        for bucket in buckets {
            var startFileName: String? = nil
            repeat {
                var params: [String: Any] = ["bucketId": bucket.bucketId, "maxFileCount": 1000]
                if let start = startFileName { params["startFileName"] = start }
                var listFilesReq = URLRequest(url: URL(string: "\(apiURL)/b2api/v3/b2_list_file_names")!)
                listFilesReq.setValue(authToken, forHTTPHeaderField: "Authorization")
                listFilesReq.httpMethod = "POST"
                listFilesReq.httpBody = try? JSONSerialization.data(withJSONObject: params)
                listFilesReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (filesData, _) = try await URLSession.shared.data(for: listFilesReq)

                struct B2FileList: Decodable { let files: [B2File]; let nextFileName: String? }
                struct B2File: Decodable { let fileId: String; let fileName: String; let contentLength: Int64 }
                guard let list = try? JSONDecoder().decode(B2FileList.self, from: filesData) else { break }

                for file in list.files {
                    let ext = (file.fileName as NSString).pathExtension.lowercased()
                    guard audioExts.contains(ext) else { continue }
                    let name = (file.fileName as NSString).lastPathComponent
                    let downloadURL = "\(apiURL)/file/\(bucket.bucketName)/\(file.fileName)"
                    tracks.append(Track(
                        title: (name as NSString).deletingPathExtension,
                        source: sourceID,
                        uri: .cloudFile(provider: .backblaze, fileID: downloadURL),
                        format: AudioFormat(fileExtension: ext) ?? .mp3,
                        durationSeconds: 0
                    ))
                }
                startFileName = list.nextFileName
            } while startFileName != nil
        }
        return tracks
    }
}

actor WiFiTransferService: MusicSourceAdapter {
    let sourceID: MusicSourceID
    private let config: WiFiTransferConfig
    private var httpServer: SimpleHTTPServer?

    init(sourceID: MusicSourceID, config: WiFiTransferConfig) {
        self.sourceID = sourceID
        self.config = config
    }

    func start() async {
        httpServer = SimpleHTTPServer(port: UInt16(config.port))
        await httpServer?.start()
    }

    func stop() async {
        await httpServer?.stop()
        httpServer = nil
    }

    func fetchTracks() async throws -> [Track] {
        // Tracks uploaded via Wi-Fi transfer are moved into the local library.
        return []
    }
}

actor SimpleHTTPServer {
    private let port: UInt16
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "net.mohome.kenopsia.http")

    init(port: UInt16) { self.port = port }

    func start() async {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            self.listener = listener
            listener.newConnectionHandler = { conn in
                Task { await self.handleConnection(conn) }
            }
            listener.start(queue: queue)
        } catch {
            // Port conflict or permission error — silently skip
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: queue)

        // Read until we have the complete HTTP headers (terminated by \r\n\r\n).
        // We must not convert the whole receive buffer to String because the body
        // can contain binary audio data that is not valid UTF-8, which causes
        // String(data:encoding:) to return nil and silently drops the connection.
        let headerTerminator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        while !buffer.contains(headerTerminator) {
            guard let chunk = await asyncReceive(connection, min: 1, max: 65536) else {
                connection.cancel(); return
            }
            buffer.append(chunk)
            if buffer.count > 1_048_576 { connection.cancel(); return } // 1 MB header limit
        }

        guard let headerEnd = buffer.range(of: headerTerminator) else {
            connection.cancel(); return
        }
        // Parse only the header bytes as text; leave the body as raw Data
        let headerBytes = buffer[buffer.startIndex..<headerEnd.lowerBound]
        let bodyAlreadyRead = Data(buffer[headerEnd.upperBound...])
        guard let headerStr = String(data: headerBytes, encoding: .utf8) else {
            connection.cancel(); return
        }
        let requestLine = headerStr.components(separatedBy: "\r\n").first ?? ""

        if requestLine.hasPrefix("GET") {
            await sendUploadPage(connection)
        } else if requestLine.hasPrefix("POST /upload") {
            await handleUpload(connection, headers: headerStr, bodyAlreadyRead: bodyAlreadyRead)
        } else {
            connection.cancel()
        }
    }

    // MARK: - Upload handling

    private func handleUpload(_ connection: NWConnection, headers: String, bodyAlreadyRead: Data) async {
        var contentLength = 0
        var boundary = ""
        for line in headers.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
            if lower.contains("boundary="), let r = line.range(of: "boundary=", options: .caseInsensitive) {
                boundary = "--" + String(line[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !boundary.isEmpty, contentLength > 0 else {
            await send400(connection); return
        }

        // Accumulate the body in chunks until we have all contentLength bytes.
        var body = bodyAlreadyRead
        while body.count < contentLength {
            let remaining = contentLength - body.count
            guard let chunk = await asyncReceive(connection, min: 1, max: min(remaining, 2 * 1024 * 1024)) else { break }
            body.append(chunk)
        }

        let savedFilenames = saveMultipartFiles(data: body, boundary: boundary)

        // Build a confirmation page so the user knows the upload worked.
        let count = savedFilenames.count
        let fileList: String
        if savedFilenames.isEmpty {
            fileList = "<p style='color:#ff3b30'>No supported audio files were found in the upload.</p>"
        } else {
            fileList = "<ul>" + savedFilenames.map { "<li>\($0)</li>" }.joined() + "</ul>"
        }
        let confirmHTML = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Kenopsia Upload</title>
        <style>
          body{font-family:-apple-system,sans-serif;max-width:520px;margin:40px auto;padding:0 20px}
          .badge{background:#34c759;color:#fff;padding:4px 14px;border-radius:20px;display:inline-block;margin:8px 0}
          a{color:#007aff;text-decoration:none;font-size:17px}
        </style>
        </head><body>
        <h2>\(count > 0 ? "Upload complete" : "Nothing uploaded")</h2>
        \(count > 0 ? "<div class='badge'>\(count) file\(count == 1 ? "" : "s") added to library</div>" : "")
        \(fileList)
        <p><a href="/">\(count > 0 ? "Upload more" : "Try again")</a></p>
        </body></html>
        """
        let pageData = Data(confirmHTML.utf8)
        let pageHeaders = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(pageData.count)\r\nConnection: close\r\n\r\n"
        var pageResp = Data(pageHeaders.utf8)
        pageResp.append(pageData)
        await asyncSend(connection, data: pageResp)
        connection.cancel()
    }

    private func sendUploadPage(_ connection: NWConnection) async {
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Kenopsia Upload</title>
        <style>body{font-family:-apple-system,sans-serif;max-width:520px;margin:40px auto;padding:0 20px}
        input[type=submit]{background:#007aff;color:#fff;border:none;padding:12px 24px;border-radius:8px;font-size:16px;cursor:pointer}</style>
        </head><body>
        <h2>Upload Audio to Kenopsia</h2>
        <form method="post" action="/upload" enctype="multipart/form-data">
          <input type="file" name="audio" accept="audio/*" multiple><br><br>
          <input type="submit" value="Upload">
        </form></body></html>
        """
        let body = Data(html.utf8)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var resp = Data(headers.utf8)
        resp.append(body)
        await asyncSend(connection, data: resp)
        connection.cancel()
    }

    // MARK: - Multipart parsing

    @discardableResult
    private func saveMultipartFiles(data: Data, boundary: String) -> [String] {
        guard let boundaryData = boundary.data(using: .utf8) else { return [] }
        let parts = data.binarySplit(separator: boundaryData)
        guard parts.count > 2 else { return [] }

        // Store in Documents/WiFiTransfer so the user can see, manage, and delete
        // their files directly in the Files app (UIFileSharingEnabled = YES in Info.plist).
        // The App Group container is sandboxed and not visible to the user.
        let destinationRoot = (FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.net.mohome.kenopsia")!)
            .appendingPathComponent("WiFiTransfer")
        try? FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        var savedFilenames: [String] = []
        for part in parts.dropFirst().dropLast() {
            guard let headerEnd = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
            let headerData = part[part.startIndex..<headerEnd.lowerBound]
            var fileBodyData = part[headerEnd.upperBound...]
            let crlf = Data("\r\n".utf8)
            if fileBodyData.count >= 2 && fileBodyData.suffix(2) == crlf {
                fileBodyData = fileBodyData.dropLast(2)
            }
            guard let headerStr = String(data: headerData, encoding: .utf8),
                  let filenameRange = headerStr.range(of: "filename=\"") else { continue }
            let filename = String(headerStr[filenameRange.upperBound...].prefix(while: { $0 != "\"" }))
            guard !filename.isEmpty,
                  AudioFormat(fileExtension: URL(fileURLWithPath: filename).pathExtension) != nil else { continue }
            let dest = destinationRoot.appendingPathComponent(filename)
            do {
                try Data(fileBodyData).write(to: dest)
                savedFilenames.append(filename)
            } catch {
                // File write failed — skip this part; notification won't include it
            }
        }
        // Post on the main thread so observers in @MainActor classes can use
        // their isolated properties directly.
        if !savedFilenames.isEmpty {
            let folder = destinationRoot
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .wifiTransferDidReceiveFiles, object: folder)
            }
        }
        return savedFilenames
    }

    // MARK: - Async network helpers

    private func asyncReceive(_ connection: NWConnection, min: Int, max: Int) async -> Data? {
        await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: min, maximumLength: max) { data, _, _, error in
                guard error == nil else { cont.resume(returning: nil); return }
                cont.resume(returning: data)
            }
        }
    }

    private func asyncSend(_ connection: NWConnection, data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    private func send400(_ connection: NWConnection) async {
        let resp = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
        await asyncSend(connection, data: Data(resp.utf8))
        connection.cancel()
    }
}

// MARK: - Notification names
extension Notification.Name {
    /// Posted by SimpleHTTPServer after audio files are saved from a Wi-Fi Transfer upload.
    /// `object` is the `URL` of the destination folder containing the new files.
    static let wifiTransferDidReceiveFiles = Notification.Name("wifiTransferDidReceiveFiles")
}

// MARK: - Data binary split helper
private extension Data {
    /// Splits `self` at every occurrence of `separator`, returning all parts including empty ones.
    func binarySplit(separator: Data) -> [Data] {
        var result: [Data] = []
        var searchStart = startIndex
        while let range = self[searchStart...].range(of: separator) {
            result.append(self[searchStart..<range.lowerBound])
            searchStart = range.upperBound
        }
        result.append(self[searchStart...])
        return result
    }
}
