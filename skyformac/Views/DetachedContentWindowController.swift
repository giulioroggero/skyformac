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
        // `center()` alone centers on whichever screen AppKit picks for a window that's never
        // been shown — not necessarily the screen (or position) the presenting page is actually
        // on, e.g. a multi-monitor setup where the main window lives on a secondary display. "The
        // modal on top of the page" means visually over the window someone's actually looking at,
        // not just "somewhere on screen" — so this re-centers over the current key window's own
        // frame instead, clamped to stay fully on that window's screen.
        if let origin = Self.originCenteredOverKeyWindow(size: contentSize) {
            window.setFrameOrigin(origin)
        }
        // AppKit's default `isReleasedWhenClosed = true` deallocates the window as part of
        // `close()` itself — but `onClose()` below (called from the delegate callback `close()`
        // triggers, so still on that same call stack) is what drops this controller's own last
        // strong reference (the caller's `@State` var), and this controller *is* the window's
        // delegate. Letting AppKit release the window out from under itself mid-close, on the
        // same object that's also about to lose its own last reference, is exactly the kind of
        // reentrant-teardown situation that can leave a window not actually finishing its close
        // — "the Done button doesn't close the preview." `false` here means `close()` just hides/
        // orders out the window, no deallocation racing the delegate callback that's still using it.
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func originCenteredOverKeyWindow(size: NSSize) -> NSPoint? {
        guard let parent = NSApp.keyWindow, let screen = parent.screen ?? NSScreen.main else { return nil }
        let parentFrame = parent.frame
        var origin = NSPoint(x: parentFrame.midX - size.width / 2, y: parentFrame.midY - size.height / 2)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        return origin
    }

    /// Overridden (not just relying on every call site's own `showWindow(nil)`) so "on top of the
    /// page" is guaranteed regardless of what else is going on when this is opened — `NSWindow`
    /// ordering is scoped to the frontmost app, so a window can `makeKeyAndOrderFront` correctly
    /// and still not visually appear in front of another app that happens to be frontmost at that
    /// moment (unlikely mid-workflow inside this same app, but cheap insurance against it).
    override func showWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        // Deferred a tick — `onClose()` drops the caller's only strong reference to this
        // controller (see `isReleasedWhenClosed`'s own doc comment above), and this is itself
        // still running from inside the window's own `close()` call; letting that finish
        // unwinding first, before this object can be deallocated, is the same reasoning.
        DispatchQueue.main.async { [onClose] in onClose() }
    }
}
