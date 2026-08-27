import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Native pinch/scroll-wheel zoom and pan, via an `NSScrollView` hosting an `NSImageView` —
/// SwiftUI has no built-in equivalent on macOS, and `NSScrollView.allowsMagnification` is the
/// same mechanism Preview.app/Finder's own Quick Look already use, rather than hand-rolling
/// `MagnificationGesture`/`DragGesture` math.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage

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
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            context.coordinator.imageView?.frame = NSRect(origin: .zero, size: image.size)
            context.coordinator.hasFitted = false
        }
        // `NSScrollView`'s own bounds aren't known yet on the first `makeNSView` layout pass —
        // fitting once here (guarded so it only ever happens once per image) is the reliable
        // point to do it, since `updateNSView` re-runs after SwiftUI has actually sized the view.
        guard !context.coordinator.hasFitted, scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return }
        context.coordinator.hasFitted = true
        scrollView.magnify(toFit: NSRect(origin: .zero, size: image.size))
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
    let image: NSImage
    let fileURL: URL
    /// `nil` hides the "Set as Thumbnail" button entirely — not every caller has a
    /// project/session to set one on (e.g. a bare exported file with no project association).
    var onSetAsThumbnail: (() -> Void)?
    /// "All the right-click menu items on post processed images must be visible also in preview
    /// of the image" — an elaborated image's own context menu (Info…, Show in Finder, Publish to
    /// AstroBin…, Redo from Original…, Edit Image…, Third-Party Tools, Delete…) previously had no
    /// equivalent here at all once this viewer replaced the old tap-to-open metadata sheet. `nil`
    /// (every other caller — a bare capture PNG has none of these concepts) hides the "More"
    /// button entirely rather than showing an empty menu. `AnyView`, not a second generic
    /// parameter, so every existing call site keeps compiling unchanged.
    var moreMenuItems: (() -> AnyView)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var isSavingToPhotos = false
    @State private var photosResultMessage: String?
    @State private var didSetThumbnail = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZoomableImageView(image: image)
                .frame(minWidth: 900, minHeight: 640)
        }
        .frame(minWidth: 960, minHeight: 700)
        .alert("Couldn't Save to Photos", isPresented: Binding(
            get: { photosResultMessage != nil }, set: { if !$0 { photosResultMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(photosResultMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text(fileURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

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

            if let onSetAsThumbnail {
                Button {
                    onSetAsThumbnail()
                    didSetThumbnail = true
                } label: {
                    Label(didSetThumbnail ? "Thumbnail Set" : "Set as Thumbnail", systemImage: didSetThumbnail ? "checkmark" : "photo.badge.checkmark")
                }
            }

            if let moreMenuItems {
                Menu {
                    moreMenuItems()
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }

            Button("Done") { dismiss() }
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
