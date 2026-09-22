# Kenopsia Roadmap

Features planned for future releases, along with implementation notes to make them easy to pick up.

---

## Crossfade Breaks After a Route Change 🐞 Bug

Reported by a user (Roy, Sep 2026): crossfade works on the phone and on wired headphones, but hard-cuts over AirPlay and wired CarPlay.

Not a routing or entitlement issue — crossfade is pure software (two `AVAudioPlayerNode`s ramped into `playerMixer`), so the output route cannot override it. The trigger is the route *change*: it fires `.AVAudioEngineConfigurationChange`, the engine restarts, and `PlaybackService.handleEngineConfigChange()` has two defects.

| # | Defect | Effect |
|---|---|---|
| 1 | `positionOffset` is never updated | `resumeActivePlayer` resets the node's `sampleTime` to 0, but position is computed as `sampleTime / sampleRate + positionOffset`. Reported position silently drops by the resume offset, so the crossfade trigger (`seconds >= duration - xfade`) never fires. Every other resume/seek path sets it — this one is the outlier. |
| 2 | `preScheduleNext` is never called | The engine restart clears the staging node's buffers, but nothing clears `stagingIsReady`. `transition(crossfade:)` reports success and fades in a silent player; the 1-frame sentinel fires immediately and falls through to a `play()` restart. |

### The fix

- `handleEngineConfigChange()`: set `positionOffset = position` alongside the `resumeActivePlayer` call, and re-run `preScheduleNext(next)` after a successful resume.
- Clear `stagingIsReady` in `AudioEngine.resumeActivePlayer` so a stale `true` can never survive a restart.

### Notes

- Either defect alone produces the hard cut; they compound.
- Predicts a testable signature: starting a track *while already* connected should crossfade correctly. Only a mid-playback route switch breaks it, and it stays broken for the rest of that session.
- Not reproducible in the simulator — needs a real head unit and an AirPlay target.
- Secondary hardening: the ramp runs as 61 `DispatchQueue.main.asyncAfter` blocks in `AudioEngine.crossfadeToStaging()`. Under CarPlay the main thread also drives template refreshes and artwork fetches, so steps can bunch. That degrades a fade; it does not eliminate one.

---

## Cloud Storage: Dropbox, Google Drive, OneDrive

Support for browsing and streaming music from third-party cloud storage providers via OAuth 2.0.

### What was built (removed pre-TestFlight to avoid requiring API keys)

All three providers were fully implemented and working:

| Provider | Fetch tracks | Download URL | OAuth flow |
|---|---|---|---|
| Dropbox | `POST /2/files/search_v2` | `POST /2/files/get_temporary_link` | Authorization Code + PKCE |
| Google Drive | `GET /drive/v3/files` (mime filter) | `GET /drive/v3/files/{id}?alt=media` (downloads to tmp) | Authorization Code |
| OneDrive (Graph) | `GET /me/drive/root/search(q='')` | `GET /me/drive/items/{id}/content` (302 redirect) | Authorization Code |

**The code is recoverable.** All three providers are intact in the initial commit `e2d95a4` (`Loudmouth/Sources/Services/SourceResolver.swift` — `fetchDropboxTracks`, `fetchGoogleDriveTracks`, `fetchOneDriveTracks`), removed in `41ff9ee`. This is a restore plus API-key registration, not a rebuild.

Google Drive specifically requested by a user (Roy, Sep 2026). Worth testing the zero-cost workaround first: the local-folder picker uses `.fileImporter` with `[.folder]`, so a Google Drive folder exposed through the Files app File Provider may already be addable as a Local source today.

### To restore

1. **Register developer apps** (all free tiers, no per-request cost for personal file access):
   - Dropbox: https://www.dropbox.com/developers/apps — create app, get App Key
   - Google Drive: https://console.cloud.google.com — create project, enable Drive API, create OAuth client ID (iOS), get Client ID
   - OneDrive: https://portal.azure.com — App registrations, add platform iOS/macOS, get Application (client) ID

2. **Add `CloudProvider` cases back** in `Loudmouth/Sources/Models/Track.swift`:
   ```swift
   enum CloudProvider: String, Codable {
       case iCloud, backblaze, dropbox, googleDrive, oneDrive
       var displayName: String {
           switch self {
           case .dropbox:     "Dropbox"
           case .googleDrive: "Google Drive"
           case .oneDrive:    "OneDrive"
           case .iCloud:      "iCloud Drive"
           case .backblaze:   "Backblaze B2"
           }
       }
   }
   ```

3. **Restore fetch functions** in `Kenopsia/Sources/Services/SourceResolver.swift`
   (add back `fetchDropboxTracks`, `fetchGoogleDriveTracks`, `fetchOneDriveTracks` and their `downloadURL` cases).

4. **Add picker options and OAuth UI** in `Kenopsia/Sources/Views/Sources/SourcesView.swift`:
   - Add Dropbox/Google Drive/OneDrive tags to the `Picker`
   - Restore the `else { }` OAuth connect branch
   - Restore `oauthConnected` / `oauthAccountName` state vars
   - Restore `connectOAuth(provider:)` function
   - Restore `CloudOAuth` enum with client IDs filled in
   - Restore `ASWebAuthenticationSession` SwiftUI helper extension and `PresentationCoordinator`
   - Add back `import AuthenticationServices`

5. **Fill in client IDs** in the restored `CloudOAuth` enum:
   ```swift
   static let dropboxClientID   = "<your Dropbox App Key>"
   static let googleClientID    = "<your Google Client ID>"
   static let microsoftClientID = "<your Azure Application ID>"
   ```

6. **Redirect URI** for all three: `loudmouth://` (already registered in `Info.plist` as a URL scheme).

---

## AVAudioSession Activated on the Main Thread ⚠️ Hang Risk

Xcode's runtime diagnostics flag `AudioEngine.configureAudioSession()`:

```
SessionCore.mm:631          setCategory  — can lead to UI unresponsiveness
AVAudioSession_iOS.mm:978   setActive    — consider the async activate API
```

All on Thread 1. `setActive(true)` can block for hundreds of milliseconds,
worst of all while a route is being established — exactly the AirPlay / CarPlay
moment the crossfade fix also lives in.

### Where it is called

| Caller | When |
|---|---|
| `PlaybackService.init` | App launch. Guarantees the session is configured for the AVPlayer path (streams, web radio), which never starts the engine and would otherwise play silently under `.soloAmbient`. |
| `AudioEngine.start()` | Whenever the engine is not running: launch, route change, interruption recovery. Guarded by `!isRunning`, so it is *not* a per-track hot path. |

### Why this was not fixed inline

The ordering is load-bearing and documented in the code: the category must be
set before `engine.start()` so nil-format connections negotiate against the real
hardware format, otherwise nodes silently disconnect. Making activation
asynchronous means making `start()` async, which ripples into `play(file:)` and
the whole synchronous startup path — the most delicate code in the app, and the
part that already carries two route-change fixes that have not yet been
confirmed on hardware.

Caching "already configured" to skip redundant calls is *not* a safe shortcut:
the session genuinely must be reactivated after an interruption ends, so a
blanket flag would break resume-after-phone-call.

### Doing it properly

1. Activate once, off the main thread, early in app launch.
2. Keep `setCategory` synchronous where format negotiation depends on it.
3. Track activation state against `AVAudioSession.interruptionNotification` so
   reactivation still happens exactly when it is required.
4. Test on a device across: launch, backgrounding, phone-call interruption,
   headphone plug/unplug, AirPlay engage, CarPlay connect.

Step 4 is the real cost. This wants a focused pass with hardware, not a
drive-by.

---

## GCKUICastButton.triggersDefaultCastDialog Deprecated

`CastButtonView.swift:44`. The only warning in our own code.

It is used deliberately, and the file documents why: `presentCastDialog()` walks
from the key window's root view controller, so the Cast dialog appears *behind*
the Now Playing sheet. `triggersDefaultCastDialog` walks the responder chain
instead, finds `CastButtonHostVC` inside the sheet, and presents correctly.

Migrating to `GCKUICastButtonDelegate` means taking over presentation, which
risks reintroducing that bug. Worth doing only with the sheet case explicitly
re-tested. Harmless until the SDK removes the property.

---

## Library List / Grid Toggle

Requested by a user (Roy, Sep 2026): let Artists and Albums display as a linear list, like the Songs view, instead of the artwork grid.

Both are currently hard-coded to a 2-column `LazyVGrid` in `Kenopsia/Sources/Views/Library/LibraryView.swift` (`AlbumsView`, `ArtistsView`). No layout preference exists.

### Notes

- Row-style cells already exist alongside the grid cells in the same file, so this is likely a toggle plus a persisted preference rather than new cell work — confirm before scoping.
- Persist with `@AppStorage` so it survives launches. Decide whether Albums and Artists get independent settings or share one.
- Put the control in the navigation bar, not Settings — it is a view-level preference.

---

## Duplicate Song Detection

Requested by a user (Roy, Sep 2026).

Nothing exists today. `LibraryStore` dedupes by URI on rescan, so a rescan will not double-add the same file, but the same song existing as two *different* files is never detected.

### Approach

1. Normalize `artist` + `title` — case-fold, strip punctuation and leading articles, trim `feat.` suffixes.
2. Group, then confirm with `durationSeconds` within a small tolerance.
3. Surface a review screen — never auto-delete. Show format, bitrate, file size and source per copy so the user picks the keeper.

### Notes

- Fits the existing `MetadataFixerView` / `ArtworkFixerView` pattern; model the UI on those.
- Acoustic fingerprinting is more accurate but needs a service. Tag-based matching covers the common case: an album ripped twice, or the same track present in both a local folder and a NAS.

---

## Apple Music / MusicKit Integration ✅ Done

Browse and play tracks from the user's Apple Music library using the MusicKit framework.

### What was built

| Area | Detail |
|---|---|
| Entitlement | `com.apple.developer.music-kit` added to `Loudmouth.entitlements` |
| Permission | `NSAppleMusicUsageDescription` added to `Info.plist` |
| Model | `MusicSourceKind.appleMusic`, `TrackURI.appleMusicID(id:)`, `AppleMusicSourceConfig` |
| Service | `AppleMusicService` (actor) — `requestAuthorisation()`, `fetchTracks()` via `MusicLibraryRequest<Song>`, `song(for:)`, `cacheArtwork(for:)` |
| Playback | `PlaybackService` routes `appleMusicID` URIs to `ApplicationMusicPlayer.shared`; pause/resume/seek all pass through the music player when active |
| Source adapter | `SourceViewModel.registerAdapter` registers `AppleMusicService`; `scan()` handles `.appleMusic` config; `connectAppleMusic()` requests auth then triggers a library scan |
| UI | `AppleMusicDetailSection` shows auth status and a Sync Library button; `AddSourceView` has an `.appleMusic` info section; `SourcesView` excludes Apple Music from the manual scan button |

### Notes
- `ApplicationMusicPlayer` handles DRM — local file path resolution is skipped for Apple Music tracks
- The `com.apple.developer.music-kit` entitlement must be enabled in the Apple Developer portal for the app's identifier before deploying to a real device (no approval required)

---

## CarPlay ✅ Done

Audio app template for CarPlay with Now Playing and library browsing.

### What was built

| Area | Detail |
|---|---|
| Entitlement | `com.apple.developer.carplay-audio` added to `Loudmouth.entitlements` |
| Scene config | `CPTemplateApplicationSceneSessionRoleApplication` scene added to `Info.plist`; delegate class `CarPlaySceneDelegate` |
| Scene delegate | `Loudmouth/Sources/CarPlay/CarPlaySceneDelegate.swift` — `@MainActor`, conforms to `CPTemplateApplicationSceneDelegate` |
| Now Playing tab | `CPNowPlayingTemplate.shared` — auto-driven by the existing `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` wiring in `PlaybackService`; no extra code needed |
| Library tab | `CPListTemplate` with Albums, Playlists, and Songs sections; tap to drill into album/playlist track list |
| Drill-down | Album detail: Play All, Shuffle, and individual tracks. Playlist detail: Play All and individual tracks |
| PlaybackService | Added `static let shared` singleton so both the SwiftUI layer and `CarPlaySceneDelegate` share the same instance |
| CarPlay framework | Auto-linked from `import CarPlay`; no explicit entry in `project.yml`. Note that XcodeGen has no `linkedFrameworks` target key — system frameworks go under `dependencies` as `sdk:`. |

### Notes
- `com.apple.developer.carplay-audio` must be enabled in the Apple Developer portal for the app's identifier before deploying to a real device (no special approval required for audio apps)
- Test with the CarPlay Simulator: Xcode → Hardware → CarPlay

---

### Planned enhancements

Requested by a user (Roy, Sep 2026): "a more complete CarPlay interface." The shipped 1.1 build (archived and uploaded 2026-06-03) already has Recents, Library with Albums/Artists/Playlists/Songs, search, and Now Playing. Remaining gaps:

- Only two tabs are constructed in `buildRootTemplate()`, though the file header comment claims four
- No Genres browsing
- No shuffle-all entry point
- `CPListTemplate.maximumItemCount` truncation is silent — the user is never told a list was cut off
- **Sitting uncommitted in the working tree:** `refreshNowPlayingButtonAvailability()` gates the Up Next / Album-Artist buttons on real queue state. Shipped 1.1 enables both unconditionally, so they look tappable but do nothing on a single-track queue or web radio. Ship this.

---

## AirPlay 2 / Multi-Room Audio

Stream to multiple AirPlay 2 targets simultaneously.

### Notes
- Requires `com.apple.developer.airplay` entitlement (restricted, requires Apple approval)
- `AVPlayer` already supports AirPlay; multi-room needs `AVAudioSession.setPreferredOutputNumberOfChannels`

---

## watchOS Companion ✅ Done

Now Playing controls on Apple Watch, communicating with the iPhone app via WatchConnectivity.

### What was built

| Area | Detail |
|---|---|
| Phone service | `WatchConnectivityService` (MainActor singleton) — activates `WCSession`, observes `PlaybackService.shared.$state`, sends state snapshots via `updateApplicationContext`, routes commands back to `PlaybackService` |
| State sync | `PlayerState` fields (status, position, duration, title, artist, album) + JPEG artwork thumbnail (100×100, only sent on track change) sent as the WC application context |
| Watch app | `LoudmouthWatch/` target — `LoudmouthWatchApp` (`@main` SwiftUI App), `PhoneConnectivityService`, `NowPlayingView` |
| Watch UI | Artwork (with `UIImage(data:)` fallback to music note icon), track title + artist, linear progress bar, previous / play-pause / next transport buttons |
| Commands | Watch buttons call `PhoneConnectivityService.sendCommand(_:)` → `WCSession.sendMessage` → phone routes to `PlaybackService` |
| project.yml | `LoudmouthWatch` watchOS 10 target added; `LoudmouthWatch` embedded as a dependency of `Loudmouth` |

### Notes
- The iOS `BUILD SUCCEEDED` — the watch target compiles but requires the watchOS 26.5 simulator runtime to run (install via Xcode → Settings → Components → Platforms)
- Test with Xcode's paired simulator: run the iOS app on the iPhone 17 Pro simulator, then in Xcode menu I/O → External Displays → Apple Watch
- Position is refreshed on the watch from the debounced (1 s) context update; the watch does not do its own timer
