import SwiftUI

/// Real macOS menu bar commands with keyboard shortcuts — export, camera connect/rescan, and
/// the toolbar toggles (Metal renderer, night mode, all-sky monitor), all discoverable through
/// the menu bar and usable without touching the mouse.
struct SkyformacCommands: Commands {
    var cameraManager: CameraManager

    // Same `@AppStorage` key `ControlsPanelView`'s own Mode picker reads/writes — this menu is a
    // second, independent path to the exact same state, not a separate concept. Added as a
    // mouse-free (and click-target-independent) fallback after the in-panel dropdown was reported
    // unresponsive to clicks; see `docs/design-notes.md`.
    @AppStorage("controlMode") private var mode: ControlMode = .general

    var body: some Commands {
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

        CommandMenu("Mode") {
            modeButton(.general, shortcut: "1")
            modeButton(.planetary, shortcut: "2")
            modeButton(.deepSky, shortcut: "3")
            modeButton(.all, shortcut: "4")
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
        }
    }

    @ViewBuilder
    private func modeButton(_ candidate: ControlMode, shortcut: KeyEquivalent) -> some View {
        Button {
            mode = candidate
        } label: {
            if mode == candidate {
                Label(candidate.rawValue, systemImage: "checkmark")
            } else {
                Text(candidate.rawValue)
            }
        }
        .keyboardShortcut(shortcut, modifiers: .command)
    }
}
