import AppKit
import SwiftUI

/// Hosts `AssistantChatPanel` in a real floating `NSPanel` when the user detaches it from the
/// main window — the exact same "utility panel the app opens/closes itself, not a second SwiftUI
/// `Window` scene" approach `HistogramCurvesPanelController` already established for the
/// Histogram/Curves tabs, reused here rather than inventing a second detach mechanism.
/// `SkyformacApp`'s single-`Scene` design is unaffected either way — a panel never adds one.
final class AssistantChatPanelController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(cameraManager: CameraManager, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Assistant"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: AssistantChatPanel(cameraManager: cameraManager, isDetachedWindow: true))
        panel.minSize = NSSize(width: 280, height: 320)
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
