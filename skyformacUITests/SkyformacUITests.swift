import XCTest

/// UI-level automated tests driving the real SwiftUI view tree via the Accessibility API
/// (XCUITest), not just the underlying logic — a gap the 100 `skyformacTests` unit tests don't
/// cover, since those never touch a live view hierarchy.
final class SkyformacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsCameraSidebar() throws {
        let app = XCUIApplication()
        app.launch()

        // "Cameras" is the sidebar section header from CameraListView.
        XCTAssertTrue(app.staticTexts["Cameras"].waitForExistence(timeout: 10))
    }

    func testToolbarRendererToggleExists() throws {
        let app = XCUIApplication()
        app.launch()

        // Label reads "GPU"/"CPU" depending on the current render path, so the test targets the
        // stable accessibility identifier rather than the (state-dependent) display text.
        XCTAssertTrue(app.checkBoxes["RenderPathToggle"].waitForExistence(timeout: 10)
            || app.buttons["RenderPathToggle"].waitForExistence(timeout: 1))
    }

}
