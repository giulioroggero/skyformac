import XCTest

/// UI-level automated tests driving the real SwiftUI view tree via the Accessibility API
/// (XCUITest), not just the underlying logic — a gap the 100 `skyformacTests` unit tests don't
/// cover, since those never touch a live view hierarchy.
///
/// `@MainActor` on the class: `XCUIApplication`/`XCUIElement` are `@MainActor`-isolated in the
/// SDK these tests build against, and XCTest genuinely does run test methods on the main thread
/// — this annotation just tells the Swift 6 compiler what was already true at runtime, avoiding
/// "call to main actor-isolated ... in a synchronous nonisolated context" errors under Xcode
/// 16.4's stricter checking (not reproduced on a newer local Xcode, which apparently inferred
/// this differently).
@MainActor
final class SkyformacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// This app's main window is the orientation Dashboard (`DashboardHomeView`) whenever no
    /// session is running — the camera view (and its "Cameras" sidebar) only appears once a
    /// session is actually active. Quick Start is the fastest way there: it creates a throwaway
    /// project/session for a curated target and switches straight into the camera view
    /// (`RootView` swaps views the moment `CameraManager.activeSession` becomes non-`nil`), so
    /// tests that need the camera view use it rather than assuming it's what launch shows.
    private func launchIntoCameraView(_ app: XCUIApplication) {
        app.launch()
        // Matched by its own accessibility identifier, not label text — the Dashboard's "Ideas
        // for Next Time" section also has one-off "Quick Start…" buttons per suggested object
        // (even on a fresh install with no history yet — see `InsightsData.build`'s empty-capture
        // branch), so a label-based match here would be ambiguous between the two.
        let quickStartTile = app.buttons["DashboardQuickStartTile"]
        XCTAssertTrue(quickStartTile.waitForExistence(timeout: 10))
        quickStartTile.tap()
        // Same reasoning for each Quick Start row inside the sheet — matched by prefix rather
        // than substring, since the Dashboard tile still in the accessibility tree behind the
        // sheet mentions "the Moon" too in its own subtitle.
        let moonRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Moon (Detail)")).firstMatch
        XCTAssertTrue(moonRow.waitForExistence(timeout: 5))
        moonRow.tap()
    }

    func testAppLaunchesIntoTheDashboard() throws {
        let app = XCUIApplication()
        app.launch()

        // "Common Tasks" is the Dashboard's own section header — present only when showing the
        // Dashboard, not the camera view.
        XCTAssertTrue(app.staticTexts["Common Tasks"].waitForExistence(timeout: 10))
    }

    func testQuickStartOpensTheCameraSidebar() throws {
        let app = XCUIApplication()
        launchIntoCameraView(app)

        // "Cameras" is the sidebar section header from CameraListView.
        XCTAssertTrue(app.staticTexts["Cameras"].waitForExistence(timeout: 10))
    }

    func testToolbarRendererToggleExists() throws {
        let app = XCUIApplication()
        launchIntoCameraView(app)

        // Label reads "GPU"/"CPU" depending on the current render path, so the test targets the
        // stable accessibility identifier rather than the (state-dependent) display text.
        XCTAssertTrue(app.checkBoxes["RenderPathToggle"].waitForExistence(timeout: 10)
            || app.buttons["RenderPathToggle"].waitForExistence(timeout: 1))
    }

    func testSettingsToolbarButtonOpensTheSettingsSheet() throws {
        let app = XCUIApplication()
        app.launch()

        // The Home page's own "Settings" tile was removed from "Common Tasks" — Settings is still
        // reachable via this toolbar button (and ⌘,), so this now drives that instead.
        // `.matching(identifier:).firstMatch` rather than the `buttons[...]` subscript: a
        // `ToolbarItem`'s own accessibility proxy can transiently expose the same identifier on
        // more than one node before the toolbar settles, which makes the (must-be-exactly-one)
        // subscript form flaky here — `firstMatch` tolerates that without caring which one it is,
        // since both represent the same visual button. `waitForExistence` first, rather than
        // tapping immediately after `launch()`, for the same "give the toolbar a moment to
        // render" reason every other tile/button in this file already waits for.
        let settingsButton = app.buttons.matching(identifier: "DashboardSettingsToolbarButton").firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 10))
        settingsButton.tap()

        // The Projects Folder section header is unique to `SettingsView` — its presence confirms
        // the sheet actually opened rather than the tap silently doing nothing.
        XCTAssertTrue(app.staticTexts["Projects Folder"].waitForExistence(timeout: 10))
    }

    func testInsightsTileOpensTheInsightsPage() throws {
        let app = XCUIApplication()
        app.launch()

        // Unlike `launchIntoCameraView`'s own Quick Start tile, this tapped the tile immediately
        // after `launch()` with no `waitForExistence` — on a slow/cold CI runner the tap can land
        // before the button is actually hittable and silently do nothing, leaving the app stuck on
        // the Dashboard for the rest of the timeout below (the likely cause of an otherwise
        // unreproducible-locally CI failure here). Waiting first, matching every tap-then-navigate
        // test elsewhere in this file, removes that race outright.
        let insightsTile = app.buttons["DashboardInsightsTile"]
        XCTAssertTrue(insightsTile.waitForExistence(timeout: 10))
        insightsTile.tap()

        // macOS `NavigationStack` titles don't surface as an XCUITest `NavigationBar` element the
        // way they do on iOS, so this checks for "Overview" — `InsightsView`'s own first
        // `PageSection` title, unique to that page — instead.
        XCTAssertTrue(app.staticTexts["Overview"].waitForExistence(timeout: 10))
    }

    func testAllProjectsTileOpensTheProjectsList() throws {
        let app = XCUIApplication()
        app.launch()

        // Same "wait before tapping" fix as `testInsightsTileOpensTheInsightsPage` above — this
        // had the identical race (tapping right after `launch()`, no wait).
        let allProjectsTile = app.buttons["DashboardAllProjectsTile"]
        XCTAssertTrue(allProjectsTile.waitForExistence(timeout: 10))
        allProjectsTile.tap()

        // "Filters" is `ProjectsHomeView`'s own toolbar button, unique to that page.
        XCTAssertTrue(app.buttons["Filters"].waitForExistence(timeout: 10))
    }

    func testAssistantPanelIsVisibleByDefaultOnTheDashboard() throws {
        let app = XCUIApplication()
        app.launch()

        // "AI" is `AssistantChatPanel`'s own header label — present by default (a chat "on
        // the right bar of all pages" should be there without the user having to discover a menu
        // item first), not dependent on the Dashboard vs. Projects vs. camera view underneath it.
        XCTAssertTrue(app.staticTexts["AI"].waitForExistence(timeout: 10))
    }

    func testMinimizingTheAssistantShowsTheExpandRail() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 10))
        app.buttons["Minimize"].tap()

        XCTAssertTrue(app.buttons["Expand AI"].waitForExistence(timeout: 5))
    }

    func testAIPanelIsDetachedNotEmbeddedWhileTheCameraViewIsRunning() throws {
        let app = XCUIApplication()
        launchIntoCameraView(app)

        // "AI" still exists (in its own floating window) with a "Close" button (the detached
        // header always shows one), but "Minimize"/"Detach" only ever appear on the *embedded*
        // sidebar copy — their absence here confirms the panel is floating, not docked, while a
        // session is actually running.
        XCTAssertTrue(app.staticTexts["AI"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Minimize"].exists)
        XCTAssertFalse(app.buttons["Detach"].exists)
    }

}
