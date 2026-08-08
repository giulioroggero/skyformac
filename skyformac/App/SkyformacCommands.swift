import SwiftUI

/// Real macOS menu bar commands with keyboard shortcuts — export, camera connect/rescan, and
/// the toolbar toggles (Metal renderer, night mode, all-sky monitor), all discoverable through
/// the menu bar and usable without touching the mouse.
struct SkyformacCommands: Commands {
    var cameraManager: CameraManager

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
}
