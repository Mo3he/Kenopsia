# Loudmouth – Agent Instructions

Swift/SwiftUI iOS music player. iOS 17+, Xcode 16, Swift 5.10. No external dependencies.

## Build

```bash
# Regenerate .xcodeproj after project.yml changes
xcodegen generate

# Build for simulator
xcodebuild -project Loudmouth.xcodeproj -scheme Loudmouth \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# Check errors only
xcodebuild ... build 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```

> **Important:** New Swift files must be declared in `project.yml`, not added via Xcode UI. After editing `project.yml`, run `xcodegen generate` before building. Do not edit `.xcodeproj/project.pbxproj` by hand.

## Source layout

```
Loudmouth/Sources/
  App/            LoudmouthApp.swift
  Models/         Track, MusicSource, Queue, Playlist, Album, PlayerState
  Services/       AudioEngine, PlaybackService, SourceResolver, LibraryStore, LibraryScanner,
                  AppleMusicService, ArtworkCache/FetchService, LyricsService,
                  OfflineCacheService, TagWriter, SubsonicModels, DLNABrowser,
                  ListeningStatsStore
  ViewModels/     PlayerViewModel, LibraryViewModel, SourceViewModel, SearchViewModel
  Views/          ContentView + subfolders: Library, NowPlaying, Onboarding, Search, Settings, Sources
LoudmouthWidget/  Home Screen widget (now-playing)
project.yml       XcodeGen project spec
ROADMAP.md        Feature backlog with implementation notes
```

## Architecture

### Playback routing (PlaybackService – @MainActor)

| Track URI | Player |
|---|---|
| `.localFile`, `.subsonicID`, `.dlnaURL`, `.cloudFile` | `AVAudioEngine` — gapless, 10-band EQ, ReplayGain |
| `.remoteURL`, `.webRadio` | `AVPlayer` — streaming/HLS/Icecast |
| `.appleMusicID` | `ApplicationMusicPlayer.shared` — MusicKit, handles DRM |

### Source adapter pattern

All adapters conform to `protocol MusicSourceAdapter: Actor`. Register via `SourceViewModel.registerAdapter(_:)`. The adapter must implement `fetchTracks() async throws -> [Track]`. `SourceResolver` dispatches URL resolution to the correct adapter at playback time.

### LibraryStore (@MainActor)

Tracks are merged by `TrackURI.stableKey`. Existing stats (playCount, lastPlayedAt, isFavourited) survive rescans. Saves to `library.json` in the App Group container (`group.net.mohome.loudmouth`).

### Concurrency

- `SourceResolver` and all `*SourceAdapter` types are **actors**.
- `PlaybackService`, `LibraryStore` are `@MainActor`.
- `AudioEngine` is a plain class; all calls go through `PlaybackService`.

## Common pitfalls

### Audio session
- Use category `.playback` with options `[.allowAirPlay]` **only**.
- Never add `.allowBluetooth` to `.playback` — causes `kAudio_ParamError (-50)` on device.
- Bluetooth routing for `.playback` is handled automatically by the system.

### AVAudioEngine
- Connect nodes with **nil format**; hard-coded formats before engine start cause silent disconnection when hardware sample rate differs → "player started when in a disconnected state" crash.
- On `AVAudioEngineConfigurationChange`: call `engine.start()` only — **do not rebuild the graph**.
- Guard `outputConnectionPoints(for:outputBus:)` is non-empty before calling `playerNode.play()`; the resulting Swift error enables AVPlayer fallback.

### TrackURI switches
All switches on `TrackURI` must be exhaustive across all 7 cases: `.localFile`, `.remoteURL`, `.subsonicID`, `.dlnaURL`, `.webRadio`, `.cloudFile`, `.appleMusicID`. Omitting a case is a compile error — don't add a `default:`.

### MusicSourceConfig mutations
`MusicSourceConfig` is an associated enum. Mutate with:
```swift
guard case .subsonic(var cfg) = source.config else { return }
cfg.someField = newValue
source.config = .subsonic(cfg)
```
Forgetting to reassign loses the change silently.

## App identity

| | |
|---|---|
| Bundle ID | `net.mohome.loudmouth` |
| App Group | `group.net.mohome.loudmouth` |
| Team | `KTX2SJ3P98` |
| MusicKit entitlement | must be enabled in Apple Developer portal for real-device builds |

## Key reference files

- [ROADMAP.md](ROADMAP.md) — feature backlog and implementation notes for planned features
- [Loudmouth/Loudmouth.entitlements](Loudmouth/Loudmouth.entitlements) — all entitlements
- [project.yml](project.yml) — XcodeGen spec (single source of truth for project structure)
