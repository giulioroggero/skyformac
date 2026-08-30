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
        // second entry in the Window menu/Mission Control to manage. `RootView` swaps between the
        // Projects browser and `ContentView` in place, in this same window, for the same reason.
        // Explicit `id` (not the no-`id` default) so `SkyTonightMenuBarView` can target this
        // exact scene with `openWindow(id: "main")` when the menu bar's "Open Skyformac…" finds
        // zero windows open — `OpenWindowAction` on this SDK requires an `id`/`value` argument,
        // there's no bare no-argument overload to fall back on.
        WindowGroup(id: "main") {
            RootView()
                .environment(cameraManager)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            SkyformacCommands(cameraManager: cameraManager)
        }

        // "Should I even go out tonight" at a glance, without opening the main window — see
        // `SkyTonightMenuBarView`'s own doc comment. `.window` style (not `.menu`) since this
        // shows real content (a status line, a planned-object list), not just a row of commands.
        MenuBarExtra("Sky Tonight", systemImage: "sparkles") {
            SkyTonightMenuBarView(cameraManager: cameraManager)
        }
        .menuBarExtraStyle(.window)
    }
}
