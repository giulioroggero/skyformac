import AppKit
import SwiftUI

@main
struct SkyformacApp: App {
    @State private var cameraManager = CameraManager()

    init() {
        // `WindowGroup` opts into native macOS window tabbing by default — the "+" button and
        // horizontal tab bar the title bar shows once more than one window of the same scene
        // could exist, letting a user open a second tab/window of this exact scene. That's a
        // second entry point to more windows independent of Help's own `Window` scene (already
        // removed) — this app is meant to be single-window, full stop, so tabbing needs
        // disabling explicitly; `WindowGroup` doesn't have its own SwiftUI-level opt-out.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        // Single-window app on purpose — Help is a `.sheet` on `ContentView` (driven by
        // `cameraManager.isHelpPresented`), not a second `Window` scene, so there's never a
        // second entry in the Window menu/Mission Control to manage.
        WindowGroup {
            ContentView()
                .environment(cameraManager)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            SkyformacCommands(cameraManager: cameraManager)
        }
    }
}
