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
    /// True for a short fixed stretch right after launch — see `LaunchSplashView`'s own doc
    /// comment for why this is a fixed duration rather than gated on real loading finishing
    /// (`CameraManager`'s startup work is already done, synchronously, by the time this view's
    /// `body` even runs the first time). Starts `false` under `AppSettings.isRunningUITests` —
    /// the splash sits on top in the `ZStack` and, for its whole fixed duration, actually
    /// intercepts hit-testing the same way any topmost view would (unlike the accessibility tree,
    /// which still exposes the covered content underneath) — a UI test tapping a tile the instant
    /// it finds it in the accessibility hierarchy, well before the splash's timer clears it, had
    /// its synthesized click silently swallowed by the splash instead of reaching the real
    /// button. Every other timing-sensitive one-time-on-launch affordance in this app is already
    /// skipped the same way under UI tests, for the same reason.
    @State private var isShowingSplash = !AppSettings.isRunningUITests

    var body: some View {
        ZStack {
            mainContent
            if isShowingSplash {
                LaunchSplashView()
                    .transition(.opacity)
            }
        }
        .task {
            guard isShowingSplash else { return }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.4)) { isShowingSplash = false }
        }
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            Group {
                if cameraManager.activeSession == nil {
                    // Deliberately NOT `.nightModeTint`ed, unlike most other top-level pages —
                    // this whole browsing hierarchy (`DashboardHomeView`, `ProjectDetailPane`,
                    // `SessionDetailPane`, `CaptureDetailPage`, the Observation Timeline) is full
                    // of actual capture thumbnails/previews, not just chrome. A blanket tint here
                    // once red-multiplied every one of them — real astrophotos rendering solid
                    // red while reviewing past sessions, not just the surrounding UI (reported as
                    // "the capture become red"). `.colorMultiply` has no per-descendant "opt out"
                    // (unlike `PreviewView`'s live image, which is simply never placed under a
                    // tinted ancestor in the first place) — retinting only this hierarchy's own
                    // chrome would need tint applied section-by-section throughout every one of
                    // those views, not one modifier here, so for now this page just stays
                    // untinted rather than risk the same bug again.
                    ProjectsBrowserView(cameraManager: cameraManager)
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
