import SwiftUI

/// Live histogram with black/white point stretch sliders, per spec Milestone 4.
///
/// When the Metal renderer is active, uses the GPU-computed histogram (`Shaders.metal`'s
/// `histogramReduce` kernel, surfaced via `CameraManager.gpuHistogramCounts`) instead of
/// `HistogramComputer`'s CPU pass — avoiding a second full per-pixel CPU pass over
/// multi-megapixel frames on top of the GPU debayer/stretch already happening for preview.
struct HistogramView: View {
    var cameraManager: CameraManager
    var useMetalRenderer: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Histogram").font(.headline)

            if let buckets = currentBuckets {
                let maxCount = max(buckets.max() ?? 1, 1)

                Canvas { context, size in
                    let barWidth = size.width / CGFloat(buckets.count)
                    for (index, count) in buckets.enumerated() {
                        let height = size.height * CGFloat(count).squareRoot() / CGFloat(maxCount).squareRoot()
                        let rect = CGRect(
                            x: CGFloat(index) * barWidth,
                            y: size.height - height,
                            width: max(barWidth, 1),
                            height: height
                        )
                        context.fill(Path(rect), with: .color(.accentColor.opacity(0.8)))
                    }

                    let blackX = size.width * cameraManager.stretch.blackPoint
                    let whiteX = size.width * cameraManager.stretch.whitePoint
                    context.stroke(
                        Path { $0.move(to: CGPoint(x: blackX, y: 0)); $0.addLine(to: CGPoint(x: blackX, y: size.height)) },
                        with: .color(.red), lineWidth: 1
                    )
                    context.stroke(
                        Path { $0.move(to: CGPoint(x: whiteX, y: 0)); $0.addLine(to: CGPoint(x: whiteX, y: size.height)) },
                        with: .color(.white), lineWidth: 1
                    )
                }
                .frame(height: 100)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Rectangle()
                    .fill(.black)
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(Text("No signal").foregroundStyle(.white.opacity(0.5)))
            }

            stretchSlider("Black Point", value: blackPointBinding)
            stretchSlider("White Point", value: whitePointBinding)
        }
        .padding()
    }

    private var currentBuckets: [Int]? {
        if useMetalRenderer {
            return cameraManager.gpuHistogramCounts
        }
        guard let frame = cameraManager.currentFrame else { return nil }
        return HistogramComputer.histogram(for: frame)
    }

    private func stretchSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.0f%%", value.wrappedValue * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }

    private var blackPointBinding: Binding<Double> {
        Binding(
            get: { cameraManager.stretch.blackPoint },
            set: { cameraManager.stretch.blackPoint = min($0, cameraManager.stretch.whitePoint - 0.01) }
        )
    }

    private var whitePointBinding: Binding<Double> {
        Binding(
            get: { cameraManager.stretch.whitePoint },
            set: { cameraManager.stretch.whitePoint = max($0, cameraManager.stretch.blackPoint + 0.01) }
        )
    }
}
