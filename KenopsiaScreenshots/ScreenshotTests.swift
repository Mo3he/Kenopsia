import XCTest

// MARK: - ScreenshotTests
/// UI test suite that launches Kenopsia in demo mode and captures App Store screenshots.
///
/// Run via:
///   scripts/take_screenshots.sh
///
/// Or manually:
///   xcodebuild test -project Kenopsia.xcodeproj \
///     -scheme KenopsiaScreenshots \
///     -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
///     -resultBundlePath screenshots/results.xcresult
///
/// Screenshots are saved as XCTAttachments inside the .xcresult bundle and
/// extracted by the shell script into screenshots/<device>/.
final class ScreenshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments = ["--demo-mode"]
        app.launch()

        // Wait for the demo data to load and the library view to settle.
        let libraryLabel = app.staticTexts["LIBRARY"]
        XCTAssertTrue(libraryLabel.waitForExistence(timeout: 30), "Library view did not appear")
        // Additional buffer for demo data injection + layout pass.
        Thread.sleep(forTimeInterval: 1.2)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func snapshot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Tap the library section chip (ARTISTS / ALBUMS / TRACKS / PLAYLISTS).
    private func selectLibrarySection(_ label: String) {
        // The chips are plain-style buttons whose accessibility labels match their text.
        let button = app.buttons[label].firstMatch
        if button.waitForExistence(timeout: 3) {
            button.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    /// Navigate to a top-level section, using tab bar on iPhone or sidebar on iPad.
    private func navigateToSection(_ sidebarLabel: String, tabLabel: String) {
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists {
            tabBar.buttons[tabLabel].tap()
        } else {
            // iPad sidebar: tap the List cell whose label matches sidebarLabel.
            // With List(selection:) the cell is an XCUIElementType.cell.
            let cell = app.cells.containing(.staticText, identifier: sidebarLabel).firstMatch
            if cell.waitForExistence(timeout: 5) {
                cell.tap()
            }
        }
        Thread.sleep(forTimeInterval: 1.2)
    }

    /// Open the Now Playing sheet by tapping the mini player.
    private func openNowPlaying() {
        // The mini player shows "NOW PLAYING" text when not stopped.
        let miniPlayer = app.staticTexts["NOW PLAYING"].firstMatch
        if miniPlayer.waitForExistence(timeout: 5) {
            miniPlayer.tap()
            Thread.sleep(forTimeInterval: 0.8)
        }
    }

    // MARK: - Screenshots

    func test01_LibraryArtists() throws {
        selectLibrarySection("ARTISTS")
        snapshot("01_library_artists")
    }

    func test02_LibraryAlbums() throws {
        selectLibrarySection("ALBUMS")
        snapshot("02_library_albums")
    }

    func test03_LibraryTracks() throws {
        selectLibrarySection("TRACKS")
        snapshot("03_library_tracks")
    }

    func test04_LibraryPlaylists() throws {
        selectLibrarySection("PLAYLISTS")
        snapshot("04_library_playlists")
    }

    func test05_VibeTab() throws {
        navigateToSection("Vibe", tabLabel: "Vibe")
        snapshot("05_vibe")
    }

    func test06_NowPlaying() throws {
        openNowPlaying()
        snapshot("06_now_playing")
    }

    func test07_NowPlayingQueue() throws {
        openNowPlaying()
        // Button text is "QUEUE" (all-caps), not "Queue".
        let queueButton = app.buttons["QUEUE"].firstMatch
        if queueButton.waitForExistence(timeout: 4) {
            queueButton.tap()
            Thread.sleep(forTimeInterval: 1.0) // wait for sheet + list to render
            // Expand from medium to large detent for more visible tracks.
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.5)
        }
        snapshot("07_queue")
    }

    func test08_EQ() throws {
        openNowPlaying()
        // EQ button label in the bottom toolbar.
        let eqButton = app.buttons["EQ"].firstMatch
        if eqButton.waitForExistence(timeout: 4) {
            eqButton.tap()
            Thread.sleep(forTimeInterval: 0.6)
        }
        snapshot("08_eq")
    }

    func test09_Sources() throws {
        navigateToSection("Sources", tabLabel: "Sources")
        snapshot("09_sources")
    }

    func test10_Settings() throws {
        navigateToSection("Settings", tabLabel: "Settings")
        snapshot("10_settings")
    }

    func test11_LibraryGenres() throws {
        selectLibrarySection("GENRES")
        Thread.sleep(forTimeInterval: 0.8)
        snapshot("11_library_genres")
    }

    func test12_MultiSelect() throws {
        selectLibrarySection("TRACKS")
        let select = app.buttons["Select"].firstMatch
        guard select.waitForExistence(timeout: 5) else {
            XCTFail("Select button not found in the track list")
            return
        }
        select.tap()
        Thread.sleep(forTimeInterval: 0.6)

        // Tap rows by title rather than by index: the action bar appears after the
        // first selection and shifts everything below it, so positional taps land
        // on the wrong rows.
        for title in ["After Midnight", "Bloom", "Blackout"] {
            let row = app.staticTexts[title].firstMatch
            if row.waitForExistence(timeout: 2) {
                row.tap()
                Thread.sleep(forTimeInterval: 0.4)
            }
        }
        Thread.sleep(forTimeInterval: 0.6)
        snapshot("12_multi_select")
    }
}
