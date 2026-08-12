import SwiftUI

/// Real macOS menu bar commands with keyboard shortcuts — export, camera connect/rescan, and
/// the toolbar toggles (Metal renderer, night mode, all-sky monitor), all discoverable through
/// the menu bar and usable without touching the mouse.
struct SkyformacCommands: Commands {
    var cameraManager: CameraManager

    // Same `@AppStorage` key `ControlsPanelView`'s own sidebar tab picker reads/writes — this
    // menu is a second, independent path to the exact same state, not a separate concept. Added
    // as a mouse-free (and click-target-independent) fallback after the in-panel dropdown was
    // reported unresponsive to clicks; see `docs/design-notes.md`.
    @AppStorage("sidebarTab") private var tab: SidebarTab = .cameraControls

    var body: some Commands {
        // Replaces the default (otherwise inert, since this app ships no Apple Help Book)
        // "skyformac Help" menu item with one that actually opens something — a `.sheet` on
        // `ContentView`, not a second `Window` scene, since this app is deliberately
        // single-window (see `SkyformacApp`).
        CommandGroup(replacing: .help) {
            Button("skyformac Help") { cameraManager.isHelpPresented = true }
                .keyboardShortcut("?", modifiers: .command)
        }

        // Removes the default "New Window" (⌘N) item — `WindowGroup` provides one automatically,
        // but this app is deliberately single-window (see `SkyformacApp`'s doc comment); a
        // second window of the same scene is exactly what that's trying to prevent.
        CommandGroup(replacing: .newItem) {}

        CommandGroup(after: .newItem) {
            Divider()
            Button("Export as FITS…") { cameraManager.exportCurrentFrame(as: .fits) }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(cameraManager.currentFrame == nil)
            Button("Export as PNG…") { cameraManager.exportCurrentFrame(as: .png) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(cameraManager.currentFrame == nil)
        }

        CommandMenu("Camera") {
            Button("Rescan Cameras") { cameraManager.refreshCameraList() }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            if cameraManager.connectedCamera != nil {
                Button("Disconnect") { cameraManager.disconnect() }
                    .keyboardShortcut("k", modifiers: .command)
            } else {
                Button("Connect to First Available") {
                    guard let camera = cameraManager.availableCameras.first else { return }
                    Task { await cameraManager.connect(to: camera) }
                }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(cameraManager.availableCameras.isEmpty)
            }
        }

        CommandMenu("Sidebar Tab") {
            tabButton(.cameraControls, shortcut: "1")
            tabButton(.improvements, shortcut: "2")
            tabButton(.planetary, shortcut: "3")
            tabButton(.deepSky, shortcut: "4")
        }

        CommandGroup(after: .toolbar) {
            Toggle("Metal Renderer", isOn: Binding(
                get: { cameraManager.useMetalRenderer },
                set: { cameraManager.useMetalRenderer = $0 }
            ))
            .keyboardShortcut("m", modifiers: .command)

            Toggle("Night Mode", isOn: Binding(
                get: { cameraManager.isNightModeEnabled },
                set: { cameraManager.isNightModeEnabled = $0 }
            ))
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Toggle("All-Sky Monitor", isOn: Binding(
                get: { cameraManager.isAllSkyMonitorVisible },
                set: { cameraManager.isAllSkyMonitorVisible = $0 }
            ))
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Toggle("Full Screen Preview", isOn: Binding(
                get: { cameraManager.isPreviewFullScreenEnabled },
                set: { cameraManager.isPreviewFullScreenEnabled = $0 }
            ))
            .keyboardShortcut("f", modifiers: [.command, .shift])

            // The native sidebar-toggle button was reported to have no way back once the
            // Cameras sidebar was collapsed — this is an independent path to the exact same
            // `NavigationSplitView` `columnVisibility` state (see `CameraManager
            // .isCameraListSidebarVisible`'s doc comment), so there's always a way back
            // regardless of whatever's wrong with that button.
            Toggle("Camera List Sidebar", isOn: Binding(
                get: { cameraManager.isCameraListSidebarVisible },
                set: { cameraManager.isCameraListSidebarVisible = $0 }
            ))
            .keyboardShortcut("s", modifiers: [.command, .control])
        }
    }

    @ViewBuilder
    private func tabButton(_ candidate: SidebarTab, shortcut: KeyEquivalent) -> some View {
        Button {
            tab = candidate
        } label: {
            if tab == candidate {
                Label(candidate.rawValue, systemImage: "checkmark")
            } else {
                Text(candidate.rawValue)
            }
        }
        .keyboardShortcut(shortcut, modifiers: .command)
    }
}
