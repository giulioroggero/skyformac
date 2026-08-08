import XCTest

/// UI-level automated tests driving the real SwiftUI view tree via the Accessibility API
/// (XCUITest), not just the underlying logic — a gap the 100 `MacZWOTests` unit tests don't
/// cover, since those never touch a live view hierarchy.
final class MacZWOUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAppLaunchesAndShowsCameraSidebar() throws {
        let app = XCUIApplication()
        app.launch()

        // "Cameras" is the sidebar section header from CameraListView.
        XCTAssertTrue(app.staticTexts["Cameras"].waitForExistence(timeout: 10))
    }

    func testSimulateMonoButtonAppearsWithNoHardware() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.buttons["Simulate Mono"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Simulate Color"].exists)
    }

    func testToolbarRendererToggleExists() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.checkBoxes["Metal Renderer"].waitForExistence(timeout: 10)
            || app.buttons["Metal Renderer"].waitForExistence(timeout: 1))
    }

    func testSimulatingAPatternShowsStreamingStatus() throws {
        let app = XCUIApplication()
        app.launch()

        let simulateButton = app.buttons["Simulate Mono"]
        XCTAssertTrue(simulateButton.waitForExistence(timeout: 10))
        simulateButton.click()

        XCTAssertTrue(app.staticTexts["Streaming"].waitForExistence(timeout: 10))
    }
}
