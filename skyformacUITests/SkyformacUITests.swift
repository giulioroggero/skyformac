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
    /// A fresh directory per test — passed to the launched app as `SKYFORMAC_UITEST_ROOT`
    /// (`AppSettings.resolveRootDirectory`), which redirects Projects/Equipment/Knowledge Base
    /// storage here instead of the developer's real `~/Documents/Skyformac Projects` (or wherever
    /// Settings actually points). Quick Start creates a genuine on-disk project — without this
    /// isolation, every UI test run left real, permanent test projects behind in real user data
    /// (confirmed: stray "Moon (Detail)" test projects were found in a real Projects folder).
    /// Removed permanently in `tearDown` — nothing from a test run should survive it.
    private var testRootURL: URL!

    // `async` overrides, not `setUpWithError()`/`tearDownWithError()` — XCTestCase declares its
    // synchronous throwing setUp/tearDown as `nonisolated` in the SDK even on a `@MainActor`
    // subclass, so they can't touch a main-actor-isolated stored property like `testRootURL`
    // directly. Confirmed on CI (Xcode 16.4): "main actor-isolated property 'testRootURL' can not
    // be mutated from a nonisolated context" — not reproduced on a newer local Xcode, which
    // apparently inferred isolation differently for the synchronous overrides (see this file's
    // own `@MainActor` doc comment above for the identical class of issue). The `async` lifecycle
    // hooks are properly isolated to the class's own actor on every Xcode version.
    override func setUp() async throws {
        continueAfterFailure = false
        testRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skyformac-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testRootURL, withIntermediateDirectories: true)
        // The AI panel's visible/minimized/detached state (`AppSettings.isAssistantPanelVisible`
        // et al.) persists across *real* launches, which is the whole point for real usage but
        // breaks these tests' assumption that every `app.launch()` starts from the same hardcoded
        // defaults. `AppSettings` itself already routes those three through an in-memory,
        // per-process store instead of real `UserDefaults` whenever `SKYFORMAC_UITEST_ROOT` is
        // set (see its own doc comment) — no separate reset needed here. An earlier version of
        // this fix reset the on-disk defaults from here instead, which raced the *previous* test's
        // just-terminated app process still flushing its own write to that same shared file —
        // passed most of the time locally, failed on every single CI run.
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: testRootURL)
    }

    /// Every test creates its `XCUIApplication` through here rather than calling the initializer
    /// directly — this is what actually wires `testRootURL` in, so every launch this test makes
    /// stays isolated from real user data.
    private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SKYFORMAC_UITEST_ROOT"] = testRootURL.path
        return app
    }

    /// Scrolls a "Common Tasks" tile into an actually-tappable position, then taps it.
    /// `XCUIElement.isHittable` alone isn't reliable for this row: on a narrower window (CI's
    /// 1024×768 virtual display, confirmed via a downloaded xcresult) the AI sidebar sits to the
    /// right of the row, and a tile whose accessibility frame still overlaps that sidebar area can
    /// wrongly report `isHittable == true` — the synthesized tap then lands on the sidebar
    /// underneath instead of the tile, and the app never navigates anywhere. Comparing the tile's
    /// real on-screen frame against the scroll view's own frame is an actual geometry check rather
    /// than trusting the accessibility layer's hit-test result.
    private func scrollCommonTasksTileIntoViewAndTap(
        _ element: XCUIElement, within scrollView: XCUIElement, timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        func isFullyVisible() -> Bool {
            let bounds = scrollView.frame
            let frame = element.frame
            return frame.width > 0 && frame.minX >= bounds.minX && frame.maxX <= bounds.maxX
        }
        for direction: CGFloat in [200, -200] {
            let deadline = Date().addingTimeInterval(timeout / 2)
            while !isFullyVisible() && Date() < deadline {
                scrollView.scroll(byDeltaX: direction, deltaY: 0)
            }
            if isFullyVisible() { break }
        }
        XCTAssertTrue(isFullyVisible(), "\(element) never scrolled into an actually-tappable position", file: file, line: line)
        element.tap()
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
        let app = makeApp()
        app.launch()

        // "Common Tasks" is the Dashboard's own section header — present only when showing the
        // Dashboard, not the camera view.
        XCTAssertTrue(app.staticTexts["Common Tasks"].waitForExistence(timeout: 10))
    }

    func testQuickStartOpensTheCameraSidebar() throws {
        let app = makeApp()
        launchIntoCameraView(app)

        // "Cameras" is the sidebar section header from CameraListView.
        XCTAssertTrue(app.staticTexts["Cameras"].waitForExistence(timeout: 10))
    }

    func testToolbarRendererToggleExists() throws {
        let app = makeApp()
        launchIntoCameraView(app)

        // Label reads "GPU"/"CPU" depending on the current render path, so the test targets the
        // stable accessibility identifier rather than the (state-dependent) display text.
        XCTAssertTrue(app.checkBoxes["RenderPathToggle"].waitForExistence(timeout: 10)
            || app.buttons["RenderPathToggle"].waitForExistence(timeout: 1))
    }

    func testSettingsToolbarButtonOpensTheSettingsSheet() throws {
        let app = makeApp()
        app.launch()

        // The Home page's own "Settings" tile was removed from "Common Tasks" — Settings is still
        // reachable via this toolbar button (and ⌘,), so this now drives that instead.
        // A `ToolbarItem`'s own accessibility representation duplicates this identifier onto TWO
        // nodes — an outer layout container spanning the whole toolbar height, and the actual
        // clickable inner button nested inside it (confirmed via a downloaded CI .xcresult: the
        // outer one, `{{1100,25},{38,52}}`, is never hittable; the inner one, `{{1104,37},{30,28}}`,
        // is) — so neither a unique-match subscript nor a blind `firstMatch` reliably picks the
        // right one. Polling `allElementsBoundByIndex` for whichever one is actually hittable
        // sidesteps needing to know which index that'll be.
        let candidates = app.buttons.matching(identifier: "DashboardSettingsToolbarButton")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        var settingsButton: XCUIElement?
        while settingsButton == nil && Date() < deadline {
            settingsButton = candidates.allElementsBoundByIndex.first(where: \.isHittable)
            if settingsButton == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        let button = try XCTUnwrap(settingsButton, "No hittable DashboardSettingsToolbarButton found")
        button.tap()

        // The Projects Folder section header is unique to `SettingsView` — its presence confirms
        // the sheet actually opened rather than the tap silently doing nothing.
        XCTAssertTrue(app.staticTexts["Projects Folder"].waitForExistence(timeout: 10))
    }

    func testInsightsTileOpensTheInsightsPage() throws {
        let app = makeApp()
        app.launch()

        let insightsTile = app.buttons["DashboardInsightsTile"]
        XCTAssertTrue(insightsTile.waitForExistence(timeout: 10))
        // The "Common Tasks" row is a horizontal ScrollView of tiles; on a narrower window (a
        // downloaded CI screen recording confirmed this — the AI sidebar leaves less room for the
        // main content there than on a typical local dev display) a later tile like Insights is
        // scrolled out of view. macOS XCUITest does NOT auto-scroll an off-screen-but-existing
        // element into view before tapping (unlike iOS), so the tap was landing on whatever was
        // actually on screen underneath — the AI panel — instead of this tile, leaving the app
        // stuck on the Dashboard for the rest of the wait below. Scroll it into view explicitly —
        // repeatedly, re-checking hittability each time, rather than a single fixed-distance
        // attempt: exactly how far it's scrolled off-screen depends on the actual window width,
        // which isn't something to hardcode a single guess for.
        let commonTasksScroll = app.scrollViews["CommonTasksScrollView"]
        scrollCommonTasksTileIntoViewAndTap(insightsTile, within: commonTasksScroll)

        // macOS `NavigationStack` titles don't surface as an XCUITest `NavigationBar` element the
        // way they do on iOS, so this checks for "Overview" — `InsightsView`'s own first
        // `PageSection` title, unique to that page — instead.
        XCTAssertTrue(app.staticTexts["Overview"].waitForExistence(timeout: 10))
    }

    func testSkyVisibilityTileOpensTheWhatToSeePage() throws {
        let app = makeApp()
        app.launch()

        let skyVisibilityTile = app.buttons["DashboardSkyVisibilityTile"]
        XCTAssertTrue(skyVisibilityTile.waitForExistence(timeout: 10))
        let commonTasksScroll = app.scrollViews["CommonTasksScrollView"]
        scrollCommonTasksTileIntoViewAndTap(skyVisibilityTile, within: commonTasksScroll)

        // `SkyVisibilityExplorerView`'s own first `PageSection` title, unique to that page.
        XCTAssertTrue(app.staticTexts["Where and When"].waitForExistence(timeout: 10))
    }

    func testGuideLogTileOpensThePHD2GuideLogPage() throws {
        let app = makeApp()
        app.launch()

        let guideLogTile = app.buttons["DashboardGuideLogTile"]
        XCTAssertTrue(guideLogTile.waitForExistence(timeout: 10))
        let commonTasksScroll = app.scrollViews["CommonTasksScrollView"]
        scrollCommonTasksTileIntoViewAndTap(guideLogTile, within: commonTasksScroll)

        // `PHD2GuideLogView`'s own first `PageSection` title, unique to that page.
        XCTAssertTrue(app.staticTexts["Import"].waitForExistence(timeout: 10))
    }

    func testAllProjectsTileOpensTheProjectsList() throws {
        let app = makeApp()
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
        let app = makeApp()
        app.launch()

        // "AI" is `AssistantChatPanel`'s own header label — present by default (a chat "on
        // the right bar of all pages" should be there without the user having to discover a menu
        // item first), not dependent on the Dashboard vs. Projects vs. camera view underneath it.
        XCTAssertTrue(app.staticTexts["AI"].waitForExistence(timeout: 10))
    }

    func testMinimizingTheAssistantShowsTheExpandRail() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 10))
        app.buttons["Minimize"].tap()

        XCTAssertTrue(app.buttons["Expand AI"].waitForExistence(timeout: 5))
    }

    func testAIPanelIsDetachedNotEmbeddedWhileTheCameraViewIsRunning() throws {
        let app = makeApp()
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

    func testExpandingTheAssistantRestoresTheEmbeddedPanel() throws {
        let app = makeApp()
        app.launch()

        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 10))
        app.buttons["Minimize"].tap()

        let expandButton = app.buttons["Expand AI"]
        XCTAssertTrue(expandButton.waitForExistence(timeout: 5))
        expandButton.tap()

        // Back to the embedded sidebar copy — "Minimize" only ever appears there, never on the
        // floating/detached copy (see `testAIPanelIsDetachedNotEmbeddedWhileTheCameraViewIsRunning`).
        XCTAssertTrue(app.buttons["Minimize"].waitForExistence(timeout: 5))
    }

    func testGalleryTileOpensTheGalleryPage() throws {
        let app = makeApp()
        app.launch()

        let galleryTile = app.buttons["DashboardGalleryTile"]
        XCTAssertTrue(galleryTile.waitForExistence(timeout: 10))
        galleryTile.tap()

        // `GalleryView`'s own empty-state copy — unique to that page, present on a fresh install
        // with nothing post-processed yet.
        XCTAssertTrue(app.staticTexts["Post-process a capture — or send one to Siril, GraXpert, or StarNet — and it shows up here."]
            .waitForExistence(timeout: 10))
    }

    /// Same "scroll the horizontal Common Tasks row into view before tapping" reasoning as
    /// `testInsightsTileOpensTheInsightsPage` — "Equipment" has no accessibility identifier of its
    /// own (unlike Quick Start/All Projects/Gallery/Insights), so this matches by label instead,
    /// still scoped to a button inside the known tile row to avoid matching some other "Equipment"
    /// label elsewhere on the page.
    func testEquipmentTileOpensTheEquipmentPage() throws {
        let app = makeApp()
        app.launch()

        let equipmentTile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Equipment")).firstMatch
        XCTAssertTrue(equipmentTile.waitForExistence(timeout: 10))
        let commonTasksScroll = app.scrollViews["CommonTasksScrollView"]
        scrollCommonTasksTileIntoViewAndTap(equipmentTile, within: commonTasksScroll)

        // `EquipmentPage`'s own empty-state title — unique to that page, present with no
        // equipment systems set up yet.
        XCTAssertTrue(app.staticTexts["No Equipment Systems Yet"].waitForExistence(timeout: 10))
    }

    func testNewProjectTileOpensAndCancelsTheNewProjectSheet() throws {
        let app = makeApp()
        app.launch()

        let newProjectTile = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "New Project")).firstMatch
        XCTAssertTrue(newProjectTile.waitForExistence(timeout: 10))
        newProjectTile.tap()

        // `NewProjectSheet`'s own headline, plus its "Create" button starts disabled until a name
        // is typed — confirms the sheet actually opened rather than the tap silently doing nothing.
        XCTAssertTrue(app.staticTexts["New Project"].waitForExistence(timeout: 10))
        let createButton = app.buttons["Create"]
        XCTAssertTrue(createButton.exists)
        XCTAssertFalse(createButton.isEnabled)

        app.buttons["Cancel"].tap()

        // Cancelling closes the sheet without creating anything — back to the Dashboard.
        XCTAssertTrue(app.staticTexts["Common Tasks"].waitForExistence(timeout: 10))
    }

    func testSettingsDoneButtonReturnsToTheUnderlyingView() throws {
        let app = makeApp()
        app.launch()

        let candidates = app.buttons.matching(identifier: "DashboardSettingsToolbarButton")
        XCTAssertTrue(candidates.firstMatch.waitForExistence(timeout: 10))
        let deadline = Date().addingTimeInterval(10)
        var settingsButton: XCUIElement?
        while settingsButton == nil && Date() < deadline {
            settingsButton = candidates.allElementsBoundByIndex.first(where: \.isHittable)
            if settingsButton == nil { Thread.sleep(forTimeInterval: 0.2) }
        }
        try XCTUnwrap(settingsButton, "No hittable DashboardSettingsToolbarButton found").tap()
        XCTAssertTrue(app.staticTexts["Projects Folder"].waitForExistence(timeout: 10))

        app.buttons["Done"].tap()

        // Back at the Dashboard underneath — settled, not just "the sheet's gone."
        XCTAssertTrue(app.staticTexts["Common Tasks"].waitForExistence(timeout: 10))
    }

    /// End-to-end session lifecycle: Quick Start → an active camera session → "End Session" →
    /// the resulting project shows up back on the Dashboard's own "Recent Projects" row → opening
    /// it lands on that project's own detail page. Exercises the full round trip a real user
    /// takes, not just one hop of it.
    func testEndingASessionReturnsToTheDashboardAndTheProjectAppearsInRecents() throws {
        let app = makeApp()
        launchIntoCameraView(app)

        let endSessionButton = app.buttons["End Session"].firstMatch
        XCTAssertTrue(endSessionButton.waitForExistence(timeout: 10))
        endSessionButton.tap()

        XCTAssertTrue(app.staticTexts["Common Tasks"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Recent Projects"].waitForExistence(timeout: 10))

        let projectCard = app.staticTexts["Moon (Detail)"].firstMatch
        XCTAssertTrue(projectCard.waitForExistence(timeout: 10))
        projectCard.tap()

        // `ProjectDetailPane`'s own "Stats" section (includes the session count) — unique to that
        // page, confirms the tap actually navigated in rather than doing nothing.
        XCTAssertTrue(app.staticTexts["Stats"].waitForExistence(timeout: 10))
    }

}
