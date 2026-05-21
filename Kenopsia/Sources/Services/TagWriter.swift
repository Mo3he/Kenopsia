import Foundation
import AVFoundation

// MARK: - TagWriter
/// Writes metadata tags back to local audio files.
///
/// AVFoundation supports writing metadata to M4A/MP4/MOV containers via AVAssetExportSession.
/// For MP3 (ID3v2), FLAC (Vorbis), and other formats, we use a pure-Swift implementation
/// covering the most common fields.
///
/// Formats and write support:
///   M4A / ALAC / AAC  — AVFoundation export (full support)
///   MP3               — ID3v2.3 header rewrite (title, artist, album, track, year, genre, artwork)
///   FLAC              — Vorbis comment block rewrite
///   OGG / Opus        — Vorbis comment rewrite
///   WAV / AIFF        — Limited (via AVFoundation for M4A re-wrap is not applicable; read-only)
///   APE / WavPack     — Read-only (requires native library)
actor TagWriter {

    // MARK: - Public API
    func write(tags: TrackTags, to url: URL) async throws {
        let format = AudioFormat(fileExtension: url.pathExtension)
        switch format {
        case .m4a, .alac, .aac, .mp4:
            try await writeM4ATags(tags: tags, to: url)
        case .mp3:
            try writeID3Tags(tags: tags, to: url)
        case .flac:
            try writeVorbisComments(tags: tags, to: url)
        case .ogg, .opus:
            try writeOggTags(tags: tags, to: url)
        default:
            throw TagWriteError.unsupportedFormat
        }
    }

    // MARK: - M4A / ALAC via AVFoundation
    private func writeM4ATags(tags: TrackTags, to url: URL) async throws {
        let asset = AVURLAsset(url: url)
        guard let exportSession = AVAssetExportSession(asset: asset,
                                                       presetName: AVAssetExportPresetPassthrough) else {
            throw TagWriteError.exportFailed
        }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)

        exportSession.outputURL = tempURL
        exportSession.outputFileType = .m4a

        var metadataItems: [AVMutableMetadataItem] = []
        func makeItem(keyString: String, keySpace: AVMetadataKeySpace, value: any NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
            let item = AVMutableMetadataItem()
            item.key = keyString as NSString
            item.keySpace = keySpace
            item.value = value
            return item
        }

        // iTunes atom key strings
        let ks = AVMetadataKeySpace.iTunes
        if let v = tags.title       { metadataItems.append(makeItem(keyString: "©nam", keySpace: ks, value: v as NSString)) }
        if let v = tags.artist      { metadataItems.append(makeItem(keyString: "©ART", keySpace: ks, value: v as NSString)) }
        if let v = tags.album       { metadataItems.append(makeItem(keyString: "©alb", keySpace: ks, value: v as NSString)) }
        if let v = tags.albumArtist { metadataItems.append(makeItem(keyString: "aART", keySpace: ks, value: v as NSString)) }
        if let v = tags.genre       { metadataItems.append(makeItem(keyString: "©gen", keySpace: ks, value: v as NSString)) }
        if let v = tags.composer    { metadataItems.append(makeItem(keyString: "©wrt", keySpace: ks, value: v as NSString)) }
        if let v = tags.year        { metadataItems.append(makeItem(keyString: "©day", keySpace: ks, value: "\(v)" as NSString)) }

        // Preserve existing metadata items we are NOT overriding (artwork, track#, etc.)
        let overriddenKeys: Set<String> = ["©nam", "©ART", "©alb", "aART", "©gen", "©wrt", "©day"]
        let existingMetadata = try await asset.load(.metadata)
        for item in existingMetadata {
            guard let key = item.key as? String else {
                // Non-string keys (numeric iTunes keys like covr) -- preserve them
                metadataItems.append(item.mutableCopy() as! AVMutableMetadataItem)
                continue
            }
            if !overriddenKeys.contains(key) {
                metadataItems.append(item.mutableCopy() as! AVMutableMetadataItem)
            }
        }

        exportSession.metadata = metadataItems
        await exportSession.export()

        if exportSession.status != .completed {
            throw TagWriteError.exportFailed
        }

        // Replace original file with the tagged version
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    // MARK: - ID3v2.3 (MP3)
    /// Rewrites the ID3v2 header in-place. Reads existing header to preserve unknown frames,
    /// then writes updated frames back with the same or larger header size.
    private func writeID3Tags(tags: TrackTags, to url: URL) throws {
        var fileData = try Data(contentsOf: url)

        // Parse existing frames so we can preserve those we don't overwrite
        let preservedFrames = preservedID3Frames(from: fileData, overriddenBy: tags)
        let newFrames = preservedFrames + buildID3Frames(tags: tags)

        // Total content = frames. In the padded in-place case we add extra zero bytes,
        // but the size field always reflects the full content region (frames + padding).
        let newHeader = buildID3v24Header(frames: newFrames)

        if let existingSize = existingID3Size(in: fileData), existingSize >= newHeader.count {
            // Overwrite in-place. The padded size = existingSize - 10 (header bytes).
            let paddedContentSize = existingSize - 10
            // Rebuild header with the correct (padded) content size so the syncsafe
            // size field reflects frames + padding, not just frames.
            var padded = buildID3v24Header(frames: newFrames, totalContentSize: paddedContentSize)
            padded.append(contentsOf: [UInt8](repeating: 0, count: paddedContentSize - newFrames.count))
            fileData.replaceSubrange(0..<existingSize, with: padded)
        } else {
            let audioStart = existingID3Size(in: fileData) ?? 0
            let audioData = fileData[audioStart...]
            fileData = newHeader + audioData
        }
        try fileData.write(to: url, options: .atomic)
    }

    /// Extracts existing ID3 frames that are NOT being overwritten, re-encoding their
    /// sizes as syncsafe (v2.4) regardless of the original tag version.
    private func preservedID3Frames(from data: Data, overriddenBy tags: TrackTags) -> Data {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return Data() }
        let majorVersion = data[3]  // 3 = ID3v2.3, 4 = ID3v2.4
        guard let tagSize = existingID3Size(in: data), tagSize > 10 else { return Data() }

        // Frame IDs we always write fresh
        var overriddenIDs: Set<String> = ["TIT2", "TPE1", "TPE2", "TALB", "TCON", "TCOM", "TDRC", "TYER", "TRCK", "TPOS", "COMM"]
        if tags.artworkData != nil { overriddenIDs.insert("APIC") }

        var preserved = Data()
        var offset = 10
        while offset + 10 <= tagSize {
            let idBytes = data[offset..<offset+4]
            guard let frameID = String(data: idBytes, encoding: .ascii),
                  frameID.first?.isLetter == true else { break }

            let frameContentSize: Int
            if majorVersion >= 4 {
                frameContentSize = (Int(data[offset+4]) << 21) | (Int(data[offset+5]) << 14)
                                 | (Int(data[offset+6]) << 7)  | Int(data[offset+7])
            } else {
                frameContentSize = (Int(data[offset+4]) << 24) | (Int(data[offset+5]) << 16)
                                 | (Int(data[offset+6]) << 8)  | Int(data[offset+7])
            }
            let frameEnd = offset + 10 + frameContentSize
            guard frameEnd <= tagSize, frameContentSize > 0 else { break }

            if !overriddenIDs.contains(frameID) {
                // Re-encode frame with v2.4 syncsafe size
                let content = data[offset+10..<frameEnd]
                var frame = Data()
                frame.append(contentsOf: Array(frameID.utf8))
                frame.append(UInt8((frameContentSize >> 21) & 0x7F))
                frame.append(UInt8((frameContentSize >> 14) & 0x7F))
                frame.append(UInt8((frameContentSize >> 7)  & 0x7F))
                frame.append(UInt8(frameContentSize & 0x7F))
                frame.append(contentsOf: [0x00, 0x00])  // flags (clear)
                frame.append(content)
                preserved.append(frame)
            }
            offset = frameEnd
        }
        return preserved
    }

    private func existingID3Size(in data: Data) -> Int? {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil }
        // ID3v2 syncsafe size is stored in bytes 6-9
        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14) | (Int(data[8]) << 7) | Int(data[9])
        return 10 + size
    }

    /// Builds an ID3v2.4 tag from frames (10-byte header + frames).
    /// Pass `totalContentSize` when the header must encode a padded region larger than the frames.
    private func buildID3v24Header(frames: Data, totalContentSize: Int? = nil) -> Data {
        let contentSize = totalContentSize ?? frames.count
        var header = Data()
        // ID3v2.4 identifier + version (2.4.0) + no flags
        header.append(contentsOf: [0x49, 0x44, 0x33, 0x04, 0x00, 0x00])
        // Syncsafe-encoded total content size (excludes the 10 header bytes)
        header.append(UInt8((contentSize >> 21) & 0x7F))
        header.append(UInt8((contentSize >> 14) & 0x7F))
        header.append(UInt8((contentSize >> 7)  & 0x7F))
        header.append(UInt8(contentSize & 0x7F))
        return header + frames
    }

    private func buildID3Frames(tags: TrackTags) -> Data {
        var frames = Data()

        func textFrame(id: String, value: String?) {
            guard let value, !value.isEmpty else { return }
            // ID3v2.4 frame: ID(4) + syncsafe size(4) + flags(2) + encoding(1) + UTF-8 text
            var frame = Data()
            frame.append(contentsOf: Array(id.utf8))
            let textBytes = Array(value.utf8)
            let frameContentSize = 1 + textBytes.count   // encoding byte + text
            // ID3v2.4 frame size is also syncsafe
            frame.append(UInt8((frameContentSize >> 21) & 0x7F))
            frame.append(UInt8((frameContentSize >> 14) & 0x7F))
            frame.append(UInt8((frameContentSize >> 7)  & 0x7F))
            frame.append(UInt8(frameContentSize & 0x7F))
            frame.append(contentsOf: [0x00, 0x00])  // flags
            frame.append(0x03)                        // encoding: UTF-8 (valid in ID3v2.4)
            frame.append(contentsOf: textBytes)
            frames.append(frame)
        }

        textFrame(id: "TIT2", value: tags.title)
        textFrame(id: "TPE1", value: tags.artist)
        textFrame(id: "TPE2", value: tags.albumArtist)
        textFrame(id: "TALB", value: tags.album)
        textFrame(id: "TCON", value: tags.genre)
        textFrame(id: "TCOM", value: tags.composer)
        // TDRC is the correct year/date frame for ID3v2.4 (TYER was v2.3)
        textFrame(id: "TDRC", value: tags.year.map { "\($0)" })
        textFrame(id: "TRCK", value: tags.trackNumber.map { "\($0)" })
        textFrame(id: "TPOS", value: tags.discNumber.map { "\($0)" })
        textFrame(id: "COMM", value: tags.comment)

        // Artwork (APIC frame)
        if let artData = tags.artworkData {
            var apic = Data()
            apic.append(contentsOf: Array("APIC".utf8))
            let content: [UInt8] = [0x03]                       // encoding: UTF-8
                + Array("image/jpeg".utf8) + [0x00]             // MIME + null terminator
                + [0x03]                                         // picture type: cover (front)
                + [0x00]                                         // description: empty string + null
                + Array(artData)
            let size = content.count
            // Syncsafe frame size
            apic.append(UInt8((size >> 21) & 0x7F))
            apic.append(UInt8((size >> 14) & 0x7F))
            apic.append(UInt8((size >> 7)  & 0x7F))
            apic.append(UInt8(size & 0x7F))
            apic.append(contentsOf: [0x00, 0x00])  // flags
            apic.append(contentsOf: content)
            frames.append(apic)
        }

        return frames
    }

    private func buildID3Header(tags: TrackTags) -> Data {
        buildID3v24Header(frames: buildID3Frames(tags: tags))
    }

    // MARK: - Vorbis Comments (FLAC only)
    /// Replaces the COMMENT block in a FLAC file.
    private func writeVorbisComments(tags: TrackTags, to url: URL) throws {
        // FLAC structure: fLaC marker (4 bytes) then metadata blocks.
        // Each block: type(1) + last-block-flag(1 bit) + size(3 bytes) + data.
        // Block type 4 = VORBIS_COMMENT.
        var data = try Data(contentsOf: url)
        guard data.prefix(4) == Data("fLaC".utf8) else { throw TagWriteError.unsupportedFormat }

        // Extract existing Vorbis comments to preserve non-standard entries
        let existing = extractExistingVorbisComments(from: data)
        let comments = buildVorbisCommentBlock(tags: tags, preserving: existing)
        data = replaceVorbisBlock(in: data, newBlock: comments)
        try data.write(to: url, options: .atomic)
    }

    /// Extracts Vorbis comment entries from a FLAC file's VORBIS_COMMENT block.
    private func extractExistingVorbisComments(from flacData: Data) -> [String] {
        var offset = 4  // skip "fLaC" marker
        while offset + 4 <= flacData.count {
            let header = flacData[offset]
            let isLast = (header & 0x80) != 0
            let type   = header & 0x7F
            let size   = (Int(flacData[offset + 1]) << 16)
                       | (Int(flacData[offset + 2]) << 8)
                       |  Int(flacData[offset + 3])
            let blockStart = offset + 4
            let blockEnd = blockStart + size
            guard blockEnd <= flacData.count else { break }
            if type == 4 {
                return parseVorbisCommentEntries(from: flacData[blockStart..<blockEnd])
            }
            offset = blockEnd
            if isLast { break }
        }
        return []
    }

    /// Parses Vorbis comment entries from raw comment block data (vendor + entries).
    private func parseVorbisCommentEntries(from block: Data) -> [String] {
        var pos = block.startIndex
        guard pos + 4 <= block.endIndex else { return [] }
        let vendorLen = Int(block[pos]) | (Int(block[pos+1]) << 8)
                      | (Int(block[pos+2]) << 16) | (Int(block[pos+3]) << 24)
        pos += 4 + vendorLen
        guard pos + 4 <= block.endIndex else { return [] }
        let count = Int(block[pos]) | (Int(block[pos+1]) << 8)
                  | (Int(block[pos+2]) << 16) | (Int(block[pos+3]) << 24)
        pos += 4
        var entries: [String] = []
        for _ in 0..<count {
            guard pos + 4 <= block.endIndex else { break }
            let len = Int(block[pos]) | (Int(block[pos+1]) << 8)
                    | (Int(block[pos+2]) << 16) | (Int(block[pos+3]) << 24)
            pos += 4
            guard pos + len <= block.endIndex else { break }
            if let s = String(data: block[pos..<pos+len], encoding: .utf8) {
                entries.append(s)
            }
            pos += len
        }
        return entries
    }

    private func buildVorbisCommentBlock(tags: TrackTags, preserving existingComments: [String] = []) -> Data {
        // Keys we always write fresh
        let overriddenKeys: Set<String> = [
            "TITLE", "ARTIST", "ALBUMARTIST", "ALBUM", "GENRE",
            "COMPOSER", "DATE", "TRACKNUMBER", "DISCNUMBER", "COMMENT"
        ]

        var entries: [String] = []

        // Preserve existing comments that we are NOT overwriting (e.g. REPLAYGAIN_*, LYRICS)
        for entry in existingComments {
            let key = entry.split(separator: "=", maxSplits: 1).first.map { String($0).uppercased() } ?? ""
            if !overriddenKeys.contains(key) {
                entries.append(entry)
            }
        }

        func add(_ key: String, _ value: String?) {
            if let v = value, !v.isEmpty { entries.append("\(key)=\(v)") }
        }
        add("TITLE",       tags.title)
        add("ARTIST",      tags.artist)
        add("ALBUMARTIST", tags.albumArtist)
        add("ALBUM",       tags.album)
        add("GENRE",       tags.genre)
        add("COMPOSER",    tags.composer)
        add("DATE",        tags.year.map { "\($0)" })
        add("TRACKNUMBER", tags.trackNumber.map { "\($0)" })
        add("DISCNUMBER",  tags.discNumber.map { "\($0)" })
        add("COMMENT",     tags.comment)

        // Vendor string
        let vendor = "Kenopsia"
        var block = Data()
        block.append(le32: UInt32(vendor.utf8.count))
        block.append(contentsOf: vendor.utf8)
        block.append(le32: UInt32(entries.count))
        for entry in entries {
            let bytes = Array(entry.utf8)
            block.append(le32: UInt32(bytes.count))
            block.append(contentsOf: bytes)
        }
        return block
    }

    // MARK: - OGG / Opus Vorbis comment writer
    /// Finds the comment packet page in an Ogg bitstream, replaces it, and rewrites the file
    /// with correct OGG page CRCs. Supports Ogg Vorbis and Ogg Opus.
    private func writeOggTags(tags: TrackTags, to url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.prefix(4) == Data("OggS".utf8) else { throw TagWriteError.unsupportedFormat }

        // Collect page byte-ranges
        struct OggPage {
            let byteRange: Range<Int>
            let type: UInt8
            let granule: Int64
            let serial: UInt32
            let seqNo: UInt32
            let body: Data
        }
        var pages: [OggPage] = []
        var offset = 0
        while offset + 27 <= data.count, data[offset..<offset+4] == Data("OggS".utf8) {
            let type = data[offset + 5]
            let granule = data[offset+6..<offset+14].withUnsafeBytes { $0.load(as: Int64.self).littleEndian }
            let serial  = data[offset+14..<offset+18].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let seqNo   = data[offset+18..<offset+22].withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let segCount = Int(data[offset + 26])
            guard offset + 27 + segCount <= data.count else { break }
            let segTable = data[offset+27..<offset+27+segCount]
            let bodySize = segTable.reduce(0) { $0 + Int($1) }
            let bodyStart = offset + 27 + segCount
            let bodyEnd   = bodyStart + bodySize
            guard bodyEnd <= data.count else { break }
            pages.append(OggPage(
                byteRange: offset..<bodyEnd,
                type: type, granule: granule, serial: serial, seqNo: seqNo,
                body: data[bodyStart..<bodyEnd]
            ))
            offset = bodyEnd
        }

        // Detect comment page: second logical packet, identified by its magic prefix
        let vorbisMagic = Data([0x03, 0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]) // 0x03 + "vorbis"
        let opusMagic   = Data("OpusTags".utf8)
        var commentIdx: Int?
        var commentPrefix = Data()
        for (i, page) in pages.enumerated() {
            if page.body.prefix(7) == vorbisMagic  { commentIdx = i; commentPrefix = vorbisMagic; break }
            if page.body.prefix(8) == opusMagic    { commentIdx = i; commentPrefix = opusMagic;   break }
        }
        guard let idx = commentIdx else { throw TagWriteError.unsupportedFormat }
        let oldPage = pages[idx]

        // Extract existing comments from the old page body (after the magic prefix)
        let commentData = oldPage.body[oldPage.body.startIndex.advanced(by: commentPrefix.count)...]
        let existingComments = parseVorbisCommentEntries(from: commentData)

        // Build new comment packet body: magic prefix + Vorbis comment encoding
        var newBody = commentPrefix
        newBody.append(buildVorbisCommentBlock(tags: tags, preserving: existingComments))
        // Vorbis requires a framing bit (0x01) appended after the comment block
        if commentPrefix == vorbisMagic { newBody.append(0x01) }

        // Build new OGG page bytes
        var segments: [UInt8] = []
        var rem = newBody.count
        while rem > 255 { segments.append(255); rem -= 255 }
        segments.append(UInt8(rem))

        var newPageBytes = Data()
        newPageBytes.append(contentsOf: "OggS".utf8)
        newPageBytes.append(0x00)           // stream structure version
        newPageBytes.append(oldPage.type)
        // granule_position (int64 LE)
        withUnsafeBytes(of: oldPage.granule.littleEndian) { newPageBytes.append(contentsOf: $0) }
        // serial_number (uint32 LE)
        withUnsafeBytes(of: oldPage.serial.littleEndian)  { newPageBytes.append(contentsOf: $0) }
        // page_sequence_number (uint32 LE)
        withUnsafeBytes(of: oldPage.seqNo.littleEndian)   { newPageBytes.append(contentsOf: $0) }
        newPageBytes.append(contentsOf: [0, 0, 0, 0])     // CRC placeholder
        newPageBytes.append(UInt8(segments.count))
        newPageBytes.append(contentsOf: segments)
        newPageBytes.append(newBody)
        // Compute and inject CRC
        let crc = oggCRC(of: newPageBytes)
        newPageBytes[22] = UInt8( crc         & 0xFF)
        newPageBytes[23] = UInt8((crc >>  8)  & 0xFF)
        newPageBytes[24] = UInt8((crc >> 16)  & 0xFF)
        newPageBytes[25] = UInt8((crc >> 24)  & 0xFF)

        // Stitch the file together
        var result = Data()
        result.append(data[0..<oldPage.byteRange.lowerBound])
        result.append(newPageBytes)
        result.append(data[oldPage.byteRange.upperBound...])
        try result.write(to: url, options: .atomic)
    }

    /// OGG CRC-32 using the generator polynomial 0x04c11db7.
    private func oggCRC(of data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04c11db7 : crc << 1
            }
        }
        return crc
    }

    private func replaceVorbisBlock(in flacData: Data, newBlock: Data) -> Data {
        var result = flacData.prefix(4)  // "fLaC" marker
        var offset = 4
        var injected = false

        while offset + 4 <= flacData.count {
            let header = flacData[offset]
            let isLast  = (header & 0x80) != 0
            let type    = header & 0x7F
            let size    = (Int(flacData[offset + 1]) << 16)
                        | (Int(flacData[offset + 2]) << 8)
                        |  Int(flacData[offset + 3])
            let blockEnd = offset + 4 + size

            if type == 4 {
                // Replace VORBIS_COMMENT block with our new one
                var newHeader = Data()
                newHeader.append(isLast ? (0x04 | 0x80) : 0x04)
                let s = newBlock.count
                newHeader.append(UInt8((s >> 16) & 0xFF))
                newHeader.append(UInt8((s >> 8)  & 0xFF))
                newHeader.append(UInt8(s & 0xFF))
                result.append(newHeader)
                result.append(newBlock)
                injected = true
            } else {
                result.append(flacData[offset..<blockEnd])
            }

            offset = blockEnd
            if isLast { break }
        }

        if !injected {
            // No existing comment block — insert before audio data
            var newHeader = Data()
            newHeader.append(0x04)  // VORBIS_COMMENT, not last
            let s = newBlock.count
            newHeader.append(UInt8((s >> 16) & 0xFF))
            newHeader.append(UInt8((s >> 8)  & 0xFF))
            newHeader.append(UInt8(s & 0xFF))
            result.insert(contentsOf: newHeader + newBlock, at: 4)
        }

        // Append remaining audio data
        result.append(flacData[offset...])
        return result
    }
}

// MARK: - TrackTags
/// The editable subset of track metadata.
struct TrackTags {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var discNumber: Int?
    var composer: String?
    var comment: String?
    var artworkData: Data?

    init(track: Track) {
        title       = track.title
        artist      = track.artist
        albumArtist = track.albumArtist
        album       = track.album
        genre       = track.genre
        year        = track.year
        trackNumber = track.trackNumber
        discNumber  = track.discNumber
        composer    = track.composer
        comment     = track.comment
    }
}

// MARK: - Errors
enum TagWriteError: Error {
    case unsupportedFormat
    case exportFailed
    case fileAccessDenied
}

// MARK: - Little-endian Data helper
private extension Data {
    mutating func append(le32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
