import AppKit
import SwiftUI

/// "Should I even go out tonight" — a menu-bar item (`MenuBarExtra`, wired up in `SkyformacApp`)
/// that's checkable without opening the app's own main window at all, the same "glance and know"
/// convenience a dedicated always-there status item gives over a page you have to navigate to.
struct SkyTonightMenuBarView: View {
    var cameraManager: CameraManager
    @Environment(\.openWindow) private var openWindow

    private var plannedObjectNames: [String] {
        cameraManager.projectsLibrary.activeProjects.flatMap(\.sessions).flatMap(\.plannedObjects)
    }

    private var status: SkyTonightCalculator.Status {
        SkyTonightCalculator.status(location: cameraManager.locationProvider.lastLocation, plannedObjectNames: plannedObjectNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.location == nil {
                Label("No location set — open Skyformac to set one.", systemImage: "location.slash")
                    .font(.callout)
            } else {
                Label(status.isWorthGoingOut ? "Worth going out tonight" : "Nothing planned clears the horizon tonight", systemImage: status.isWorthGoingOut ? "checkmark.circle.fill" : "moon.zzz")
                    .font(.headline)
                    .foregroundStyle(status.isWorthGoingOut ? .green : .secondary)

                if let window = status.nightWindow {
                    Text("Dark from \(Self.timeFormatter.string(from: window.start)) to \(Self.timeFormatter.string(from: window.end)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No real astronomical darkness tonight from this location.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text("Moon: \(status.moonPhase.phaseName) (\(Int(status.moonPhase.illuminatedFraction * 100))% illuminated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !status.visiblePlannedObjects.isEmpty {
                    Divider()
                    Text("Planned objects clearing the horizon tonight:").font(.caption).bold()
                    ForEach(status.visiblePlannedObjects, id: \.name) { entry in
                        Text("\(entry.name) — peaks at \(Int(entry.maxAltitudeDegrees))°").font(.caption)
                    }
                }
            }
            Divider()
            Button("Open Skyformac…") { openMainWindow() }
            Button("Quit Skyformac") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
    }

    /// `NSApp.activate` alone only brings an already-open window forward — closing the main
    /// window doesn't quit this app (no window-count-based termination), so it's entirely
    /// possible to have zero windows open (every detached one — Post-Processing, Edit Image —
    /// closed too) with the app still running. In that case activation alone shows nothing at
    /// all; `openWindow()` asks SwiftUI for a fresh instance of the app's one `WindowGroup`, which
    /// lands back on `ContentView` (the camera/capture screen) rather than the Projects browser
    /// whenever `CameraManager.activeSession` is still set — exactly "go back to the capture" for
    /// a session that was mid-run when every window happened to close.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if !cameraManager.isMainWindowVisible {
            openWindow(id: "main")
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
