import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Native pinch/scroll-wheel zoom and pan, via an `NSScrollView` hosting an `NSImageView` —
/// SwiftUI has no built-in equivalent on macOS, and `NSScrollView.allowsMagnification` is the
/// same mechanism Preview.app/Finder's own Quick Look already use, rather than hand-rolling
/// `MagnificationGesture`/`DragGesture` math.
/// Exposes explicit zoom controls (header buttons, not just the pinch/scroll gestures
/// `NSScrollView.allowsMagnification` already gives for free) by holding onto the live
/// `NSScrollView` `ZoomableImageView` creates — a plain reference type rather than `@State`,
/// since `ZoomableImageView` itself is recreated by SwiftUI but this needs to keep driving
/// whichever `NSScrollView` is currently on screen.
@MainActor
final class ImageZoomController {
    fileprivate weak var scrollView: NSScrollView?
    fileprivate var imageSize: CGSize = .zero

    func zoomIn() { step(by: 1.4) }
    func zoomOut() { step(by: 1 / 1.4) }

    /// Re-fits the whole image in the visible area — the same thing `ZoomableImageView` already
    /// does automatically the moment it first appears, just re-triggerable on demand once the
    /// user has zoomed/panned away from it.
    func zoomToFit() {
        guard let scrollView, imageSize.width > 0, imageSize.height > 0 else { return }
        scrollView.animator().magnify(toFit: NSRect(origin: .zero, size: imageSize))
        Self.center(scrollView)
    }

    /// `NSScrollView.magnify(toFit:)` zooms so the given rect fills the frame, but doesn't
    /// guarantee the scroll position lands centered — for an image whose fitted aspect ratio
    /// doesn't exactly match the viewport's, it can leave the image sitting off to one edge
    /// instead of in the middle. Called right after every fit (initial open, "Fit to Window") to
    /// make "centered" actually true rather than incidental.
    fileprivate static func center(_ scrollView: NSScrollView) {
        guard let documentView = scrollView.documentView else { return }
        let clipBounds = scrollView.contentView.bounds
        let docFrame = documentView.frame
        let centeredOrigin = NSPoint(
            x: max(0, (docFrame.width - clipBounds.width) / 2),
            y: max(0, (docFrame.height - clipBounds.height) / 2)
        )
        scrollView.contentView.scroll(to: centeredOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func step(by factor: CGFloat) {
        guard let scrollView else { return }
        let target = (scrollView.magnification * factor).clamped(to: scrollView.minMagnification...scrollView.maxMagnification)
        let center = NSPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        scrollView.animator().setMagnification(target, centeredAt: center)
    }
}

private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let zoomController: ImageZoomController

    func makeNSView(context: Context) -> NSScrollView {
        let imageView = NSImageView()
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: image.size)

        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 12
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.backgroundColor = .black
        scrollView.drawsBackground = true
        scrollView.documentView = imageView
        context.coordinator.imageView = imageView
        zoomController.scrollView = scrollView
        zoomController.imageSize = image.size
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            context.coordinator.imageView?.frame = NSRect(origin: .zero, size: image.size)
            context.coordinator.hasFitted = false
            zoomController.imageSize = image.size
        }
        // `NSScrollView`'s own bounds aren't known yet on the first `makeNSView` layout pass —
        // fitting once here (guarded so it only ever happens once per image) is the reliable
        // point to do it, since `updateNSView` re-runs after SwiftUI has actually sized the view.
        guard !context.coordinator.hasFitted, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
        context.coordinator.hasFitted = true
        scrollView.magnify(toFit: NSRect(origin: .zero, size: image.size))
        ImageZoomController.center(scrollView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var imageView: NSImageView?
        var hasFitted = false
    }
}

/// One reusable "open this image" experience shared by every "Open" action on a viewable
/// (FITS/PNG/TIFF or an elaborated result) image in the app — a near-fullscreen zoomable view
/// (see `ZoomableImageView`'s own doc comment for why `NSScrollView` rather than SwiftUI
/// gestures) plus the small set of actions someone opening a finished astrophoto actually wants
/// next: save a copy elsewhere, drop it into Photos, hand it to another app via Share, or make it
/// this project/session's cover image. Deliberately doesn't duplicate `ExportedFileViewerView`'s
/// FITS-specific debayer/stretch controls — this is the "just look at it, then do something with
/// it" viewer, not a raw-frame inspector.
struct FullScreenImageViewer: View {
    /// One image in the browsable set this viewer can step through with Next/Previous — just
    /// enough to display it and load it lazily (`NSImage(contentsOf:)` for every sibling up front
    /// would be wasteful for a large gallery).
    struct Entry {
        let fileURL: URL
        let displayName: String
    }

    /// Every image Next/Previous can step to, in display order — a single-element array (the
    /// convenience initializer below) means no navigation at all, matching every pre-existing
    /// caller's behavior exactly.
    let entries: [Entry]
    @State private var currentIndex: Int
    /// The index `currentIndex` started at — see `canActOnCurrentEntry`'s own doc comment.
    private let originalIndex: Int
    /// `nil` hides the "Set as Thumbnail" button entirely — not every caller has a
    /// project/session to set one on (e.g. a bare exported file with no project association).
    /// Scoped to `entries[0]` only (see `canActOnCurrentEntry`'s own doc comment) — never called
    /// for a different index.
    var onSetAsThumbnail: (() -> Void)?
    /// "All the right-click menu items on post processed images must be visible also in preview
    /// of the image" — an elaborated image's own context menu (Info…, Show in Finder, Publish to
    /// AstroBin…, Redo from Original…, Edit Image…, Third-Party Tools, Delete…) previously had no
    /// equivalent here at all once this viewer replaced the old tap-to-open metadata sheet. `nil`
    /// (every other caller — a bare capture PNG has none of these concepts) hides the "More"
    /// button entirely rather than showing an empty menu. `AnyView`, not a second generic
    /// parameter, so every existing call site keeps compiling unchanged. Scoped to `entries[0]`
    /// only, same as `onSetAsThumbnail`.
    var moreMenuItems: (() -> AnyView)? = nil
    /// Closes this viewer's own window — a plain closure (not `@Environment(\.dismiss)`, which
    /// only does anything inside a `.sheet`/`NavigationStack`) since this is now hosted in a real
    /// `NSWindow` via `DetachedContentWindowController` instead, precisely so it can be moved and
    /// resized like any other window.
    var onDismiss: () -> Void

    init(image: NSImage, fileURL: URL, onSetAsThumbnail: (() -> Void)? = nil, moreMenuItems: (() -> AnyView)? = nil, onDismiss: @escaping () -> Void) {
        self.entries = [Entry(fileURL: fileURL, displayName: fileURL.lastPathComponent)]
        self._currentIndex = State(initialValue: 0)
        self.originalIndex = 0
        self._loadedImage = State(initialValue: image)
        self.onSetAsThumbnail = onSetAsThumbnail
        self.moreMenuItems = moreMenuItems
        self.onDismiss = onDismiss
    }

    /// "Allow the user to go to next/previous image without closing the view" — `startIndex` is
    /// whichever `entries` element the user actually tapped to get here, not necessarily 0.
    init(entries: [Entry], startIndex: Int, onSetAsThumbnail: (() -> Void)? = nil, moreMenuItems: (() -> AnyView)? = nil, onDismiss: @escaping () -> Void) {
        self.entries = entries
        let resolvedStartIndex = entries.indices.contains(startIndex) ? startIndex : 0
        self._currentIndex = State(initialValue: resolvedStartIndex)
        self.originalIndex = resolvedStartIndex
        self._loadedImage = State(initialValue: nil)
        self.onSetAsThumbnail = onSetAsThumbnail
        self.moreMenuItems = moreMenuItems
        self.onDismiss = onDismiss
    }

    @State private var isSavingToPhotos = false
    @State private var photosResultMessage: String?
    @State private var didSetThumbnail = false
    @State private var loadedImage: NSImage?
    private let zoomController = ImageZoomController()

    private var currentEntry: Entry { entries[currentIndex] }
    private var fileURL: URL { currentEntry.fileURL }
    private var canGoPrevious: Bool { currentIndex > 0 }
    private var canGoNext: Bool { currentIndex < entries.count - 1 }
    /// `onSetAsThumbnail`/`moreMenuItems` close over the *specific* image the caller originally
    /// opened this viewer for (its own project/session, its own per-card `@State`) — they aren't
    /// meaningful for whatever sibling Next/Previous has since scrolled to, so both stay hidden
    /// once navigated away from the starting image rather than silently acting on the wrong one.
    private var canActOnCurrentEntry: Bool { currentIndex == originalIndex }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                if let loadedImage {
                    ZoomableImageView(image: loadedImage, zoomController: zoomController)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Matches `PlanetaryPostProcessingView.minWindowSize`/`fullScreenSize` — every window
        // showing a finished image (editing, post-processing, or just viewing one) opens at the
        // same size now, instead of this one alone defaulting to a smaller fixed size that left
        // the zoom/autofit `ZoomableImageView` already had less room to actually be useful in.
        .frame(minWidth: PlanetaryPostProcessingView.minWindowSize.width, maxWidth: .infinity,
               minHeight: PlanetaryPostProcessingView.minWindowSize.height, maxHeight: .infinity)
        .alert("Couldn't Save to Photos", isPresented: Binding(
            get: { photosResultMessage != nil }, set: { if !$0 { photosResultMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(photosResultMessage ?? "")
        }
        .task(id: currentIndex) {
            // Skipped for the single-entry convenience initializer, which already seeds
            // `loadedImage` directly with the image the caller loaded itself — no need to
            // re-decode the exact same file from disk a second time.
            guard entries.count > 1 else { return }
            loadedImage = NSImage(contentsOf: currentEntry.fileURL)
        }
    }

    private func goPrevious() {
        guard canGoPrevious else { return }
        currentIndex -= 1
    }

    private func goNext() {
        guard canGoNext else { return }
        currentIndex += 1
    }

    private var header: some View {
        HStack {
            if entries.count > 1 {
                HStack(spacing: 4) {
                    Button("Previous", systemImage: "chevron.left") { goPrevious() }
                        .disabled(!canGoPrevious)
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("Next", systemImage: "chevron.right") { goNext() }
                        .disabled(!canGoNext)
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                .labelStyle(.iconOnly)
                Text("\(currentIndex + 1) of \(entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider().frame(height: 16)
            }

            Text(fileURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // Explicit controls for the zoom/pan `ZoomableImageView`'s `NSScrollView` already
            // supports via pinch/scroll gestures — those work, but nothing on screen said so;
            // "Fit" re-triggers the same auto-fit that already runs once when the image first
            // appears, for after a user has zoomed/panned away from it.
            HStack(spacing: 4) {
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoomController.zoomOut() }
                Button("Fit to Window", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { zoomController.zoomToFit() }
                Button("Zoom In", systemImage: "plus.magnifyingglass") { zoomController.zoomIn() }
            }
            .labelStyle(.iconOnly)

            Divider().frame(height: 16)

            Button("Save As…", systemImage: "square.and.arrow.down") { saveAs() }

            Button {
                saveToPhotos()
            } label: {
                if isSavingToPhotos {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Save to Photos", systemImage: "photo.on.rectangle")
                }
            }
            .disabled(isSavingToPhotos)

            ShareLink(item: fileURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            if let onSetAsThumbnail, canActOnCurrentEntry {
                Button {
                    onSetAsThumbnail()
                    didSetThumbnail = true
                } label: {
                    Label(didSetThumbnail ? "Thumbnail Set" : "Set as Thumbnail", systemImage: didSetThumbnail ? "checkmark" : "photo.badge.checkmark")
                }
            }

            if let moreMenuItems, canActOnCurrentEntry {
                Menu {
                    moreMenuItems()
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }

            Button("Done") { onDismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        if let type = UTType(filenameExtension: fileURL.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: fileURL, to: destination)
    }

    /// `.addOnly` — this only ever writes a new asset into the user's library, never reads or
    /// modifies their existing photos, so it's the narrowest authorization level that covers this
    /// button (matching `NSPhotoLibraryAddUsageDescription`, not the broader
    /// `NSPhotoLibraryUsageDescription` full-library read/write prompt).
    private func saveToPhotos() {
        isSavingToPhotos = true
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    isSavingToPhotos = false
                    photosResultMessage = "Photos access was denied. Enable it in System Settings › Privacy & Security › Photos."
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    isSavingToPhotos = false
                    if !success {
                        photosResultMessage = error?.localizedDescription ?? "Unknown error."
                    }
                }
            }
        }
    }
}
