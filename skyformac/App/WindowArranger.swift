import AppKit

/// "Window → Tile Windows"/"Cascade Windows" — arranges every one of Skyformac's own real,
/// independently-movable/resizable windows (the main window plus however many of Planetary
/// Post-Processing/Edit Image/the full-screen preview happen to be open at once via
/// `DetachedContentWindowController`) the way a multi-window code editor's own Window menu does,
/// rather than leaving the user to drag each one into place by hand. macOS itself has no built-in
/// per-app "tile all my windows" command (only per-window "Move & Resize" and the system-wide,
/// Dock-icon-context-menu "Tile Windows" that arranges windows from *every* app together, not
/// just this one) — this is Skyformac's own equivalent, scoped to this app's windows only.
@MainActor
enum WindowArranger {
    /// Every window worth arranging — excludes `NSPanel`s (`HistogramCurvesPanelController`/
    /// `AssistantChatPanelController`, both deliberately floating accessories someone glances at
    /// while working elsewhere, not primary content to tile/cascade alongside) and anything not
    /// currently visible (a closed/minimized window has no on-screen position to arrange).
    private static func arrangeableWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible && !window.isMiniaturized && !(window is NSPanel)
        }
    }

    /// Splits the main screen's visible area into an even grid (as square as the window count
    /// allows) and gives each window its own cell — the same "no window overlaps another" idea a
    /// code editor's own "Tile Windows" offers when you've got several files open side by side.
    static func tileWindows() {
        let windows = arrangeableWindows()
        guard !windows.isEmpty, let screen = windows.first?.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let columns = Int(ceil(sqrt(Double(windows.count))))
        let rows = Int(ceil(Double(windows.count) / Double(columns)))
        let cellWidth = visible.width / CGFloat(columns)
        let cellHeight = visible.height / CGFloat(rows)
        for (index, window) in windows.enumerated() {
            let column = index % columns
            let row = index / columns
            let frame = NSRect(
                x: visible.minX + CGFloat(column) * cellWidth,
                y: visible.maxY - CGFloat(row + 1) * cellHeight,
                width: cellWidth, height: cellHeight
            )
            window.setFrame(frame, display: true, animate: true)
        }
    }

    /// `NSWindow.cascadeTopLeft(from:)` is the same primitive AppKit itself uses for a fresh
    /// document window's own default offset-from-the-last-one placement — feeding each window's
    /// own returned point into the next call is what produces the diagonal stagger, rather than
    /// hand-rolling the offset math.
    static func cascadeWindows() {
        let windows = arrangeableWindows()
        guard !windows.isEmpty else { return }
        var topLeft = NSPoint.zero
        for window in windows {
            window.setIsVisible(true)
            topLeft = window.cascadeTopLeft(from: topLeft)
        }
    }
}
