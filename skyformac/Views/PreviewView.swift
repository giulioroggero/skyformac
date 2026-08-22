import SwiftUI

/// Live camera preview. Two interchangeable render paths:
/// - CPU (`useMetalRenderer == false`): `CameraManager.currentImage`, a `CGImage` produced by
///   `CGImageRenderer`'s CPU debayer + stretch — the Milestone 2/4 baseline.
/// - GPU (`useMetalRenderer == true`): `MetalPreviewView`, which uploads frames straight to an
///   `MTLTexture` and debayers/stretches in a compute shader (`Shaders.metal`) — the upgrade
///   pass per spec 3.4's "leverage GPUs" direction.
///
/// When focus assist is on, detected stars (`StarDetector`, via Vision) are drawn as an overlay
/// on top of either render path.
struct PreviewView: View {
    var cameraManager: CameraManager
    var useMetalRenderer: Bool

    /// Fullscreen presentation of this exact same view (see `ContentView.fullScreenPreview`) —
    /// no separate view/rendering path to keep in sync, just a few extra overlay affordances and
    /// modifiers that only make sense once this view *is* the whole window: an explicit zoom
    /// slider (pinch-to-zoom still works, but isn't discoverable/precise enough to be the only
    /// way to zoom in on a dim star field when the whole point is seeing detail better), an Exit
    /// button + Escape key, and no fixed aspect ratio/rounded corners (those exist so the preview
    /// looks right embedded next to the sidebar, not filling a whole window).
    var onEnterFullScreen: (() -> Void)?
    var onExitFullScreen: (() -> Void)?

    init(
        cameraManager: CameraManager,
        useMetalRenderer: Bool,
        onEnterFullScreen: (() -> Void)? = nil,
        onExitFullScreen: (() -> Void)? = nil
    ) {
        self.cameraManager = cameraManager
        self.useMetalRenderer = useMetalRenderer
        self.onEnterFullScreen = onEnterFullScreen
        self.onExitFullScreen = onExitFullScreen
    }

    @State private var captureFlashOpacity: Double = 0
    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @GestureState private var magnifyDelta: CGFloat = 1
    @GestureState private var dragDelta: CGSize = .zero
    /// The on-screen size `zoomablePreview`'s content actually renders at before `scaleEffect` —
    /// needed to convert `panOffset` (in points) into the normalized crop rect `CameraManager`
    /// uses at export time. Captured via a `GeometryReader` in `zoomablePreview`'s background.
    @State private var containerSize: CGSize = .zero

    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 8

    private var isFullScreenPresentation: Bool { onExitFullScreen != nil }

    /// The real camera/frame's own width:height ratio — `currentFrame` (rather than the
    /// connected camera's fixed sensor dimensions) so a planetary auto-crop ROI, which changes
    /// the displayed frame's own dimensions, is reflected immediately too. This used to be a
    /// hardcoded `4.0 / 3.0` regardless of the actual source: unnoticeable for many ZWO sensors,
    /// which happen to be close to that ratio, but visibly wrong for a webcam/iPhone frame
    /// (typically 16:9). `nil` (no `.aspectRatio` constraint at all) before any frame/camera
    /// info exists yet, so the placeholder states just fill whatever space they're given.
    private var actualAspectRatio: CGFloat? {
        if let frame = cameraManager.currentFrame, frame.height > 0 {
            return CGFloat(frame.width) / CGFloat(frame.height)
        }
        if let camera = cameraManager.connectedCamera, camera.maxHeight > 0 {
            return CGFloat(camera.maxWidth) / CGFloat(camera.maxHeight)
        }
        return nil
    }

    /// Night mode tints everything *around* the live image red (preserves dark adaptation
    /// reading labels/sliders/badges). The image itself defaults to staying untinted — the
    /// actual point of this app is seeing the real sensor data (true star colors, a correctly
    /// white-balanced RGB24 frame), which a red multiply would destroy — but
    /// `isNightModePreviewTinted` (toggled via `videoTintToggle` below) lets it be tinted too for
    /// sessions dark-adapted enough that even a small true-color preview matters, or switched
    /// back to true color ("normal") on demand without leaving Night Mode altogether.
    /// `ContentView` applies the chrome-only tint to everything else in the window individually
    /// rather than as one blanket modifier over the whole content area, for the identical reason.
    private var imageNightTint: Color {
        cameraManager.isNightModeEnabled && cameraManager.isNightModePreviewTinted ? .red : .white
    }

    /// `.colorMultiply` forces SwiftUI to composite its content through an extra color-filter
    /// pass on every single paint — including a `.white` multiply, which is mathematically a
    /// no-op but not a *free* one. Applying it unconditionally to the live image meant every
    /// incoming frame paid that compositing cost even with Night Mode off entirely (the vast
    /// majority of the time), which showed up as added live-preview latency. Only wrapping
    /// `preview` in the modifier when the tint is actually non-white keeps the fast path for
    /// everyone not using the red-tinted-preview option.
    @ViewBuilder
    private var tintedPreview: some View {
        if cameraManager.isNightModeEnabled && cameraManager.isNightModePreviewTinted {
            preview.colorMultiply(imageNightTint)
        } else {
            preview
        }
    }

    var body: some View {
        tintedPreview
            .clipShape(isFullScreenPresentation ? AnyShape(Rectangle()) : AnyShape(RoundedRectangle(cornerRadius: 8)))
            .overlay { Color.white.opacity(captureFlashOpacity).allowsHitTesting(false) }
            .overlay(alignment: .bottomLeading) { zoomBadge.nightModeTint(cameraManager) }
            .overlay(alignment: .topTrailing) { cornerControls.nightModeTint(cameraManager) }
            .overlay(alignment: .top) { exposureCountdownBadge.nightModeTint(cameraManager) }
            .overlay(alignment: .top) { liveViewCountdownBadge.nightModeTint(cameraManager) }
            .overlay(alignment: .bottom) { zoomControlBar.nightModeTint(cameraManager) }
            .onExitCommand { onExitFullScreen?() }
            .onChange(of: cameraManager.captureFeedbackTrigger) {
                captureFlashOpacity = 0.6
                withAnimation(.easeOut(duration: 0.25)) { captureFlashOpacity = 0 }
            }
            .onChange(of: zoom) { updateCaptureCropRect() }
            .onChange(of: panOffset) { updateCaptureCropRect() }
            .onChange(of: containerSize) { updateCaptureCropRect() }
    }

    /// Keeps `CameraManager.previewCropRectNormalized` matching what's actually visible on
    /// screen, so a capture taken while zoomed in exports that same framing instead of the full
    /// sensor frame — see that property's doc comment for why. Normalized, top-left origin.
    private func updateCaptureCropRect() {
        guard zoom > 1.001, containerSize.width > 0, containerSize.height > 0 else {
            cameraManager.previewCropRectNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
            return
        }
        let offsetUnitX = panOffset.width / containerSize.width
        let offsetUnitY = panOffset.height / containerSize.height
        let side = 1 / zoom
        let minX = 0.5 - (0.5 + offsetUnitX) / zoom
        let minY = 0.5 - (0.5 + offsetUnitY) / zoom
        cameraManager.previewCropRectNormalized = CGRect(
            x: min(max(minX, 0), 1 - side),
            y: min(max(minY, 0), 1 - side),
            width: side,
            height: side
        )
    }

    /// Split out of `body` because `.aspectRatio(nil, contentMode: .fit)` is *not* the "no
    /// constraint" no-op it looks like — passing `nil` still makes the modifier size this whole
    /// `ZStack` (background fill included) to its own intrinsic aspect ratio, then fit *that*
    /// into the fullscreen window, leaving the entire preview — not just the video image, the
    /// black background and the zoom/pan content too — confined to a centered box smaller than
    /// the actual window. The fix is to not apply the modifier at all in fullscreen, not to pass
    /// it `nil`; individual images/`MetalPreviewView` still keep their own aspect-correct fit
    /// inside that now-full-window box, so nothing gets stretched.
    @ViewBuilder
    private var preview: some View {
        let stack = ZStack {
            Rectangle().fill(.black)
            if cameraManager.connectedCamera == nil {
                ContentUnavailableView(
                    "No Live Preview",
                    systemImage: "camera.metering.none",
                    description: Text("Connect a camera to start streaming.")
                )
                .foregroundStyle(.white)
            } else if useMetalRenderer || cameraManager.currentImage != nil {
                zoomablePreview
            } else {
                ProgressView("Waiting for first frame…")
                    .foregroundStyle(.white)
            }
        }
        if isFullScreenPresentation {
            stack
        } else {
            stack.aspectRatio(actualAspectRatio, contentMode: .fit)
        }
    }

    /// Direct, on-screen evidence of which render path is actually live (the toolbar toggle
    /// state alone isn't visible while looking at the preview itself), plus the fullscreen
    /// enter/exit button — combined into one corner group so they share a single padding inset.
    @ViewBuilder
    private var cornerControls: some View {
        HStack(spacing: 8) {
            if cameraManager.connectedCamera != nil {
                Label(useMetalRenderer ? "GPU" : "CPU", systemImage: useMetalRenderer ? "bolt.fill" : "cpu")
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((useMetalRenderer ? Color.green : Color.gray).opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
                    .help(useMetalRenderer
                        ? "Rendering on GPU (Metal compute shaders)"
                        : "Rendering on CPU (CGImage)")
            }
            if cameraManager.isNightModeEnabled {
                Button {
                    cameraManager.isNightModePreviewTinted.toggle()
                } label: {
                    Label(
                        cameraManager.isNightModePreviewTinted ? "Normal" : "Dark",
                        systemImage: cameraManager.isNightModePreviewTinted ? "sun.max.fill" : "moon.fill"
                    )
                    .font(.caption2.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help(cameraManager.isNightModePreviewTinted
                    ? "Video is red-tinted along with the rest of the UI. Click to switch just the video back to normal (true color) without leaving Night Mode."
                    : "Video stays true color while Night Mode tints the rest of the UI. Click to red-tint the video too.")
            }
            if let onEnterFullScreen {
                Button(action: onEnterFullScreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.bold())
                        .padding(8)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Fill the window with the live video and an overlay zoom control — for seeing faint stars without sidebar clutter.")
            }
            if let onExitFullScreen {
                Button(action: onExitFullScreen) {
                    Label("Exit Full Screen", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.caption2.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Exit fullscreen (Esc)")
            }
        }
        .padding(10)
    }

    /// Only shown in fullscreen (`isFullScreenPresentation`) — pinch-to-zoom (`magnifyGesture`)
    /// still works here too, but isn't precise or discoverable enough to be the *only* way to
    /// zoom in when the whole point of fullscreen is seeing faint detail (stars) better.
    @ViewBuilder
    private var zoomControlBar: some View {
        if isFullScreenPresentation, cameraManager.connectedCamera != nil {
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass").font(.caption)
                Slider(
                    value: Binding(
                        get: { zoom },
                        set: { applyZoom(clampedZoom($0)) }
                    ),
                    in: minZoom...maxZoom
                )
                .frame(width: 220)
                Image(systemName: "plus.magnifyingglass").font(.caption)
                Text(String(format: "%.1f×", zoom))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .leading)
                if zoom > 1.001 {
                    Button("Reset", action: resetZoom)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.cyan)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private var zoomablePreview: some View {
        frameContent
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerSize = proxy.size }
                        .onChange(of: proxy.size) { _, newValue in containerSize = newValue }
                }
            )
            .scaleEffect(zoom * magnifyDelta, anchor: .center)
            // `panOffset` is scaled by `magnifyDelta` here too — `.offset` is applied in absolute
            // points *after* `.scaleEffect` above, so without this an in-progress pinch would
            // leave whatever's currently centered visibly drifting toward whichever direction the
            // last pan happened to lean, growing worse the further zoom goes. See `magnifyGesture`
            // and the fullscreen zoom slider's `set:` for the equivalent fix to the *committed*
            // `zoom`/`panOffset` pair once a zoom change actually lands.
            .offset(
                x: panOffset.width * magnifyDelta + dragDelta.width,
                y: panOffset.height * magnifyDelta + dragDelta.height
            )
            .gesture(magnifyGesture)
            .simultaneousGesture(dragGesture)
            .onTapGesture(count: 2) { resetZoom() }
    }

    @ViewBuilder
    private var frameContent: some View {
        Group {
            if useMetalRenderer {
                MetalPreviewView(cameraManager: cameraManager)
            } else if let cgImage = cameraManager.currentImage {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .overlay { focusAssistOverlay }
        .overlay { planetROIOverlay }
        .overlay { polarAlignmentOverlay }
        .overlay { skyHUDOverlay }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($magnifyDelta) { value, state, _ in state = value.magnification }
            .onEnded { value in
                applyZoom(clampedZoom(zoom * value.magnification))
            }
    }

    /// Changes `zoom` to `newZoom` and rescales `panOffset` by the same ratio, so whatever's
    /// currently centered on screen *stays* centered — without this, `panOffset` stayed a fixed
    /// number of points while `zoom` changed underneath it (via a pinch, or the fullscreen zoom
    /// slider), and since `.offset` in `zoomablePreview` applies in absolute points *after*
    /// `.scaleEffect`, the same offset represented a shrinking or growing fraction of the zoomed
    /// content as zoom changed — visibly dragging whatever was centered off toward one side, worse
    /// the more zoom changed afterward. `oldZoom` is guaranteed `> 0` (`minZoom` is `1`).
    private func applyZoom(_ newZoom: CGFloat) {
        let ratio = newZoom / zoom
        panOffset = clampedOffset(CGSize(width: panOffset.width * ratio, height: panOffset.height * ratio))
        zoom = newZoom
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: zoom > 1.001 ? 2 : .infinity)
            .updating($dragDelta) { value, state, _ in state = value.translation }
            .onEnded { value in
                panOffset = clampedOffset(CGSize(
                    width: panOffset.width + value.translation.width,
                    height: panOffset.height + value.translation.height
                ))
            }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        min(max(value, minZoom), maxZoom)
    }

    /// Panning only makes sense once zoomed in; snaps back to centered otherwise.
    private func clampedOffset(_ offset: CGSize) -> CGSize {
        zoom <= 1.001 ? .zero : offset
    }

    private func resetZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            panOffset = .zero
        }
    }

    /// A big, hard-to-miss countdown directly on the preview during a blocking single/dark/flat
    /// exposure — `ExposureCountdownView` itself only ever appeared next to the "Capture" button
    /// deep inside the sidebar's collapsed "Advanced" section, so a long exposure's progress was
    /// easy to miss entirely unless that section happened to already be open. Same driving state
    /// (`CameraManager.isCapturingExposure`/`capturingExposureStartDate`/
    /// `capturingExposureDurationSeconds`) — this is just a second, always-visible presentation
    /// of it, not a separate timer.
    @ViewBuilder
    private var exposureCountdownBadge: some View {
        if cameraManager.isCapturingExposure,
           let start = cameraManager.capturingExposureStartDate,
           let duration = cameraManager.capturingExposureDurationSeconds {
            TimelineView(.periodic(from: start, by: 0.1)) { context in
                let remaining = max(0, duration - context.date.timeIntervalSince(start))
                Label(String(format: "Exposing… %.1fs left", remaining), systemImage: "timer")
                    .font(.callout.monospacedDigit().bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(.top, 10)
        }
    }

    /// A "next frame in Xs" indicator for continuous live-view streaming with a long exposure set
    /// (e.g. 5s) — distinct from `exposureCountdownBadge` above (a one-shot blocking capture):
    /// this is a recurring cadence, so it uses a lighter/secondary visual treatment (a thin
    /// progress ring, not a bold capsule) to read as "the view refreshes periodically" rather
    /// than "something is blocked." Mutually exclusive with `exposureCountdownBadge` in practice
    /// (`CameraManager.liveViewFrameStartDate` is only set while `!isCapturingExposure`), so both
    /// safely share the same `.overlay(alignment: .top)` slot.
    @ViewBuilder
    private var liveViewCountdownBadge: some View {
        if let start = cameraManager.liveViewFrameStartDate,
           let duration = cameraManager.liveViewFrameExpectedDuration {
            TimelineView(.periodic(from: start, by: 0.1)) { context in
                let elapsed = context.date.timeIntervalSince(start)
                let remaining = max(0, duration - elapsed)
                HStack(spacing: 6) {
                    ProgressView(value: min(elapsed / duration, 1))
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                    Text(String(format: "Next frame in %.1fs", remaining))
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.4), in: Capsule())
                .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private var zoomBadge: some View {
        if zoom > 1.001 {
            Button(action: resetZoom) {
                Label(String(format: "%.1f×", zoom), systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(10)
            .help("Zoomed \(String(format: "%.1f", zoom))×. Click to reset, or double-click the preview.")
        }
    }

    @ViewBuilder
    private var focusAssistOverlay: some View {
        if let stars = cameraManager.focusAssist?.stars {
            GeometryReader { geometry in
                ForEach(stars) { star in
                    let box = star.boundingBoxNormalized
                    // Vision's normalized coordinates are bottom-left origin, y-up; SwiftUI's
                    // GeometryReader-relative coordinates are top-left origin, y-down.
                    let rect = CGRect(
                        x: box.minX * geometry.size.width,
                        y: (1 - box.maxY) * geometry.size.height,
                        width: box.width * geometry.size.width,
                        height: box.height * geometry.size.height
                    )
                    Circle()
                        .stroke(.green, lineWidth: 1.5)
                        .frame(width: max(rect.width, rect.height) * 1.6, height: max(rect.width, rect.height) * 1.6)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }

    /// Only meaningful when tracking without cropping: `planetROI` is expressed in the full,
    /// uncropped frame's coordinate space, but once auto-crop is on, the visible preview *is*
    /// already that cropped region — overlaying the same box on it would be nonsensical.
    @ViewBuilder
    private var planetROIOverlay: some View {
        if !cameraManager.isPlanetaryCropEnabled, let box = cameraManager.planetROI {
            GeometryReader { geometry in
                let rect = CGRect(
                    x: box.minX * geometry.size.width,
                    y: (1 - box.maxY) * geometry.size.height,
                    width: box.width * geometry.size.width,
                    height: box.height * geometry.size.height
                )
                Rectangle()
                    .stroke(.yellow, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    /// Catalog object badges/labels (spec/skyformac_Catalog_HUD_Spec.md) — shown once
    /// `CameraManager.liveWCS` has a real solve from identified stars (Focus Assist -> Recognize
    /// Stars needs to be on, and enough confidently-matched stars in frame).
    @ViewBuilder
    private var skyHUDOverlay: some View {
        if let wcs = cameraManager.liveWCS {
            SkyHUDView(wcs: wcs, visibleObjects: cameraManager.visibleSkyObjects)
        }
    }

    /// Arrow from the frame's assumed center to the solved mechanical rotation center — a
    /// visual "which way is the axis actually pointing" indicator, in pixels, not degrees (see
    /// `PolarAlignmentSolver`'s doc comment for why real alt/az degree readouts aren't possible
    /// here without a full plate solver).
    @ViewBuilder
    private var polarAlignmentOverlay: some View {
        if cameraManager.polarAlignmentStage == .complete,
           let center = cameraManager.polarAlignmentRotationCenter,
           let frame = cameraManager.currentFrame {
            GeometryReader { geometry in
                let scaleX = geometry.size.width / CGFloat(frame.width)
                let scaleY = geometry.size.height / CGFloat(frame.height)
                let start = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let end = CGPoint(x: center.x * scaleX, y: center.y * scaleY)
                Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                }
                .stroke(.cyan, lineWidth: 2)
                Circle()
                    .fill(.cyan)
                    .frame(width: 8, height: 8)
                    .position(end)
            }
        }
    }
}
