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

    @State private var zoom: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @GestureState private var magnifyDelta: CGFloat = 1
    @GestureState private var dragDelta: CGSize = .zero

    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 8

    var body: some View {
        ZStack {
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
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomLeading) { zoomBadge }
    }

    @ViewBuilder
    private var zoomablePreview: some View {
        frameContent
            .scaleEffect(zoom * magnifyDelta)
            .offset(x: panOffset.width + dragDelta.width, y: panOffset.height + dragDelta.height)
            .gesture(magnifyGesture)
            .simultaneousGesture(dragGesture)
            .onTapGesture(count: 2) { resetZoom() }
    }

    @ViewBuilder
    private var frameContent: some View {
        if useMetalRenderer {
            MetalPreviewView(cameraManager: cameraManager)
                .overlay { focusAssistOverlay }
                .overlay { planetROIOverlay }
                .overlay { polarAlignmentOverlay }
        } else if let cgImage = cameraManager.currentImage {
            Image(decorative: cgImage, scale: 1.0)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .overlay { focusAssistOverlay }
                .overlay { planetROIOverlay }
                .overlay { polarAlignmentOverlay }
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($magnifyDelta) { value, state, _ in state = value.magnification }
            .onEnded { value in
                zoom = clampedZoom(zoom * value.magnification)
                panOffset = clampedOffset(panOffset)
            }
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
