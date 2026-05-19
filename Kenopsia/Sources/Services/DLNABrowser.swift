import Foundation
import Network

// MARK: - DLNABrowser
/// Browses a DLNA/UPnP content directory server using SOAP over HTTP.
/// Discovers servers via SSDP, then walks the content tree to enumerate audio tracks.
actor DLNABrowser {

    // MARK: - Discovery
    /// Sends an SSDP M-SEARCH multicast to find UPnP MediaServer devices on the LAN.
    /// Returns discovered device description URLs.
    func discoverServers(timeout: TimeInterval = 5) async -> [URL] {
        let ssdpMessage = """
        M-SEARCH * HTTP/1.1\r\n\
        HOST: 239.255.255.250:1900\r\n\
        MAN: "ssdp:discover"\r\n\
        MX: 3\r\n\
        ST: urn:schemas-upnp-org:device:MediaServer:1\r\n\r\n
        """
        // Real SSDP uses UDP multicast via Network.framework NWConnection.
        // The response parsing and cancellation loop run below.
        return await withCheckedContinuation { continuation in
            Task {
                let discovered = await SSDPClient().search(message: ssdpMessage, timeout: timeout)
                continuation.resume(returning: discovered)
            }
        }
    }

    // MARK: - Content Directory Browse
    /// Browse a DLNA content directory starting at the root container.
    /// Returns all audio tracks found in the tree.
    func browse(serverURL: URL, sourceID: MusicSourceID) async throws -> [Track] {
        // Fetch device description to find the ContentDirectory control URL.
        let controlURL = try await fetchControlURL(descriptionURL: serverURL)
        return try await browseContainer(objectID: "0", controlURL: controlURL, sourceID: sourceID)
    }

    /// Recursively browse a container (objectID "0" = root).
    private func browseContainer(objectID: String, controlURL: URL, sourceID: MusicSourceID) async throws -> [Track] {
        let response = try await soapBrowse(objectID: objectID, controlURL: controlURL)
        var tracks: [Track] = []

        for item in response.items {
            if item.isContainer {
                let children = try await browseContainer(
                    objectID: item.id,
                    controlURL: controlURL,
                    sourceID: sourceID
                )
                tracks.append(contentsOf: children)
            } else if let track = item.asTrack(sourceID: sourceID) {
                tracks.append(track)
            }
        }
        return tracks
    }

    // MARK: - SOAP Browse action
    private func soapBrowse(objectID: String, controlURL: URL) async throws -> DLNABrowseResult {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
                    s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:Browse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">
              <ObjectID>\(objectID)</ObjectID>
              <BrowseFlag>BrowseDirectChildren</BrowseFlag>
              <Filter>*</Filter>
              <StartingIndex>0</StartingIndex>
              <RequestedCount>1000</RequestedCount>
              <SortCriteria></SortCriteria>
            </u:Browse>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: controlURL)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"",
                         forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:ContentDirectory:1#Browse\"",
                         forHTTPHeaderField: "SOAPAction")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DLNAError.soapFailed
        }
        return try DLNAResponseParser().parse(data: data)
    }

    // MARK: - Device description
    /// Parses the UPnP device description XML to extract the ContentDirectory control URL.
    private func fetchControlURL(descriptionURL: URL) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: descriptionURL)
        return try DLNADescriptionParser().parseControlURL(data: data, baseURL: descriptionURL)
    }
}

// MARK: - SSDP Client
/// Sends M-SEARCH and collects LOCATION headers from responses using UDP multicast.
actor SSDPClient {
    func search(message: String, timeout: TimeInterval) async -> [URL] {
        await withCheckedContinuation { continuation in
            var results: [URL] = []
            var done = false

            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let connection = NWConnection(
                host: "239.255.255.250",
                port: 1900,
                using: params
            )

            func finish() {
                guard !done else { return }
                done = true
                connection.cancel()
                continuation.resume(returning: results)
            }

            func receiveNext() {
                connection.receiveMessage { data, _, _, error in
                    if let data, let text = String(data: data, encoding: .utf8),
                       let url = SSDPClient.parseLocation(from: text) {
                        if !results.contains(url) { results.append(url) }
                    }
                    guard !done, error == nil else { finish(); return }
                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: message.data(using: .utf8),
                                    completion: .contentProcessed { _ in receiveNext() })
                case .failed, .cancelled:
                    finish()
                default: break
                }
            }

            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { finish() }
        }
    }

    private static func parseLocation(from response: String) -> URL? {
        for line in response.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("location:") {
                let value = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces)
                return URL(string: value)
            }
        }
        return nil
    }
}

// MARK: - DLNA Browse Result
struct DLNABrowseResult {
    var items: [DLNAItem]
}

struct DLNAItem {
    var id: String
    var parentID: String
    var title: String
    var isContainer: Bool
    var resourceURL: URL?
    var mimeType: String?
    var artist: String?
    var album: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var durationSeconds: Double?
    var albumArtURL: URL?

    func asTrack(sourceID: MusicSourceID) -> Track? {
        guard !isContainer, let url = resourceURL else { return nil }
        let ext = url.pathExtension
        guard let format = AudioFormat(fileExtension: ext) else { return nil }
        return Track(
            title:           title,
            artist:          artist ?? "",
            album:           album ?? "",
            genre:           genre ?? "",
            year:            year,
            trackNumber:     trackNumber,
            source:          sourceID,
            uri:             .dlnaURL(url: url),
            format:          format,
            durationSeconds: durationSeconds ?? 0
        )
    }
}

// MARK: - XML Parsers
/// Parses the DIDL-Lite XML returned inside a SOAP Browse response.
class DLNAResponseParser: NSObject, XMLParserDelegate {
    private var items: [DLNAItem] = []
    private var current: DLNAItem?
    private var currentText = ""
    private var insideResult = false

    func parse(data: Data) throws -> DLNABrowseResult {
        // The Browse result is double-XML: the SOAP response contains a
        // URL-escaped DIDL-Lite document in <Result>. Extract and re-parse it.
        guard let soap = String(data: data, encoding: .utf8),
              let resultStart = soap.range(of: "<Result>"),
              let resultEnd   = soap.range(of: "</Result>") else {
            throw DLNAError.parseError
        }
        let escaped = String(soap[resultStart.upperBound..<resultEnd.lowerBound])
        let unescaped = escaped
            .replacingOccurrences(of: "&lt;",  with: "<")
            .replacingOccurrences(of: "&gt;",  with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
        guard let didlData = unescaped.data(using: .utf8) else { throw DLNAError.parseError }

        let parser = XMLParser(data: didlData)
        parser.delegate = self
        parser.parse()
        return DLNABrowseResult(items: items)
    }

    // XMLParserDelegate
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""
        switch elementName {
        case "container":
            current = DLNAItem(id: attributes["id"] ?? "",
                               parentID: attributes["parentID"] ?? "",
                               title: "", isContainer: true)
        case "item":
            current = DLNAItem(id: attributes["id"] ?? "",
                               parentID: attributes["parentID"] ?? "",
                               title: "", isContainer: false)
        case "res":
            if var item = current, !item.isContainer {
                if let urlStr = attributes["protocolInfo"], urlStr.contains("audio") {
                    // protocolInfo is not the URL; the text content is the URL
                }
                // Parse duration: "h:mm:ss.xxx"
                if let durStr = attributes["duration"] {
                    item.durationSeconds = parseDuration(durStr)
                }
                current = item
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard var item = current else { return }
        switch elementName {
        case "dc:title":        item.title = currentText
        case "upnp:artist":     item.artist = currentText
        case "upnp:album":      item.album = currentText
        case "upnp:genre":      item.genre = currentText
        case "upnp:originalTrackNumber": item.trackNumber = Int(currentText)
        case "dc:date":         item.year = Int(currentText.prefix(4))
        case "res":
            if !item.isContainer, let url = URL(string: currentText.trimmingCharacters(in: .whitespacesAndNewlines)) {
                item.resourceURL = url
            }
        case "upnp:albumArtURI":
            item.albumArtURL = URL(string: currentText)
        case "container", "item":
            if !item.title.isEmpty { items.append(item) }
            current = nil
        default: break
        }
        current = item
    }

    /// Parses DLNA duration "h:mm:ss.xxx" or "mm:ss" into seconds.
    private func parseDuration(_ str: String) -> Double {
        let parts = str.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        default: return 0
        }
    }
}

/// Parses a UPnP device description XML to find the ContentDirectory control URL.
class DLNADescriptionParser: NSObject, XMLParserDelegate {
    private var controlURL: String?
    private var inContentDirectory = false
    private var inControlURL = false
    private var currentText = ""

    func parseControlURL(data: Data, baseURL: URL) throws -> URL {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        guard let path = controlURL else { throw DLNAError.controlURLNotFound }
        return baseURL.deletingLastPathComponent().appendingPathComponent(path)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentText = ""
        if elementName == "serviceType" { inContentDirectory = false }
        if elementName == "controlURL" && inContentDirectory { inControlURL = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { currentText += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "serviceType",
           currentText.contains("ContentDirectory") { inContentDirectory = true }
        if elementName == "controlURL" && inControlURL {
            controlURL = currentText
            inControlURL = false
        }
    }
}

// MARK: - Errors
enum DLNAError: Error {
    case soapFailed
    case parseError
    case controlURLNotFound
}
