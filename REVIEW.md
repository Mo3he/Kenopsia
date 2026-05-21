# Kenopsia — Code Review Findings

Full review of all 51 Swift files (iOS app, widget, watch), `project.yml`, and `Info.plist`.
Last reviewed: 2026-05-21. Numbers below match the original review for traceability.

---

## ✅ Resolved — verified in current code

Every item below was re-checked file-by-file against the working tree.

### Original numbered findings
- **#1 — Subsonic/cloud playback restored.** `SourceResolver` is a singleton (`static let shared`);
  `PlaybackService` and `SourceViewModel` both default to `.shared`.
- **#2 — EQ persists.** `PlaybackService.apply(preset:)` calls `eqStore.assign(preset:to:)`.
- **#3 — Tag editing preserves untouched metadata.** M4A copies existing items (incl. `covr`);
  MP3 re-encodes untouched frames via `preservedID3Frames`; FLAC/Ogg keep non-standard Vorbis
  comments via `extractExistingVorbisComments` + `buildVorbisCommentBlock(preserving:)`.
- **#4 — Undecodable formats no longer scanned in.** `AudioFormat(fileExtension:)` excludes
  `dsd`/`dsf`/`dff`, `ogg`, `opus`, `wma`, `mpc`. *(README still advertises DSD — update the copy.)*
- **#5 — Queue UI updates reliably.** `PlayerViewModel.bind()` forwards `queue.objectWillChange`.
- **#6 — Smart playlists fully implemented.** New `SmartPlaylistEditorView` sheet: choose Manual/
  Smart, add/remove rules (field + condition + value), match operator, optional limit + sort.
  `PlaylistListView` opens it for new playlists; `PlaylistDetailView` has a pencil button to edit.
  `SmartPlaylistEvaluator.evaluate` is now an exhaustive switch covering all 18 fields.
- **#7 — Artwork Fixer cache-key mismatch fixed.** `autoFix`/`manualPickerSheet` use
  `ArtworkFetchService.generateCacheKey`; `LibraryStore.setArtworkCacheKey(_:forAlbumID:)` stamps
  every track.
- **#8 — Self-signed HTTPS for Subsonic.** `SubsonicSourceConfig.allowsSelfSignedCertificate`
  drives a scoped `LenientTLSDelegate`; toggle exposed in `SourceDetailView`.
- **#9 — Crossfade ReplayGain corrected.** `AudioEngine.preparePendingReplayGain` called with the
  incoming track's gain before `transition`.
- **#10 — Engine route-change fallback implemented.** `handleEngineConfigChange` falls back to
  `AVPlayer`.
- **#11 — Dead/half-wired data resolved.** `Track.comment` populated from `COMM`/`©cmt`; genre uses
  `TCON`/`©gen` (not `commonKeyType`); stale Web Radio tracks pruned before merge; `bpm` read from
  `TBPM`/`tmpo`; `isExplicit` read from `rtng` (≥4); new `Track.rating` (0–5) field. The evaluator
  matches `bpm`, `isExplicit`, `rating`, `acoustID`.

### Other fixes
- **`AlbumEditorView` writes through TagWriter** for every local-file track.
- **B2 auth token moved to header** via `PlaybackService.makeAVAssetExtractingAuth`.
- **Widget is interactive** — `TogglePlayPauseIntent` + Darwin notification + `Button(intent:)`.
- **Watch shows an "iPhone not reachable" banner** driven by `isPhoneReachable`.
- **Wi-Fi Transfer URL works on non-en0 interfaces.**
- **DLNA parser `current` leak fixed** — `didEndElement` returns early after `container`/`item`.
- **`ListeningStatsStore` is a singleton** — `PlaybackService`, the Settings sub-views, and
  `RecentlyPlayedView` all share `ListeningStatsStore.shared`.
- **"History" tab in Library** — new `RecentlyPlayedView` shows `recentlyPlayed`.
- **iPad `NavigationStack` nesting fixed** — `LibraryView` no longer wraps itself; `ContentView`
  wraps it once for the iPhone tab and once for the iPad split-view content column.
- **Dead `PlayerViewModel.setVolume` passthrough removed.**
- **Onboarding leads to source setup** — final page offers "Add Your First Source" (opens
  `SourcesView`) and "Skip for now"; closing the sheet dismisses onboarding.

---

## 🔴 Still open — significant

*(none)*

---

## 🟡 Still open — smaller bugs & polish

- **Widget toggle only works while the app is alive.** `TogglePlayPauseIntent` posts a Darwin
  notification, which iOS does not deliver to suspended/terminated apps. Works while audio is
  playing; does nothing once the app is suspended after a long pause.
- **`makeAVAssetExtractingAuth` uses a private key string** (`"AVURLAssetHTTPHeaderFieldsKey"`) --
  reliable in practice, acknowledged in comments, but undocumented.
- **`acoustID` is never populated** -- the evaluator can match it, but no AcoustID fingerprint
  lookup is wired up, so the field is always empty.
- **Watch app: no library browse or standalone playback** -- purely a remote.

### Resolved since last check
- **`RecentlyPlayedView` is now live.** Uses `@ObservedObject` on `ListeningStatsStore.shared`
  instead of a one-time `@State` snapshot; new plays appear immediately in the History tab.
- **History rows are tappable.** Tapping a row looks up the track in `LibraryStore.shared` and
  calls `player.play(tracks:)` immediately.
- **Numeric smart-playlist rules now support equality.** `allowedConditions` for `.numeric` fields
  includes `is_` and `isNot`; `matchNumeric` handles both. "Rating is 5" and "Year is 2020" work.
- **Test target added.** `KenopsiaTests` in `project.yml` (unit-test bundle, `GENERATE_INFOPLIST_FILE`
  set). `⌘U` now runs 33 tests across 9 suites covering `SmartPlaylistEvaluator` (all 18 fields,
  all condition types), `Queue` navigation/mutation/Codable, and `Playlist` Codable round-trips.
  All 33 pass.

---

## ✅ What's solid

- The gapless/crossfade engine with generation-counter invalidation, sentinel buffers, and
  stale-callback guards is genuinely careful work.
- Subsonic token auth, B2 native API pagination, SSDP discovery, and the Ogg/FLAC/ID3 writers are
  real implementations, not stubs.
- Stale-resolve cancellation in `resolveAndPlay`, the App Group write throttling, and
  interruption/route-change handling are well thought through.
- The smart-playlist editor cleanly gates conditions per field category and keeps the evaluator
  switch exhaustive, so new fields can't be silently unhandled.

---

## Recommended priority order (remaining)

1. Make `RecentlyPlayedView` observe the store so History updates live; make its rows tappable.
2. Update the README — DSD is no longer a supported format.
3. Add a test target — at minimum cover `TagWriter`, the queue state machine, and `Queue` Codable.
4. Add "is equal to" for numeric smart-playlist rules.
