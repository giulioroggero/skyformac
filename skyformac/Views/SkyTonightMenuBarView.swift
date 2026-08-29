import AppKit
import SwiftUI

/// "Should I even go out tonight" — a menu-bar item (`MenuBarExtra`, wired up in `SkyformacApp`)
/// that's checkable without opening the app's own main window at all, the same "glance and know"
/// convenience a dedicated always-there status item gives over a page you have to navigate to.
struct SkyTonightMenuBarView: View {
    var cameraManager: CameraManager

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
            Button("Open Skyformac…") { NSApp.activate(ignoringOtherApps: true) }
            Button("Quit Skyformac") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 280)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
