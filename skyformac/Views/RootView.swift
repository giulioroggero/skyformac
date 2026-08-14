import SwiftUI

/// The app's actual root content — swapped in place inside `SkyformacApp`'s one `WindowGroup`
/// (this app stays single-window; see its doc comment), never a second window. Mirrors the
/// project → session → session execution hierarchy: browsing projects and their sessions (even
/// with a project "open" as context) all happens in the Projects browser; the camera
/// `ContentView` — a session's actual *execution* — only shows once a specific session is
/// running. `CameraManager.activeSession` is the one gate: set by clicking a not-yet-run session
/// or "Run This Session" in the browser, cleared by "End Session"/"Switch Project"/deleting it.
struct RootView: View {
    @Environment(CameraManager.self) private var cameraManager

    var body: some View {
        Group {
            if cameraManager.activeSession == nil {
                ProjectsBrowserView(cameraManager: cameraManager)
            } else {
                ContentView()
            }
        }
        // Attached here, not on `ContentView`/`ProjectsBrowserView` individually, so "skyformac →
        // Show Log…" works no matter which of the two is currently showing.
        .sheet(isPresented: Binding(
            get: { cameraManager.isLogViewerPresented },
            set: { cameraManager.isLogViewerPresented = $0 }
        )) {
            LogViewerView()
        }
    }
}
