#if DEBUG
import Foundation
import UIKit

// MARK: - DemoDataProvider
/// Provides real CC-licensed library data and a frozen playback state for App Store
/// screenshot automation. Only active when the `--demo-mode` launch argument
/// is present (injected by the KenopsiaScreenshots UI test target).
///
/// Run `scripts/setup_demo_assets.sh` once before building to download audio + artwork.
///
/// Attribution (CC BY 4.0 unless noted):
///   Chris Zabriskie  - https://chriszabriskie.com
///   Lee Rosevere     - https://leerosevere.bandcamp.com
///   Kai Engel        - https://freemusicarchive.org/music/Kai_Engel
///   Kevin MacLeod    - https://incompetech.com
///   Jahzzar (CC BY-SA 3.0) - https://jahzzar.bandcamp.com
@MainActor
enum DemoDataProvider {

    // MARK: - Detection
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("--demo-mode")
    }

    // MARK: - Fixed IDs (stable across screenshot runs)
    static let sourceID = MusicSourceID(UUID(uuidString: "FACE0000-0000-0000-0000-000000000000")!)

    // Chris Zabriskie – Cylinders
    private static let cz1 = UUID(uuidString: "00C00001-0000-0000-0000-000000000001")!
    private static let cz2 = UUID(uuidString: "00C00001-0000-0000-0000-000000000002")!
    private static let cz3 = UUID(uuidString: "00C00001-0000-0000-0000-000000000003")!
    private static let cz4 = UUID(uuidString: "00C00001-0000-0000-0000-000000000004")!
    private static let cz5 = UUID(uuidString: "00C00001-0000-0000-0000-000000000005")!

    // Lee Rosevere – Music Inspired by MiNRS
    private static let lr1 = UUID(uuidString: "00C00002-0000-0000-0000-000000000001")!
    private static let lr2 = UUID(uuidString: "00C00002-0000-0000-0000-000000000002")!
    private static let lr3 = UUID(uuidString: "00C00002-0000-0000-0000-000000000003")!
    private static let lr4 = UUID(uuidString: "00C00002-0000-0000-0000-000000000004")!
    private static let lr5 = UUID(uuidString: "00C00002-0000-0000-0000-000000000005")!

    // Kai Engel – Idea
    private static let ke1 = UUID(uuidString: "00C00003-0000-0000-0000-000000000001")!
    private static let ke2 = UUID(uuidString: "00C00003-0000-0000-0000-000000000002")!
    private static let ke3 = UUID(uuidString: "00C00003-0000-0000-0000-000000000003")!
    private static let ke4 = UUID(uuidString: "00C00003-0000-0000-0000-000000000004")!
    private static let ke5 = UUID(uuidString: "00C00003-0000-0000-0000-000000000005")!

    // Kevin MacLeod – Vicious
    private static let km1 = UUID(uuidString: "00C00004-0000-0000-0000-000000000001")!
    private static let km2 = UUID(uuidString: "00C00004-0000-0000-0000-000000000002")!
    private static let km3 = UUID(uuidString: "00C00004-0000-0000-0000-000000000003")!
    private static let km4 = UUID(uuidString: "00C00004-0000-0000-0000-000000000004")!
    private static let km5 = UUID(uuidString: "00C00004-0000-0000-0000-000000000005")!

    // Jahzzar – Super
    private static let jz1 = UUID(uuidString: "00C00005-0000-0000-0000-000000000001")!
    private static let jz2 = UUID(uuidString: "00C00005-0000-0000-0000-000000000002")!
    private static let jz3 = UUID(uuidString: "00C00005-0000-0000-0000-000000000003")!
    private static let jz4 = UUID(uuidString: "00C00005-0000-0000-0000-000000000004")!
    private static let jz5 = UUID(uuidString: "00C00005-0000-0000-0000-000000000005")!

    // Virtual artists – display-only tracks (same source, fake paths, borrowed artwork)
    // Aria Solis – Bloom (A)
    private static let as1 = UUID(uuidString: "00AA0001-0000-0000-0000-000000000001")!
    private static let as2 = UUID(uuidString: "00AA0001-0000-0000-0000-000000000002")!
    private static let as3 = UUID(uuidString: "00AA0001-0000-0000-0000-000000000003")!
    // Cosmo Drake – Drift (C)
    private static let cd1 = UUID(uuidString: "00AB0001-0000-0000-0000-000000000001")!
    private static let cd2 = UUID(uuidString: "00AB0001-0000-0000-0000-000000000002")!
    private static let cd3 = UUID(uuidString: "00AB0001-0000-0000-0000-000000000003")!
    // Jade River – The Distance (J)
    private static let jr1 = UUID(uuidString: "00AC0001-0000-0000-0000-000000000001")!
    private static let jr2 = UUID(uuidString: "00AC0001-0000-0000-0000-000000000002")!
    private static let jr3 = UUID(uuidString: "00AC0001-0000-0000-0000-000000000003")!
    // Kyle Strand – Iron Gate (K)
    private static let ks1 = UUID(uuidString: "00AD0001-0000-0000-0000-000000000001")!
    private static let ks2 = UUID(uuidString: "00AD0001-0000-0000-0000-000000000002")!
    private static let ks3 = UUID(uuidString: "00AD0001-0000-0000-0000-000000000003")!
    // Lena Collins – Soft Hours (L)
    private static let lc1 = UUID(uuidString: "00AE0001-0000-0000-0000-000000000001")!
    private static let lc2 = UUID(uuidString: "00AE0001-0000-0000-0000-000000000002")!
    private static let lc3 = UUID(uuidString: "00AE0001-0000-0000-0000-000000000003")!
    // Mara Sun – Coastal (M)
    private static let ms1 = UUID(uuidString: "00AF0001-0000-0000-0000-000000000001")!
    private static let ms2 = UUID(uuidString: "00AF0001-0000-0000-0000-000000000002")!
    private static let ms3 = UUID(uuidString: "00AF0001-0000-0000-0000-000000000003")!

    // MARK: - Helpers

    private static func audioPath(_ filename: String) -> String {
        // XcodeGen copies folder-reference contents flat to the bundle root.
        Bundle.main.path(forResource: filename, ofType: nil)
            ?? Bundle.main.bundlePath + "/" + filename
    }

    private static func albumKey(artist: String, album: String) -> String {
        let combined = "\(artist.lowercased()):\(album.lowercased())"
        return combined.data(using: .utf8).map { Data($0).base64EncodedString() } ?? ""
    }

    private static func artistKey(name: String) -> String {
        let k = "artist_photo:\(name.lowercased())"
        return k.data(using: .utf8).map { Data($0).base64EncodedString() } ?? ""
    }

    // MARK: - Demo catalog
    static var demoTracks: [Track] {
        let czKey   = albumKey(artist: "Chris Zabriskie", album: "Cylinders")
        let lrKey   = albumKey(artist: "Lee Rosevere",   album: "Music Inspired by MiNRS")
        let keKey   = albumKey(artist: "Kai Engel",      album: "Idea")
        let kmKey   = albumKey(artist: "Kevin MacLeod",  album: "Vicious")
        let jzKey   = albumKey(artist: "Jahzzar",        album: "Super")
        // Virtual artist artwork keys – each gets its own gradient
        let ariaKey  = albumKey(artist: "Aria Solis",   album: "Bloom")
        let cosmoKey = albumKey(artist: "Cosmo Drake",  album: "Drift")
        let jadeKey  = albumKey(artist: "Jade River",   album: "The Distance")
        let kyleKey  = albumKey(artist: "Kyle Strand",  album: "Iron Gate")
        let lenaKey  = albumKey(artist: "Lena Collins", album: "Soft Hours")
        let maraKey  = albumKey(artist: "Mara Sun",     album: "Coastal")

        let y2014 = Calendar.current.date(from: DateComponents(year: 2014, month: 3, day: 1))!
        let y2022 = Calendar.current.date(from: DateComponents(year: 2022, month: 6, day: 1))!
        let y2013 = Calendar.current.date(from: DateComponents(year: 2013, month: 9, day: 1))!
        let y2016 = Calendar.current.date(from: DateComponents(year: 2016, month: 1, day: 1))!
        let y2015 = Calendar.current.date(from: DateComponents(year: 2015, month: 4, day: 1))!

        return [
            // MARK: Chris Zabriskie – Cylinders (Ambient/Electronic, 2014, CC BY 4.0)
            Track(
                id: cz1, title: "Cylinder One",
                artist: "Chris Zabriskie", albumArtist: "Chris Zabriskie",
                album: "Cylinders", genre: "Ambient", year: 2014, trackNumber: 1,
                source: sourceID,
                uri: .localFile(path: audioPath("cylinders_01.mp3")),
                format: .mp3, durationSeconds: 176,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: czKey,
                playCount: 31,
                lastPlayedAt: Calendar.current.date(byAdding: .hour, value: -2, to: .now),
                dateAdded: y2014, isFavourited: true, rating: 5
            ),
            Track(
                id: cz2, title: "Cylinder Two",
                artist: "Chris Zabriskie", albumArtist: "Chris Zabriskie",
                album: "Cylinders", genre: "Ambient", year: 2014, trackNumber: 2,
                source: sourceID,
                uri: .localFile(path: audioPath("cylinders_02.mp3")),
                format: .mp3, durationSeconds: 228,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: czKey,
                playCount: 24, dateAdded: y2014, rating: 4
            ),
            Track(
                id: cz3, title: "Cylinder Three",
                artist: "Chris Zabriskie", albumArtist: "Chris Zabriskie",
                album: "Cylinders", genre: "Ambient", year: 2014, trackNumber: 3,
                source: sourceID,
                uri: .localFile(path: audioPath("cylinders_03.mp3")),
                format: .mp3, durationSeconds: 166,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: czKey,
                playCount: 19, dateAdded: y2014, rating: 4
            ),
            Track(
                id: cz4, title: "Cylinder Four",
                artist: "Chris Zabriskie", albumArtist: "Chris Zabriskie",
                album: "Cylinders", genre: "Ambient", year: 2014, trackNumber: 4,
                source: sourceID,
                uri: .localFile(path: audioPath("cylinders_04.mp3")),
                format: .mp3, durationSeconds: 177,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: czKey,
                playCount: 15, dateAdded: y2014, rating: 3
            ),
            Track(
                id: cz5, title: "Cylinder Five",
                artist: "Chris Zabriskie", albumArtist: "Chris Zabriskie",
                album: "Cylinders", genre: "Ambient", year: 2014, trackNumber: 5,
                source: sourceID,
                uri: .localFile(path: audioPath("cylinders_05.mp3")),
                format: .mp3, durationSeconds: 174,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: czKey,
                playCount: 22,
                lastPlayedAt: Calendar.current.date(byAdding: .day, value: -1, to: .now),
                dateAdded: y2014, isFavourited: true, rating: 5
            ),

            // MARK: Lee Rosevere – Music Inspired by MiNRS (Cinematic, 2022, CC BY 4.0)
            Track(
                id: lr1, title: "Perses",
                artist: "Lee Rosevere", albumArtist: "Lee Rosevere",
                album: "Music Inspired by MiNRS", genre: "Cinematic", year: 2022, trackNumber: 1,
                source: sourceID,
                uri: .localFile(path: audioPath("minrs_01.mp3")),
                format: .mp3, durationSeconds: 142,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: lrKey,
                playCount: 17,
                lastPlayedAt: Calendar.current.date(byAdding: .hour, value: -5, to: .now),
                dateAdded: y2022, rating: 4
            ),
            Track(
                id: lr2, title: "The Great Mission",
                artist: "Lee Rosevere", albumArtist: "Lee Rosevere",
                album: "Music Inspired by MiNRS", genre: "Cinematic", year: 2022, trackNumber: 2,
                source: sourceID,
                uri: .localFile(path: audioPath("minrs_02.mp3")),
                format: .mp3, durationSeconds: 138,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: lrKey,
                playCount: 13, dateAdded: y2022, rating: 4
            ),
            Track(
                id: lr3, title: "Blackout",
                artist: "Lee Rosevere", albumArtist: "Lee Rosevere",
                album: "Music Inspired by MiNRS", genre: "Cinematic", year: 2022, trackNumber: 3,
                source: sourceID,
                uri: .localFile(path: audioPath("minrs_03.mp3")),
                format: .mp3, durationSeconds: 253,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: lrKey,
                playCount: 9, dateAdded: y2022, isFavourited: true, rating: 5
            ),
            Track(
                id: lr4, title: "In the Mines",
                artist: "Lee Rosevere", albumArtist: "Lee Rosevere",
                album: "Music Inspired by MiNRS", genre: "Cinematic", year: 2022, trackNumber: 4,
                source: sourceID,
                uri: .localFile(path: audioPath("minrs_04.mp3")),
                format: .mp3, durationSeconds: 193,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: lrKey,
                playCount: 7, dateAdded: y2022, rating: 3
            ),
            Track(
                id: lr5, title: "Landers",
                artist: "Lee Rosevere", albumArtist: "Lee Rosevere",
                album: "Music Inspired by MiNRS", genre: "Cinematic", year: 2022, trackNumber: 5,
                source: sourceID,
                uri: .localFile(path: audioPath("minrs_05.mp3")),
                format: .mp3, durationSeconds: 250,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: lrKey,
                playCount: 11, dateAdded: y2022, rating: 4
            ),

            // MARK: Kai Engel – Idea (Piano/Ambient, 2013, CC BY 4.0)
            Track(
                id: ke1, title: "Idea",
                artist: "Kai Engel", albumArtist: "Kai Engel",
                album: "Idea", genre: "Piano", year: 2013, trackNumber: 1,
                source: sourceID,
                uri: .localFile(path: audioPath("idea_01.mp3")),
                format: .mp3, durationSeconds: 174,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: keKey,
                playCount: 44,
                lastPlayedAt: Calendar.current.date(byAdding: .minute, value: -45, to: .now),
                dateAdded: y2013, isFavourited: true, rating: 5
            ),
            Track(
                id: ke2, title: "Endless Story About Sun and Moon",
                artist: "Kai Engel", albumArtist: "Kai Engel",
                album: "Idea", genre: "Piano", year: 2013, trackNumber: 2,
                source: sourceID,
                uri: .localFile(path: audioPath("idea_02.mp3")),
                format: .mp3, durationSeconds: 185,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: keKey,
                playCount: 38, dateAdded: y2013, rating: 4
            ),
            Track(
                id: ke3, title: "After Midnight",
                artist: "Kai Engel", albumArtist: "Kai Engel",
                album: "Idea", genre: "Piano", year: 2013, trackNumber: 3,
                source: sourceID,
                uri: .localFile(path: audioPath("idea_03.mp3")),
                format: .mp3, durationSeconds: 181,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: keKey,
                playCount: 29, dateAdded: y2013, isFavourited: true, rating: 5
            ),
            Track(
                id: ke4, title: "Behind Your Window",
                artist: "Kai Engel", albumArtist: "Kai Engel",
                album: "Idea", genre: "Piano", year: 2013, trackNumber: 4,
                source: sourceID,
                uri: .localFile(path: audioPath("idea_04.mp3")),
                format: .mp3, durationSeconds: 156,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: keKey,
                playCount: 21, dateAdded: y2013, rating: 4
            ),
            Track(
                id: ke5, title: "Touch the Darkness",
                artist: "Kai Engel", albumArtist: "Kai Engel",
                album: "Idea", genre: "Piano", year: 2013, trackNumber: 5,
                source: sourceID,
                uri: .localFile(path: audioPath("idea_05.mp3")),
                format: .mp3, durationSeconds: 299,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: keKey,
                playCount: 16, dateAdded: y2013, rating: 4
            ),

            // MARK: Kevin MacLeod – Vicious (Electronic/Action, 2016, CC BY 4.0)
            Track(
                id: km1, title: "Pyro Flow",
                artist: "Kevin MacLeod", albumArtist: "Kevin MacLeod",
                album: "Vicious", genre: "Electronic", year: 2016, trackNumber: 1,
                source: sourceID,
                uri: .localFile(path: audioPath("vicious_01.mp3")),
                format: .mp3, durationSeconds: 234,
                bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: kmKey,
                playCount: 52,
                lastPlayedAt: Calendar.current.date(byAdding: .day, value: -2, to: .now),
                dateAdded: y2016, isFavourited: true, rating: 5
            ),
            Track(
                id: km2, title: "Vicious",
                artist: "Kevin MacLeod", albumArtist: "Kevin MacLeod",
                album: "Vicious", genre: "Electronic", year: 2016, trackNumber: 2,
                source: sourceID,
                uri: .localFile(path: audioPath("vicious_02.mp3")),
                format: .mp3, durationSeconds: 225,
                bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: kmKey,
                playCount: 41, dateAdded: y2016, rating: 4
            ),
            Track(
                id: km3, title: "Lewis and DeKalb",
                artist: "Kevin MacLeod", albumArtist: "Kevin MacLeod",
                album: "Vicious", genre: "Electronic", year: 2016, trackNumber: 3,
                source: sourceID,
                uri: .localFile(path: audioPath("vicious_03.mp3")),
                format: .mp3, durationSeconds: 197,
                bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: kmKey,
                playCount: 33, dateAdded: y2016, rating: 4
            ),
            Track(
                id: km4, title: "Chillin Hard",
                artist: "Kevin MacLeod", albumArtist: "Kevin MacLeod",
                album: "Vicious", genre: "Electronic", year: 2016, trackNumber: 4,
                source: sourceID,
                uri: .localFile(path: audioPath("vicious_04.mp3")),
                format: .mp3, durationSeconds: 234,
                bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: kmKey,
                playCount: 27, dateAdded: y2016, rating: 3
            ),
            Track(
                id: km5, title: "Basic Implosion",
                artist: "Kevin MacLeod", albumArtist: "Kevin MacLeod",
                album: "Vicious", genre: "Electronic", year: 2016, trackNumber: 5,
                source: sourceID,
                uri: .localFile(path: audioPath("vicious_05.mp3")),
                format: .mp3, durationSeconds: 190,
                bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: kmKey,
                playCount: 19, dateAdded: y2016, rating: 3
            ),

            // MARK: Jahzzar – Super (Pop/Funk, 2015, CC BY-SA 3.0)
            Track(
                id: jz1, title: "Shake It!",
                artist: "Jahzzar", albumArtist: "Jahzzar",
                album: "Super", genre: "Funk", year: 2015, trackNumber: 1,
                source: sourceID,
                uri: .localFile(path: audioPath("super_01.mp3")),
                format: .mp3, durationSeconds: 273,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: jzKey,
                playCount: 63,
                lastPlayedAt: Calendar.current.date(byAdding: .hour, value: -3, to: .now),
                dateAdded: y2015, isFavourited: true, rating: 5
            ),
            Track(
                id: jz2, title: "Chiefs",
                artist: "Jahzzar", albumArtist: "Jahzzar",
                album: "Super", genre: "Funk", year: 2015, trackNumber: 2,
                source: sourceID,
                uri: .localFile(path: audioPath("super_02.mp3")),
                format: .mp3, durationSeconds: 337,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: jzKey,
                playCount: 48, dateAdded: y2015, rating: 4
            ),
            Track(
                id: jz3, title: "No Control",
                artist: "Jahzzar", albumArtist: "Jahzzar",
                album: "Super", genre: "Funk", year: 2015, trackNumber: 3,
                source: sourceID,
                uri: .localFile(path: audioPath("super_03.mp3")),
                format: .mp3, durationSeconds: 216,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: jzKey,
                playCount: 35, dateAdded: y2015, rating: 4
            ),
            Track(
                id: jz4, title: "Word Up",
                artist: "Jahzzar", albumArtist: "Jahzzar",
                album: "Super", genre: "Funk", year: 2015, trackNumber: 4,
                source: sourceID,
                uri: .localFile(path: audioPath("super_04.mp3")),
                format: .mp3, durationSeconds: 300,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: jzKey,
                playCount: 27, dateAdded: y2015, rating: 3
            ),
            Track(
                id: jz5, title: "Comedie",
                artist: "Jahzzar", albumArtist: "Jahzzar",
                album: "Super", genre: "Funk", year: 2015, trackNumber: 5,
                source: sourceID,
                uri: .localFile(path: audioPath("super_05.mp3")),
                format: .mp3, durationSeconds: 280,
                bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                artworkCacheKey: jzKey,
                playCount: 21, dateAdded: y2015, rating: 4
            ),

            // MARK: Virtual artists (display-only — paths are placeholders)

            // MARK: Aria Solis – Bloom (Indie, 2021)
            Track(id: as1, title: "First Light", artist: "Aria Solis", albumArtist: "Aria Solis",
                  album: "Bloom", genre: "Indie", year: 2021, trackNumber: 1, source: sourceID,
                  uri: .localFile(path: "/private/demo/v001_01.mp3"),
                  format: .mp3, durationSeconds: 225, bitrateBps: 256_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: ariaKey, playCount: 38,
                  lastPlayedAt: Calendar.current.date(byAdding: .hour, value: -4, to: .now),
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2021, month: 7, day: 1))!, isFavourited: true, rating: 5),
            Track(id: as2, title: "Still Water", artist: "Aria Solis", albumArtist: "Aria Solis",
                  album: "Bloom", genre: "Indie", year: 2021, trackNumber: 2, source: sourceID,
                  uri: .localFile(path: "/private/demo/v001_02.mp3"),
                  format: .mp3, durationSeconds: 252, bitrateBps: 256_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: ariaKey, playCount: 29,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2021, month: 7, day: 1))!, rating: 4),
            Track(id: as3, title: "Bloom", artist: "Aria Solis", albumArtist: "Aria Solis",
                  album: "Bloom", genre: "Indie", year: 2021, trackNumber: 3, source: sourceID,
                  uri: .localFile(path: "/private/demo/v001_03.mp3"),
                  format: .mp3, durationSeconds: 301, bitrateBps: 256_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: ariaKey, playCount: 22,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2021, month: 7, day: 1))!, rating: 4),

            // MARK: Cosmo Drake – Drift (Electronic, 2023)
            Track(id: cd1, title: "Shoreline", artist: "Cosmo Drake", albumArtist: "Cosmo Drake",
                  album: "Drift", genre: "Electronic", year: 2023, trackNumber: 1, source: sourceID,
                  uri: .localFile(path: "/private/demo/v002_01.mp3"),
                  format: .mp3, durationSeconds: 234, bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: cosmoKey, playCount: 57,
                  lastPlayedAt: Calendar.current.date(byAdding: .day, value: -1, to: .now),
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2023, month: 4, day: 1))!, isFavourited: true, rating: 5),
            Track(id: cd2, title: "Low Clouds", artist: "Cosmo Drake", albumArtist: "Cosmo Drake",
                  album: "Drift", genre: "Electronic", year: 2023, trackNumber: 2, source: sourceID,
                  uri: .localFile(path: "/private/demo/v002_02.mp3"),
                  format: .mp3, durationSeconds: 263, bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: cosmoKey, playCount: 43,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2023, month: 4, day: 1))!, rating: 4),
            Track(id: cd3, title: "Carry Me", artist: "Cosmo Drake", albumArtist: "Cosmo Drake",
                  album: "Drift", genre: "Electronic", year: 2023, trackNumber: 3, source: sourceID,
                  uri: .localFile(path: "/private/demo/v002_03.mp3"),
                  format: .mp3, durationSeconds: 197, bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: cosmoKey, playCount: 31,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2023, month: 4, day: 1))!, rating: 4),

            // MARK: Jade River – The Distance (Ambient, 2022)
            Track(id: jr1, title: "Open Country", artist: "Jade River", albumArtist: "Jade River",
                  album: "The Distance", genre: "Ambient", year: 2022, trackNumber: 1, source: sourceID,
                  uri: .localFile(path: "/private/demo/v003_01.mp3"),
                  format: .mp3, durationSeconds: 285, bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: jadeKey, playCount: 19,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2022, month: 2, day: 1))!, rating: 4),
            Track(id: jr2, title: "Pale Horizon", artist: "Jade River", albumArtist: "Jade River",
                  album: "The Distance", genre: "Ambient", year: 2022, trackNumber: 2, source: sourceID,
                  uri: .localFile(path: "/private/demo/v003_02.mp3"),
                  format: .mp3, durationSeconds: 218, bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: jadeKey, playCount: 14,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2022, month: 2, day: 1))!, isFavourited: true, rating: 5),
            Track(id: jr3, title: "The Distance", artist: "Jade River", albumArtist: "Jade River",
                  album: "The Distance", genre: "Ambient", year: 2022, trackNumber: 3, source: sourceID,
                  uri: .localFile(path: "/private/demo/v003_03.mp3"),
                  format: .mp3, durationSeconds: 322, bitrateBps: 128_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: jadeKey, playCount: 11,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2022, month: 2, day: 1))!, rating: 3),

            // MARK: Kyle Strand – Iron Gate (Rock, 2020)
            Track(id: ks1, title: "Pressure Wave", artist: "Kyle Strand", albumArtist: "Kyle Strand",
                  album: "Iron Gate", genre: "Rock", year: 2020, trackNumber: 1, source: sourceID,
                  uri: .localFile(path: "/private/demo/v004_01.mp3"),
                  format: .mp3, durationSeconds: 209, bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: kyleKey, playCount: 72,
                  lastPlayedAt: Calendar.current.date(byAdding: .hour, value: -6, to: .now),
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2020, month: 10, day: 1))!, isFavourited: true, rating: 5),
            Track(id: ks2, title: "Ignition", artist: "Kyle Strand", albumArtist: "Kyle Strand",
                  album: "Iron Gate", genre: "Rock", year: 2020, trackNumber: 2, source: sourceID,
                  uri: .localFile(path: "/private/demo/v004_02.mp3"),
                  format: .mp3, durationSeconds: 247, bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: kyleKey, playCount: 61,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2020, month: 10, day: 1))!, rating: 4),
            Track(id: ks3, title: "Iron Gate", artist: "Kyle Strand", albumArtist: "Kyle Strand",
                  album: "Iron Gate", genre: "Rock", year: 2020, trackNumber: 3, source: sourceID,
                  uri: .localFile(path: "/private/demo/v004_03.mp3"),
                  format: .mp3, durationSeconds: 344, bitrateBps: 320_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: kyleKey, playCount: 49,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2020, month: 10, day: 1))!, rating: 4),

            // MARK: Lena Collins – Soft Hours (Lo-Fi, 2023)
            Track(id: lc1, title: "Sunday Slow", artist: "Lena Collins", albumArtist: "Lena Collins",
                  album: "Soft Hours", genre: "Lo-Fi", year: 2023, trackNumber: 1, source: sourceID,
                  uri: .localFile(path: "/private/demo/v005_01.mp3"),
                  format: .mp3, durationSeconds: 222, bitrateBps: 192_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: lenaKey, playCount: 44,
                  lastPlayedAt: Calendar.current.date(byAdding: .minute, value: -90, to: .now),
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2023, month: 8, day: 1))!, isFavourited: true, rating: 5),
            Track(id: lc2, title: "Warm Glass", artist: "Lena Collins", albumArtist: "Lena Collins",
                  album: "Soft Hours", genre: "Lo-Fi", year: 2023, trackNumber: 2, source: sourceID,
                  uri: .localFile(path: "/private/demo/v005_02.mp3"),
                  format: .mp3, durationSeconds: 259, bitrateBps: 192_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: lenaKey, playCount: 33,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2023, month: 8, day: 1))!, rating: 4),
            Track(id: lc3, title: "Settle", artist: "Lena Collins", albumArtist: "Lena Collins",
                  album: "Soft Hours", genre: "Lo-Fi", year: 2023, trackNumber: 3, source: sourceID,
                  uri: .localFile(path: "/private/demo/v005_03.mp3"),
                  format: .mp3, durationSeconds: 302, bitrateBps: 192_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: lenaKey, playCount: 26,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2023, month: 8, day: 1))!, rating: 4),

            // MARK: Mara Sun – Coastal (Chill, 2024)
            Track(id: ms1, title: "Tide Pool", artist: "Mara Sun", albumArtist: "Mara Sun",
                  album: "Coastal", genre: "Chill", year: 2024, trackNumber: 1, source: sourceID,
                  uri: .localFile(path: "/private/demo/v006_01.mp3"),
                  format: .mp3, durationSeconds: 273, bitrateBps: 256_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: maraKey, playCount: 18,
                  lastPlayedAt: Calendar.current.date(byAdding: .day, value: -3, to: .now),
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1))!, isFavourited: true, rating: 5),
            Track(id: ms2, title: "Sea Foam", artist: "Mara Sun", albumArtist: "Mara Sun",
                  album: "Coastal", genre: "Chill", year: 2024, trackNumber: 2, source: sourceID,
                  uri: .localFile(path: "/private/demo/v006_02.mp3"),
                  format: .mp3, durationSeconds: 236, bitrateBps: 256_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: maraKey, playCount: 12,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1))!, rating: 4),
            Track(id: ms3, title: "Coastal", artist: "Mara Sun", albumArtist: "Mara Sun",
                  album: "Coastal", genre: "Chill", year: 2024, trackNumber: 3, source: sourceID,
                  uri: .localFile(path: "/private/demo/v006_03.mp3"),
                  format: .mp3, durationSeconds: 317, bitrateBps: 256_000, sampleRateHz: 44100, channelCount: 2,
                  artworkCacheKey: maraKey, playCount: 8,
                  dateAdded: Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 1))!, rating: 3),
        ]
    }

    // MARK: - Demo playlists
    static var demoPlaylists: [Playlist] {
        var lateNight = Playlist(
            id: UUID(uuidString: "0000F001-0000-0000-0000-000000000001")!,
            name: "Late Night Drive"
        )
        lateNight.trackIDs = [cz1, cz5, km1, km2, jz1]

        var chill = Playlist(
            id: UUID(uuidString: "0000F002-0000-0000-0000-000000000002")!,
            name: "Chill Out"
        )
        chill.trackIDs = [ke1, ke2, ke3, lr3, lr5]

        return [lateNight, chill]
    }

    // MARK: - Load
    /// Merges demo tracks into the shared LibraryStore and configures a static
    /// "paused" playback state so every view renders as if music is loaded.
    static func load() {
        let tracks = demoTracks

        injectDemoArtwork()

        LibraryStore.shared.removeTracks(from: sourceID)
        LibraryStore.shared.merge(tracks: tracks, from: sourceID)

        for playlist in demoPlaylists {
            LibraryStore.shared.save(playlist: playlist)
        }

        // Freeze playback: "Idea" by Kai Engel paused at 1:42 (600×600 artwork looks best at full-bleed).
        let nowPlaying = tracks.first(where: { $0.id == ke1 }) ?? tracks[0]
        let nowPlayingIdx = tracks.firstIndex(where: { $0.id == ke1 }) ?? 0
        var demoState = PlayerState()
        demoState.status = .paused
        demoState.currentTrackID = nowPlaying.id
        demoState.positionSeconds = 87
        demoState.durationSeconds = nowPlaying.durationSeconds
        demoState.nowPlayingTitle = nowPlaying.title
        demoState.nowPlayingArtist = nowPlaying.artist
        demoState.nowPlayingAlbum = nowPlaying.album
        demoState.nowPlayingArtworkCacheKey = nowPlaying.artworkCacheKey

        let demoQueue = Queue()
        demoQueue.replace(with: tracks, startAt: nowPlayingIdx)

        PlaybackService.shared.setDemoState(demoState, queue: demoQueue)
    }

    // MARK: - Artwork injection
    /// Loads bundled JPG artwork into ArtworkCache (album art + artist photos).
    /// Falls back to a solid-colour placeholder if the asset is missing.
    private static func injectDemoArtwork() {
        let albums: [(imageFile: String, artist: String, album: String)] = [
            ("album_cylinders", "Chris Zabriskie", "Cylinders"),
            ("album_minrs",     "Lee Rosevere",    "Music Inspired by MiNRS"),
            ("album_idea",      "Kai Engel",       "Idea"),
            ("album_vicious",   "Kevin MacLeod",   "Vicious"),
            ("album_super",     "Jahzzar",         "Super"),
        ]

        let artistPhotos: [(imageFile: String, artistName: String)] = [
            ("artist_chris_zabriskie", "Chris Zabriskie"),
            ("artist_lee_rosevere",    "Lee Rosevere"),
            ("artist_kai_engel",       "Kai Engel"),
            ("artist_kevin_macleod",   "Kevin MacLeod"),
            ("artist_jahzzar",         "Jahzzar"),
        ]

        func loadFromBundle(_ name: String) -> Data? {
            // Files are copied flat to the bundle root by XcodeGen.
            let path = Bundle.main.path(forResource: name, ofType: "jpg")
                    ?? Bundle.main.path(forResource: name, ofType: nil)
            guard let p = path else { return nil }
            return try? Data(contentsOf: URL(fileURLWithPath: p))
        }

        for entry in albums {
            let key = albumKey(artist: entry.artist, album: entry.album)
            guard !ArtworkCache.shared.hasArtwork(forKey: key) else { continue }
            if let data = loadFromBundle(entry.imageFile) {
                ArtworkCache.shared.store(imageData: data, forKey: key)
            }
        }

        for entry in artistPhotos {
            let key = artistKey(name: entry.artistName)
            guard !ArtworkCache.shared.hasArtwork(forKey: key) else { continue }
            if let data = loadFromBundle(entry.imageFile) {
                ArtworkCache.shared.store(imageData: data, forKey: key)
            }
        }

        // Load real photo artwork for virtual artists from bundle.
        let virtualEntries: [(imageFile: String, artist: String, album: String)] = [
            ("virtual_aria",  "Aria Solis",   "Bloom"),
            ("virtual_cosmo", "Cosmo Drake",  "Drift"),
            ("virtual_jade",  "Jade River",   "The Distance"),
            ("virtual_kyle",  "Kyle Strand",  "Iron Gate"),
            ("virtual_lena",  "Lena Collins", "Soft Hours"),
            ("virtual_mara",  "Mara Sun",     "Coastal"),
        ]

        for entry in virtualEntries {
            guard let data = loadFromBundle(entry.imageFile) else { continue }
            let aKey = albumKey(artist: entry.artist, album: entry.album)
            if !ArtworkCache.shared.hasArtwork(forKey: aKey) {
                ArtworkCache.shared.store(imageData: data, forKey: aKey)
            }
            let pKey = artistKey(name: entry.artist)
            if !ArtworkCache.shared.hasArtwork(forKey: pKey) {
                ArtworkCache.shared.store(imageData: data, forKey: pKey)
            }
        }
    }
}
#endif

