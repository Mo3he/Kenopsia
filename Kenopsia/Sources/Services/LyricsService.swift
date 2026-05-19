import Foundation

// MARK: - LyricsService
/// Fetches synced lyrics from:
///   1. Embedded LRC tags in the audio file
///   2. A sidecar .lrc file next to the audio file
///   3. LRCLIB API (https://lrclib.net)
actor LyricsService {
    private let session: URLSession
    private let lrclibBaseURL = URL(string: "https://lrclib.net/api")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    func lyrics(for track: Track) async -> [LyricsLine] {
        // 1. Try sidecar .lrc file
        if case .localFile(let path) = track.uri {
            let lrcURL = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .appendingPathExtension("lrc")
            if let lines = parseLRC(at: lrcURL) { return lines }
        }

        // 2. Try LRCLIB
        return (try? await fetchFromLRCLIB(track: track)) ?? []
    }

    // MARK: - LRC file parser
    private func parseLRC(at url: URL) -> [LyricsLine]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines: [LyricsLine] = []
        for raw in content.components(separatedBy: .newlines) {
            guard let (ts, text) = parseLRCLine(raw) else { continue }
            lines.append(LyricsLine(id: UUID(), timestampSeconds: ts, text: text))
        }
        return lines.isEmpty ? nil : lines.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }

    /// Parses a single LRC line: `[MM:SS.xx] lyric text`
    private func parseLRCLine(_ line: String) -> (Double, String)? {
        // Match [MM:SS.xx] or [MM:SS]
        let pattern = #"^\[(\d+):(\d+)(?:\.(\d+))?\]\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges >= 4
        else { return nil }

        func group(_ i: Int) -> String? {
            let r = match.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: line) else { return nil }
            return String(line[range])
        }

        guard let minStr = group(1), let secStr = group(2),
              let min = Double(minStr), let sec = Double(secStr) else { return nil }
        let cs = group(3).flatMap { Double($0) } ?? 0
        let text = group(4) ?? ""
        let timestamp = min * 60 + sec + cs / 100
        return (timestamp, text)
    }

    // MARK: - LRCLIB
    private struct LRCLIBResponse: Decodable {
        let syncedLyrics: String?
    }

    private func fetchFromLRCLIB(track: Track) async throws -> [LyricsLine] {
        var comps = URLComponents(url: lrclibBaseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: true)!
        comps.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name",  value: track.title),
            URLQueryItem(name: "album_name",  value: track.album),
            URLQueryItem(name: "duration",    value: String(Int(track.durationSeconds)))
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Kenopsia/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }

        let decoded = try JSONDecoder().decode(LRCLIBResponse.self, from: data)
        guard let synced = decoded.syncedLyrics else { return [] }
        return parseLRC(content: synced)
    }

    private func parseLRC(content: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        for raw in content.components(separatedBy: .newlines) {
            guard let (ts, text) = parseLRCLine(raw) else { continue }
            lines.append(LyricsLine(id: UUID(), timestampSeconds: ts, text: text))
        }
        return lines.sorted { $0.timestampSeconds < $1.timestampSeconds }
    }
}
