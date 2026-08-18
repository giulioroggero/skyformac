import AppKit
import SwiftUI

/// Hosts `HistogramView`/`CurvesView` in a real floating `NSPanel` when the user detaches them
/// from the main window (`ContentView`'s "Detach" button, next to the tabs) — a plain AppKit
/// panel the app opens/closes itself, not a second SwiftUI `Window` scene, on purpose:
/// `SkyformacApp`'s doc comment is explicit that this app is single-`Scene` (no second
/// Window-menu entry, no window-tabbing surface). A panel doesn't add a scene at all, so that
/// constraint holds regardless of whether one happens to be open.
///
/// `.utilityWindow` + `.nonactivatingPanel` gives the "float above the main window, can overlap
/// it, click-through doesn't steal focus" behavior a detached tool palette is expected to have —
/// the same style macOS's own Xcode/Photos-style inspector panels use. Closing it (the panel's
/// own close button, or the "Dock" button `ContentView` shows once detached) re-docks the tabs
/// inline via `onClose`, rather than leaving a permanently-closed floating panel with no way back.
final class HistogramCurvesPanelController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(cameraManager: CameraManager, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Histogram & Curves"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DetachedHistogramCurvesView(cameraManager: cameraManager))
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

/// The floating panel's actual SwiftUI content — a thin wrapper (rather than handing
/// `NSHostingView` the `TabView` directly) so `useMetalRenderer` is read fresh from
/// `cameraManager` inside this view's own `body` on every SwiftUI re-render, the same way
/// `ContentView` reads it, instead of being frozen at whatever it was when the panel opened.
/// `@Observable` invalidation flows through `NSHostingView` normally either way — this wrapper
/// exists for that freshness, not to work around some interop gap.
private struct DetachedHistogramCurvesView: View {
    var cameraManager: CameraManager

    var body: some View {
        TabView {
            HistogramView(cameraManager: cameraManager, useMetalRenderer: cameraManager.useMetalRenderer)
                .tabItem { Text("Histogram") }
            CurvesView(cameraManager: cameraManager)
                .tabItem { Text("Curves") }
            StackingStatusView(cameraManager: cameraManager)
                .tabItem { Text("Stacking") }
        }
        .nightModeTint(cameraManager)
        .frame(minWidth: 340, idealWidth: 380, minHeight: 360, idealHeight: 420)
        .padding(.top, 4)
    }
}
