# Loudmouth Roadmap

Features planned for future releases, along with implementation notes to make them easy to pick up.

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

3. **Restore fetch functions** in `Loudmouth/Sources/Services/SourceResolver.swift`
   (add back `fetchDropboxTracks`, `fetchGoogleDriveTracks`, `fetchOneDriveTracks` and their `downloadURL` cases).

4. **Add picker options and OAuth UI** in `Loudmouth/Sources/Views/Sources/SourcesView.swift`:
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
| CarPlay framework | Linked via `linkedFrameworks` in `project.yml` |

### Notes
- `com.apple.developer.carplay-audio` must be enabled in the Apple Developer portal for the app's identifier before deploying to a real device (no special approval required for audio apps)
- Test with the CarPlay Simulator: Xcode → Hardware → CarPlay

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
