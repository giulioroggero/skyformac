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

    /// This app's main window is the Projects browser whenever no session is running — the camera
    /// view (and its "Cameras" sidebar) only appears once a session is actually active. Quick
    /// Start is the fastest way there: it creates a throwaway project/session for a curated target
    /// and switches straight into the camera view (`RootView` swaps views the moment
    /// `CameraManager.activeSession` becomes non-`nil`), so tests that need the camera view use it
    /// rather than assuming it's what launch shows.
    private func launchIntoCameraView(_ app: XCUIApplication) {
        app.launch()
        app.buttons["Quick Start…"].tap()
        // Each Quick Start row's accessibility label is its whole custom `Button` label (name +
        // icon + summary text concatenated), not just the target's name — matched by prefix
        // rather than substring, since the Home page's own "Quick Start" tile (still in the
        // accessibility tree behind the sheet) mentions "the Moon" too in its own subtitle.
        let moonRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Moon (Detail)")).firstMatch
        XCTAssertTrue(moonRow.waitForExistence(timeout: 5))
        moonRow.tap()
    }

    func testAppLaunchesIntoTheProjectsBrowser() throws {
        let app = XCUIApplication()
        app.launch()

        // "Quick Start…" is the Home page's own toolbar button — present only when showing the
        // Projects browser, not the camera view.
        XCTAssertTrue(app.buttons["Quick Start…"].waitForExistence(timeout: 10))
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

}
