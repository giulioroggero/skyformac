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

    /// 1x (each slider spans the full 0...100% range, like before) up to 100x (each slider spans
    /// only 1% of it). Applied independently per slider (see `blackCenter`/`whiteCenter`) —
    /// centering both on a single shared point (e.g. their midpoint) would put black/white point
    /// out of that window entirely whenever they're far apart, which is the common case (0%/100%
    /// is the default), making the slider unable to even show its own current value once zoomed.
    /// The exact-percentage `TextField`s (below, 2 decimal places) work at any zoom level
    /// regardless, for a value further away than the current window.
    @State private var zoom: Double = 1.0
    /// Where each slider's zoomed window is centered — snapshotted (not continuously recomputed
    /// from the live value) whenever `zoom` changes or "Center" is tapped, and held steady while
    /// actually dragging. Continuously re-centering the window on every intermediate value during
    /// an active drag would mean fighting `Slider`'s own gesture recognizer over a bounds
    /// (`in:`) that keeps moving out from under it mid-gesture; snapshotting instead makes the
    /// window predictable — drag to an edge, then tap "Center" (or nudge `zoom`) to keep going.
    @State private var blackCenter: Double = 0
    @State private var whiteCenter: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Histogram").font(.headline)

            if let buckets = currentBuckets {
                histogramCanvas(buckets: buckets)
            } else {
                Rectangle()
                    .fill(.black)
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(Text("No signal").foregroundStyle(.white.opacity(0.5)))
            }

            zoomControl

            stretchSlider("Black Point", value: blackPointBinding, center: $blackCenter)
            stretchSlider("White Point", value: whitePointBinding, center: $whiteCenter)
        }
        .padding()
        .onChange(of: zoom) { recenter() }
        .onAppear { recenter() }
    }

    // MARK: - Zoom

    private func recenter() {
        blackCenter = cameraManager.stretch.blackPoint
        whiteCenter = cameraManager.stretch.whitePoint
    }

    /// A window of width `1/zoom` centered on `center`, clamped into 0...1.
    private func zoomedRange(around center: Double) -> ClosedRange<Double> {
        guard zoom > 1 else { return 0...1 }
        let halfWidth = 0.5 / zoom
        let lower = min(max(0, center - halfWidth), 1 - halfWidth * 2)
        let upper = min(1, lower + halfWidth * 2)
        return lower...upper
    }

    @ViewBuilder
    private var zoomControl: some View {
        HStack {
            Text("Zoom").font(.caption)
            Slider(value: $zoom, in: 1...100)
            Text(zoom <= 1 ? "1x" : String(format: "%.0fx", zoom))
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            if zoom > 1 {
                Button("Reset") { zoom = 1 }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
        .help("Zooms the Black/White Point sliders below into a narrow window around each one's own current value, for finer drag control. The exact-value fields next to each slider work at any zoom.")
    }

    // MARK: - Histogram canvas

    /// Always shows the *full* 0...100% range regardless of `zoom` — the two sliders can each be
    /// zoomed into a different, independent window (see `zoomedRange(around:)`), so there's no
    /// single "zoomed region" left that would still make sense to magnify here. This stays a
    /// full-range overview; the sliders do the fine-grained work.
    @ViewBuilder
    private func histogramCanvas(buckets: [Int]) -> some View {
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
    }

    private var currentBuckets: [Int]? {
        if useMetalRenderer {
            return cameraManager.gpuHistogramCounts
        }
        guard let frame = cameraManager.currentFrame else { return nil }
        return HistogramComputer.histogram(for: frame)
    }

    // MARK: - Sliders

    private func stretchSlider(_ title: String, value: Binding<Double>, center: Binding<Double>) -> some View {
        // Reaching either edge of a zoomed window means the drag can't go further until the
        // window moves — offer that inline rather than making "Center" a separate always-there
        // control most drags will never need.
        let range = zoomedRange(around: center.wrappedValue)
        let atEdge = zoom > 1 && (value.wrappedValue <= range.lowerBound || value.wrappedValue >= range.upperBound)

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                if atEdge {
                    Button("Center") { center.wrappedValue = value.wrappedValue }
                        .font(.caption2)
                        .controlSize(.small)
                        .help("This slider is zoomed in and pinned at the edge of its window — center it back on the current value to keep dragging further.")
                }
                TextField("", value: percentBinding(for: value), format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("%").font(.caption).foregroundStyle(.secondary)
            }
            // Restricting the slider's own range to its zoomed window (rather than always 0...1)
            // is what actually delivers finer drag control: the same physical slider width now
            // maps to a narrower span of values, so the same finger movement changes the value by
            // less.
            Slider(value: value, in: range)
        }
    }

    /// Converts a 0...1 stretch-point binding to 0...100 for the exact-value `TextField`, while
    /// still routing writes through the original binding's black/white-point clamp logic.
    private func percentBinding(for value: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { value.wrappedValue * 100 },
            set: { value.wrappedValue = $0 / 100 }
        )
    }

    private var blackPointBinding: Binding<Double> {
        Binding(
            get: { cameraManager.stretch.blackPoint },
            set: { cameraManager.stretch.blackPoint = min(max($0, 0), cameraManager.stretch.whitePoint - 0.01) }
        )
    }

    private var whitePointBinding: Binding<Double> {
        Binding(
            get: { cameraManager.stretch.whitePoint },
            set: { cameraManager.stretch.whitePoint = max(min($0, 1), cameraManager.stretch.blackPoint + 0.01) }
        )
    }
}
