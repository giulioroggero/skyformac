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
    /// Owns the floating panel's lifetime while detached — `nil` whenever
    /// `cameraManager.isAssistantDetached` is `false`, created/closed in lockstep with it via the
    /// `.onChange` below, the same pattern this app doesn't otherwise need since
    /// `HistogramCurvesPanelController` is owned by `ContentView` instead (that one lives and
    /// dies with the camera view; the assistant needs to survive across both pages).
    @State private var detachedAssistantController: AssistantChatPanelController?
    /// Persisted like `ControlsPanelView`'s own sidebar-tab choice — a width the user drags to
    /// should stick across relaunches, not reset back to the default every time.
    @AppStorage("assistantPanelWidth") private var assistantPanelWidth: Double = 320

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if cameraManager.activeSession == nil {
                    // `ContentView` manages its own night-mode tint internally (deliberately
                    // excluding the live image) — applying it there too. Here at `RootView`
                    // level a blanket tint would be safe for `ProjectsBrowserView` (nothing
                    // exempt in it) but would also reach into `ContentView`'s `PreviewView` and
                    // tint the live image, so it's scoped to just this branch instead.
                    ProjectsBrowserView(cameraManager: cameraManager)
                        .nightModeTint(cameraManager)
                } else {
                    ContentView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // "A chat on the right bar of all pages" — sits alongside whichever of the two above
            // is showing, rather than being reimplemented per page, so it's one continuous
            // conversation regardless of where the user navigates. The `activeSession == nil`
            // check is a hard backstop for "in camera mode the AI is only detached" — `CameraManager
            // .syncAssistantDockStateForCameraMode()` already forces `isAssistantDetached` true the
            // moment a session starts, but this guarantees the sidebar copy never renders even if
            // that state were ever somehow out of sync.
            if cameraManager.isAssistantPanelVisible && !cameraManager.isAssistantDetached && cameraManager.activeSession == nil {
                if cameraManager.isAssistantMinimized {
                    Divider()
                    AssistantMinimizedRail(cameraManager: cameraManager)
                        .nightModeTint(cameraManager)
                } else {
                    AssistantResizeHandle(width: $assistantPanelWidth)
                    AssistantChatPanel(cameraManager: cameraManager)
                        .frame(width: assistantPanelWidth)
                        .nightModeTint(cameraManager)
                }
            }
        }
        // Attached here, not on `ContentView`/`ProjectsBrowserView` individually, so "skyformac →
        // Show Log…" works no matter which of the two is currently showing.
        .sheet(isPresented: Binding(
            get: { cameraManager.isLogViewerPresented },
            set: { cameraManager.isLogViewerPresented = $0 }
        )) {
            LogViewerView()
                .nightModeTint(cameraManager)
        }
        // Same "works no matter which of the two is currently showing" reasoning as the log
        // sheet above — Recall Parameters is useful both from the Session page (before running)
        // and the live camera view (mid-session), and Settings from either as well.
        .sheet(isPresented: Binding(
            get: { cameraManager.isRecallParametersPresented },
            set: { cameraManager.isRecallParametersPresented = $0 }
        )) {
            RecallParametersView(cameraManager: cameraManager)
                .nightModeTint(cameraManager)
        }
        .sheet(isPresented: Binding(
            get: { cameraManager.isSettingsPresented },
            set: { cameraManager.isSettingsPresented = $0 }
        )) {
            SettingsView(cameraManager: cameraManager)
                .nightModeTint(cameraManager)
        }
        // Watches the combination, not just `isAssistantDetached` alone — pressing the detached
        // panel's own Close button sets `isAssistantPanelVisible = false` while leaving
        // `isAssistantDetached` untouched, and without this the floating `NSPanel` would have
        // nothing left to actually close it.
        .onChange(of: cameraManager.isAssistantPanelVisible && cameraManager.isAssistantDetached) { _, shouldShowDetached in
            if shouldShowDetached {
                let controller = AssistantChatPanelController(cameraManager: cameraManager) {
                    cameraManager.isAssistantDetached = false
                }
                controller.showWindow(nil)
                detachedAssistantController = controller
            } else {
                detachedAssistantController?.close()
                detachedAssistantController = nil
            }
        }
    }
}
