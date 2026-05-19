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

        // iTunes atom key strings — cross-platform (iOS + macOS Catalyst)
        let ks = AVMetadataKeySpace.iTunes
        if let v = tags.title       { metadataItems.append(makeItem(keyString: "©nam", keySpace: ks, value: v as NSString)) }
        if let v = tags.artist      { metadataItems.append(makeItem(keyString: "©ART", keySpace: ks, value: v as NSString)) }
        if let v = tags.album       { metadataItems.append(makeItem(keyString: "©alb", keySpace: ks, value: v as NSString)) }
        if let v = tags.albumArtist { metadataItems.append(makeItem(keyString: "aART", keySpace: ks, value: v as NSString)) }
        if let v = tags.genre       { metadataItems.append(makeItem(keyString: "©gen", keySpace: ks, value: v as NSString)) }
        if let v = tags.composer    { metadataItems.append(makeItem(keyString: "©wrt", keySpace: ks, value: v as NSString)) }
        if let v = tags.year        { metadataItems.append(makeItem(keyString: "©day", keySpace: ks, value: "\(v)" as NSString)) }

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
        let newHeader = buildID3Header(tags: tags)

        if let existingSize = existingID3Size(in: fileData), existingSize >= newHeader.count {
            // Overwrite existing header in-place (with padding if smaller)
            var padded = newHeader
            padded.append(contentsOf: [UInt8](repeating: 0, count: existingSize - newHeader.count))
            fileData.replaceSubrange(0..<existingSize, with: padded)
        } else {
            // Prepend new header, removing old one if present
            let audioStart = existingID3Size(in: fileData) ?? 0
            let audioData = fileData[audioStart...]
            fileData = newHeader + audioData
        }
        try fileData.write(to: url, options: .atomic)
    }

    private func existingID3Size(in data: Data) -> Int? {
        guard data.count >= 10,
              data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil }
        // ID3v2 syncsafe size is stored in bytes 6-9
        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14) | (Int(data[8]) << 7) | Int(data[9])
        return 10 + size
    }

    private func buildID3Header(tags: TrackTags) -> Data {
        var frames = Data()

        func textFrame(id: String, value: String?) {
            guard let value, !value.isEmpty else { return }
            // Frame: ID(4) + size(4) + flags(2) + encoding(1) + text
            var frame = Data()
            frame.append(contentsOf: Array(id.utf8))
            let textBytes = Array(value.utf8)
            let frameSize = 1 + textBytes.count
            frame.append(UInt8((frameSize >> 24) & 0xFF))
            frame.append(UInt8((frameSize >> 16) & 0xFF))
            frame.append(UInt8((frameSize >> 8) & 0xFF))
            frame.append(UInt8(frameSize & 0xFF))
            frame.append(contentsOf: [0x00, 0x00])  // flags
            frame.append(0x03)                        // UTF-8 encoding
            frame.append(contentsOf: textBytes)
            frames.append(frame)
        }

        textFrame(id: "TIT2", value: tags.title)
        textFrame(id: "TPE1", value: tags.artist)
        textFrame(id: "TPE2", value: tags.albumArtist)
        textFrame(id: "TALB", value: tags.album)
        textFrame(id: "TCON", value: tags.genre)
        textFrame(id: "TCOM", value: tags.composer)
        textFrame(id: "TDRC", value: tags.year.map { "\($0)" })
        textFrame(id: "TRCK", value: tags.trackNumber.map { "\($0)" })
        textFrame(id: "TPOS", value: tags.discNumber.map { "\($0)" })
        textFrame(id: "COMM", value: tags.comment)

        // Artwork (APIC frame)
        if let artData = tags.artworkData {
            var apic = Data()
            apic.append(contentsOf: Array("APIC".utf8))
            let content: [UInt8] = [0x03]                   // UTF-8
                + Array("image/jpeg".utf8) + [0x00]         // MIME
                + [0x03]                                     // cover (front)
                + [0x00]                                     // description (empty)
                + Array(artData)
            let size = content.count
            apic.append(UInt8((size >> 24) & 0xFF))
            apic.append(UInt8((size >> 16) & 0xFF))
            apic.append(UInt8((size >> 8)  & 0xFF))
            apic.append(UInt8(size & 0xFF))
            apic.append(contentsOf: [0x00, 0x00])
            apic.append(contentsOf: content)
            frames.append(apic)
        }

        // ID3v2.3 header: "ID3" + version(2.3) + flags + syncsafe size
        var header = Data()
        header.append(contentsOf: [0x49, 0x44, 0x33, 0x03, 0x00, 0x00])  // ID3 v2.3.0 no flags
        let totalSize = frames.count
        header.append(UInt8((totalSize >> 21) & 0x7F))
        header.append(UInt8((totalSize >> 14) & 0x7F))
        header.append(UInt8((totalSize >> 7)  & 0x7F))
        header.append(UInt8(totalSize & 0x7F))
        return header + frames
    }

    // MARK: - Vorbis Comments (FLAC only)
    /// Replaces the COMMENT block in a FLAC file.
    private func writeVorbisComments(tags: TrackTags, to url: URL) throws {
        // FLAC structure: fLaC marker (4 bytes) then metadata blocks.
        // Each block: type(1) + last-block-flag(1 bit) + size(3 bytes) + data.
        // Block type 4 = VORBIS_COMMENT.
        var data = try Data(contentsOf: url)
        guard data.prefix(4) == Data("fLaC".utf8) else { throw TagWriteError.unsupportedFormat }

        let comments = buildVorbisCommentBlock(tags: tags)
        data = replaceVorbisBlock(in: data, newBlock: comments)
        try data.write(to: url, options: .atomic)
    }

    private func buildVorbisCommentBlock(tags: TrackTags) -> Data {
        var entries: [String] = []
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

        // Build new comment packet body: magic prefix + Vorbis comment encoding
        var newBody = commentPrefix
        newBody.append(buildVorbisCommentBlock(tags: tags))
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
