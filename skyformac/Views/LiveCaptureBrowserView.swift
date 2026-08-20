import SwiftUI

/// The iPhone-Live-Photo-style picker: shown right after `CameraManager.startLiveCapture()`
/// fires, first as a "Capturing…" progress state for the burst's ~3 seconds, then as a scrubber
/// over every frame it captured — a slider plus Previous/Next, rather than a full thumbnail
/// filmstrip, since a burst can realistically be anywhere from ~10 to several hundred frames
/// (see `CameraManager.startLiveCapture`'s doc comment) and rendering that many thumbnails up
/// front isn't worth the cost when scrubbing one frame at a time already tells you what you need.
/// Selecting a frame is a real side effect, same as `LuckyImagingFrameBrowserView`: it calls
/// `CameraManager.showLiveCaptureFrame(atIndex:)`, which replaces `currentFrame`/`currentImage`
/// so the picked frame is exactly what "Export PNG"/"Export TIFF" below then saves.
struct LiveCaptureBrowserView: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int = 0

    private var frameCount: Int { cameraManager.luckyImagingSession?.capturedCount ?? 0 }
    private var scoreAtSelection: Double? {
        let frames = cameraManager.luckyImagingSession?.scoredFrames ?? []
        return frames.indices.contains(selectedIndex) ? frames[selectedIndex].score : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Live Capture", systemImage: "livephoto")
                    .font(.headline)
                Spacer()
                if cameraManager.isLiveCaptureBurstActive {
                    Text("Capturing… \(frameCount) frame(s) so far")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(frameCount) frame(s) captured")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Close") {
                    cameraManager.discardLuckyImagingSession()
                    dismiss()
                }
            }
            .padding()

            Divider()

            ZStack {
                Color.black
                if let image = cameraManager.currentImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: 280, maxHeight: .infinity)

            Divider()

            VStack(spacing: 8) {
                if cameraManager.isLiveCaptureBurstActive {
                    Text("Capturing — the scrubber below fills in as frames arrive.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if frameCount == 0 {
                    Text("No frames captured.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button {
                            selectedIndex = max(0, selectedIndex - 1)
                            cameraManager.showLiveCaptureFrame(atIndex: selectedIndex)
                        } label: {
                            Image(systemName: "chevron.left")
                        }
                        .disabled(selectedIndex <= 0)

                        Slider(
                            value: Binding(
                                get: { Double(selectedIndex) },
                                set: { newValue in
                                    selectedIndex = Int(newValue.rounded())
                                    cameraManager.showLiveCaptureFrame(atIndex: selectedIndex)
                                }
                            ),
                            in: 0...Double(max(frameCount - 1, 0)), step: 1
                        )

                        Button {
                            selectedIndex = min(frameCount - 1, selectedIndex + 1)
                            cameraManager.showLiveCaptureFrame(atIndex: selectedIndex)
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .disabled(selectedIndex >= frameCount - 1)
                    }
                    HStack {
                        Text("Frame \(selectedIndex + 1) of \(frameCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let scoreAtSelection {
                            Text(String(format: "· sharpness %.1f", scoreAtSelection))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Export PNG…") { cameraManager.exportCurrentFrame(as: .png) }
                        Button("Export TIFF…") { cameraManager.exportCurrentFrame(as: .tiff) }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 460, idealHeight: 560)
        .onAppear { cameraManager.showLiveCaptureFrame(atIndex: 0) }
    }
}
