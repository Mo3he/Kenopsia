import Foundation

// MARK: - PlayerState
/// Observable snapshot of playback state, shared across the app and written
/// to the App Group container so the widget can read it.
struct PlayerState: Codable, Equatable {
    var status: PlaybackStatus = .stopped
    var currentTrackID: UUID?
    var positionSeconds: Double = 0
    var durationSeconds: Double = 0
    var volume: Float = 1.0         // 0.0 – 1.0
    var isAirPlaying: Bool = false

    // Widget-readable snapshot of now-playing metadata
    var nowPlayingTitle: String = ""
    var nowPlayingArtist: String = ""
    var nowPlayingAlbum: String = ""
    var nowPlayingArtworkCacheKey: String? = nil

    var progress: Double {
        guard durationSeconds > 0 else { return 0 }
        return positionSeconds / durationSeconds
    }
}

enum PlaybackStatus: String, Codable {
    case stopped, playing, paused, buffering
}

// MARK: - EQPreset
/// A 10-band parametric EQ preset.
struct EQPreset: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var bands: [EQBand]
    var isBuiltIn: Bool     // built-ins can't be deleted

    static let flat = EQPreset(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Flat",
        bands: EQBand.defaultBands,
        isBuiltIn: true
    )
}

struct EQBand: Identifiable, Codable, Hashable {
    let id: UUID
    var frequencyHz: Float  // e.g. 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    var gainDB: Float       // -12 to +12
    var qFactor: Float      // bandwidth

    static let defaultBands: [EQBand] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16_000]
        .map { freq in
            EQBand(id: UUID(), frequencyHz: Float(freq), gainDB: 0, qFactor: 1.0)
        }
}

// MARK: - EQPresetStore
/// Persists user EQ presets and the per-source EQ preset assignment.
final class EQPresetStore {
    static let shared = EQPresetStore()

    private let defaults = UserDefaults(suiteName: "group.net.mohome.kenopsia")
    private let encoder  = JSONEncoder()
    private let decoder  = JSONDecoder()

    // MARK: - User presets (built-ins + custom)
    var presets: [EQPreset] {
        get {
            let custom = (try? defaults?.data(forKey: "eqPresets")
                .flatMap { try decoder.decode([EQPreset].self, from: $0) }) ?? []
            return builtInPresets + custom
        }
    }

    func save(preset: EQPreset) {
        guard !preset.isBuiltIn else { return }
        var custom = customPresets
        if let idx = custom.firstIndex(where: { $0.id == preset.id }) {
            custom[idx] = preset
        } else {
            custom.append(preset)
        }
        if let data = try? encoder.encode(custom) {
            defaults?.set(data, forKey: "eqPresets")
        }
    }

    func delete(presetID: UUID) {
        var custom = customPresets
        custom.removeAll { $0.id == presetID }
        if let data = try? encoder.encode(custom) {
            defaults?.set(data, forKey: "eqPresets")
        }
    }

    // MARK: - Per-source assignment
    /// Returns the EQ preset assigned to a source, falling back to .flat.
    func preset(for sourceID: MusicSourceID) -> EQPreset {
        guard let data = defaults?.data(forKey: "eqSourceMap"),
              let map = try? decoder.decode([String: UUID].self, from: data),
              let presetID = map[sourceID.rawValue.uuidString],
              let preset = presets.first(where: { $0.id == presetID })
        else { return .flat }
        return preset
    }

    func assign(preset: EQPreset, to sourceID: MusicSourceID) {
        var map = sourcePresetMap
        map[sourceID.rawValue.uuidString] = preset.id
        if let data = try? encoder.encode(map) {
            defaults?.set(data, forKey: "eqSourceMap")
        }
    }

    // MARK: - Private
    private var customPresets: [EQPreset] {
        (try? defaults?.data(forKey: "eqPresets")
            .flatMap { try decoder.decode([EQPreset].self, from: $0) }) ?? []
    }

    private var sourcePresetMap: [String: UUID] {
        (try? defaults?.data(forKey: "eqSourceMap")
            .flatMap { try decoder.decode([String: UUID].self, from: $0) }) ?? [:]
    }

    private let builtInPresets: [EQPreset] = [
        .flat,
        EQPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                 name: "Bass Boost",
                 bands: EQBand.defaultBands.enumerated().map { i, b in
                     var band = b; band.gainDB = i < 2 ? 6 : 0; return band },
                 isBuiltIn: true),
        EQPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                 name: "Treble Boost",
                 bands: EQBand.defaultBands.enumerated().map { i, b in
                     var band = b; band.gainDB = i >= 7 ? 5 : 0; return band },
                 isBuiltIn: true),
        EQPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                 name: "Vocal Clarity",
                 bands: EQBand.defaultBands.enumerated().map { i, b in
                     var band = b
                     band.gainDB = (i == 4 || i == 5) ? 4 : (i < 2 ? -2 : 0)
                     return band },
                 isBuiltIn: true),
        EQPreset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                 name: "Late Night",
                 bands: EQBand.defaultBands.enumerated().map { i, b in
                     var band = b; band.gainDB = i >= 7 ? -4 : (i < 2 ? -3 : 0); return band },
                 isBuiltIn: true)
    ]
}

// MARK: - LyricsLine
/// A single line of synced lyrics (LRC format or LRCLIB response).
struct LyricsLine: Identifiable, Codable {
    let id: UUID
    var timestampSeconds: Double
    var text: String
}
