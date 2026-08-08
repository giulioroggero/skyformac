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
            } else if useMetalRenderer {
                MetalPreviewView(cameraManager: cameraManager)
                    .overlay { focusAssistOverlay }
            } else if let cgImage = cameraManager.currentImage {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { focusAssistOverlay }
            } else {
                ProgressView("Waiting for first frame…")
                    .foregroundStyle(.white)
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
}
