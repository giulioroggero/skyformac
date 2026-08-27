import AppKit
import SwiftUI

/// Hosts any SwiftUI view in a real, independently movable/resizable `NSWindow` — what
/// Planetary Post-Processing, Edit Image, and the full-screen image viewer all now open into
/// instead of a `.sheet`. A macOS sheet is permanently attached below its parent window's own
/// title bar; it can never be dragged to another position on screen or freely resized past what
/// the presenting view declares — that's an OS-level property of sheet presentation itself, not
/// an app-level setting to flip, so "the edit/preview windows can be moved across the screen and
/// resized" means using a genuinely separate window instead. Plain `NSWindowController` (not a
/// SwiftUI second `Window`/`WindowGroup` scene) for the same reason `HistogramCurvesPanelController`/
/// `AssistantChatPanelController` already are — `SkyformacApp`'s single-`Scene` design stays
/// true regardless of how many of these happen to be open, since a manually-managed window never
/// adds a scene at all. Unlike those two (both `.nonactivatingPanel` tool palettes a user glances
/// at while working elsewhere), this is a normal, activating, titled/closable/resizable/
/// miniaturizable window — Post-Processing/Edit Image/the image preview are primary workflows
/// someone works *in*, not a floating accessory.
final class DetachedContentWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    /// `content`'s generic `Content` only needs to be known inside this initializer (to build the
    /// `NSHostingView`) — the controller itself stays a plain, non-generic class, so every call
    /// site can share one common `@State private var ...: DetachedContentWindowController?`
    /// storage type regardless of which SwiftUI view it's actually hosting.
    init<Content: View>(
        title: String, contentSize: NSSize, minSize: NSSize, onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = NSHostingView(rootView: content())
        window.minSize = minSize
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
