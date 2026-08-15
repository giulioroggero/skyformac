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
        // "skyformac → Show Log…" — right after "About skyformac," in the app's own first menu,
        // since grabbing the log is exactly the kind of thing someone reporting a problem looks
        // for right where "About"/version info already lives.
        CommandGroup(after: .appInfo) {
            Button("Show Log…") { cameraManager.isLogViewerPresented = true }
                .keyboardShortcut("d", modifiers: [.command, .shift])
        }

        // The standard macOS "Settings…" placement/shortcut (⌘,) — a `.sheet` on `RootView`
        // (`SettingsView`), not a real `Settings` scene, matching every other modal this
        // deliberately single-window app already uses instead of a second window.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { cameraManager.isSettingsPresented = true }
                .keyboardShortcut(",", modifiers: .command)
        }

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

            Divider()

            // Packages/unpacks a whole project folder as one file — "share projects across
            // users" — distinct from Export above, which is about a single captured frame.
            Button("Save As Project…") { cameraManager.saveActiveProjectAsFile() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(cameraManager.activeProject == nil)
            Button("Load Project…") { cameraManager.loadProjectFromFile() }
                .keyboardShortcut("o", modifiers: [.command, .option])
        }

        // Both this and "Sidebar Tab" below only make sense while the camera view is actually
        // showing — "Rescan Cameras," a render-path toggle, or a sidebar-tab shortcut are all
        // meaningless (and were previously just always enabled) when the window is showing the
        // Projects browser instead. `@CommandsBuilder` supports `if`, the same as `@ViewBuilder`,
        // so this removes the whole menu from the menu bar rather than merely disabling its items.
        if cameraManager.activeSession != nil {
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

                Divider()

                Button("Acquisition Wizard…") { cameraManager.isAcquisitionWizardPresented = true }
                    .keyboardShortcut("w", modifiers: [.command, .shift])

                // Save/Load work standalone, without the Wizard sheet open at all — the Wizard is
                // where you'd go to pick a *target*'s recommended setup; these two are for a setup
                // you already have dialed in (or a preset file you already know you want).
                Button("Save Current Setup as Preset…") { cameraManager.saveCurrentSetupAsPreset() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(cameraManager.connectedCamera == nil)
                Button("Load Preset…") { cameraManager.loadAndApplyAcquisitionPreset() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(cameraManager.connectedCamera == nil)
            }
        }

        // Every project/session management action in one place — creating, opening, navigating,
        // and tearing down, rather than split across the File menu and a separate "Session" menu.
        CommandMenu("Project") {
            Button("New Project…") { cameraManager.newProject() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Quick Start…") { cameraManager.requestQuickStart() }
                .keyboardShortcut("u", modifiers: .command)
            Button("Show All Projects") { cameraManager.showAllProjects() }
            Button("Go Home") { cameraManager.setActive(project: nil, session: nil) }
                .keyboardShortcut("h", modifiers: [.command, .shift])

            Divider()

            Button("Open Project Page") { cameraManager.showProjectDetail() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(cameraManager.activeProject == nil)

            Divider()

            Button("End Session") { cameraManager.endActiveSession() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(cameraManager.activeSession == nil)
            Button("Open Previous Session") { cameraManager.openPreviousSession() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
                .disabled(!cameraManager.hasPreviousSession)
            Button("Open Next Session") { cameraManager.openNextSession() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                .disabled(!cameraManager.hasNextSession)
            Button("New Session in Project") { cameraManager.createSessionInActiveProject() }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(cameraManager.activeProject == nil)
            Button("Delete This Session") { cameraManager.deleteActiveSession() }
                .disabled(cameraManager.activeSession == nil)

            Divider()

            Button("Recall Parameters…") { cameraManager.isRecallParametersPresented = true }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Equipment") {
            Button("View") { cameraManager.showEquipmentList() }
                .keyboardShortcut("e", modifiers: [.command, .control])
            Button("Add New…") { cameraManager.showAddNewEquipment() }
                .keyboardShortcut("e", modifiers: [.command, .control, .shift])
        }

        if cameraManager.activeSession != nil {
            CommandMenu("Sidebar Tab") {
                tabButton(.cameraControls, shortcut: "1")
                tabButton(.improvements, shortcut: "2")
                tabButton(.planetary, shortcut: "3")
                tabButton(.deepSky, shortcut: "4")
            }
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

            // Reopens the sidebar assistant if it's been closed — `isAssistantMinimized`/
            // `isAssistantDetached` don't need their own menu items, since both already have an
            // always-visible way back (the minimized rail's expand button, the floating panel's
            // own Dock button).
            Toggle("AI", isOn: Binding(
                get: { cameraManager.isAssistantPanelVisible },
                set: { cameraManager.isAssistantPanelVisible = $0 }
            ))
            .keyboardShortcut("j", modifiers: [.command, .shift])
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
