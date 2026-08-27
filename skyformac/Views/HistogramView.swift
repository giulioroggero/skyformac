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
    /// Combined (luma) histogram vs. separate Red/Green/Blue curves — only meaningful for a color
    /// source, so the toggle itself only appears when `currentChannelHistograms` has something to
    /// show. Also gates which Black/White Point sliders are shown below: "By Channel" on switches
    /// those from the one combined pair to `cameraManager.channelStretch`'s three independent
    /// pairs, in lockstep with `cameraManager.isIndependentChannelStretchEnabled` — seeing the
    /// per-channel histograms is exactly when per-channel stretch editing is useful, so one
    /// toggle drives both rather than asking for two separate ones.
    @State private var showByChannel = false
    @State private var redBlackCenter: Double = 0
    @State private var redWhiteCenter: Double = 1
    @State private var greenBlackCenter: Double = 0
    @State private var greenWhiteCenter: Double = 1
    @State private var blueBlackCenter: Double = 0
    @State private var blueWhiteCenter: Double = 1

    /// The CPU-renderer path's own cache for `currentBuckets`/`currentChannelHistograms` — see
    /// the `.task(id:)` in `body` below for why this exists at all: computing these synchronously
    /// inside a computed property read *during `body`'s own evaluation* ran a full per-pixel CPU
    /// histogram pass on the main actor every single time this view re-rendered, i.e. on every
    /// live frame — "when capture and the histogram change the image freeze a little bit" was
    /// this main-thread stall. The GPU path never had this problem (`gpuHistogramCounts` is
    /// already precomputed elsewhere before this view ever reads it), so only the CPU path needs
    /// a cache.
    @State private var cachedCPUHistogram: [Int]?
    @State private var cachedCPUChannelHistograms: (red: [Int], green: [Int], blue: [Int])?

    /// This whole tab lives in a shared row with the live preview — a plain `VStack` sizes to
    /// its own content's actual height, letting the tab area (and so the preview, via its own
    /// `.layoutPriority(1)` in `ContentView`) size correctly either way. A `ScrollView` does NOT
    /// do that: it always requests all the space its parent offers rather than reporting its
    /// content's real height upward, which is exactly what was leaving dead empty space below
    /// the (usually short) combined-mode content once this got wrapped in one. Only "By
    /// Channel" mode's 6 sliders (vs. combined mode's 2) actually risk running taller than the
    /// tab's `maxHeight` cap, so only *that* case gets wrapped — see `body` below.
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Histogram").font(.headline)
                HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.blackWhitePoint")
                if currentChannelHistograms != nil {
                    Spacer()
                    Toggle("By Channel", isOn: Binding(
                        get: { showByChannel },
                        set: { newValue in
                            showByChannel = newValue
                            cameraManager.isIndependentChannelStretchEnabled = newValue
                        }
                    ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .help("Shows separate Red/Green/Blue histograms, and switches the Black/White Point sliders below to three independent pairs (one per channel) instead of the one combined pair — useful for compensating a color imbalance (e.g. a light-polluted sky's orange cast) directly at the stretch stage.")
                    HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.histogramByChannel")
                }
            }

            if showByChannel, let channels = currentChannelHistograms {
                channelHistogramCanvas(channels)
            } else if let buckets = currentBuckets {
                histogramCanvas(buckets: buckets)
            } else {
                Rectangle()
                    .fill(.black)
                    .frame(height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(Text("No signal").foregroundStyle(.white.opacity(0.5)))
            }

            clippingWarningView

            zoomControl

            if showByChannel {
                Text("Red").font(.caption).foregroundStyle(.red)
                stretchSlider("Black Point", value: channelBlackPointBinding(\.red), center: $redBlackCenter)
                stretchSlider("White Point", value: channelWhitePointBinding(\.red), center: $redWhiteCenter)
                Text("Green").font(.caption).foregroundStyle(.green)
                stretchSlider("Black Point", value: channelBlackPointBinding(\.green), center: $greenBlackCenter)
                stretchSlider("White Point", value: channelWhitePointBinding(\.green), center: $greenWhiteCenter)
                Text("Blue").font(.caption).foregroundStyle(.blue)
                stretchSlider("Black Point", value: channelBlackPointBinding(\.blue), center: $blueBlackCenter)
                stretchSlider("White Point", value: channelWhitePointBinding(\.blue), center: $blueWhiteCenter)
            } else {
                stretchSlider("Black Point", value: blackPointBinding, center: $blackCenter)
                stretchSlider("White Point", value: whitePointBinding, center: $whiteCenter)
            }
        }
        .padding()
    }

    var body: some View {
        Group {
            if showByChannel {
                ScrollView { content }
            } else {
                content
            }
        }
        .onChange(of: zoom) { recenter() }
        .onAppear { recenter() }
        // `frameID` (not `cameraManager.currentFrame` itself) as the task's own identity —
        // `CapturedFrame` has no `Equatable`/stable identity of its own, but `frameID` is bumped
        // exactly once per new frame, and SwiftUI cancels the previous `.task(id:)` invocation
        // outright when this changes, so a slow histogram pass never races a newer one back into
        // `cachedCPUHistogram`.
        .task(id: cameraManager.frameID) {
            guard !useMetalRenderer, let frame = cameraManager.currentFrame else { return }
            let bucketsTask = Task.detached(priority: .userInitiated) { HistogramComputer.histogram(for: frame) }
            let buckets = await bucketsTask.value
            guard !Task.isCancelled else { return }
            cachedCPUHistogram = buckets

            guard let camera = cameraManager.connectedCamera else {
                cachedCPUChannelHistograms = nil
                return
            }
            let channelsTask = Task.detached(priority: .userInitiated) {
                HistogramComputer.channelHistograms(for: frame, isColorCamera: camera.isColorCamera, bayerPattern: camera.bayerPattern)
            }
            let channels = await channelsTask.value
            guard !Task.isCancelled else { return }
            cachedCPUChannelHistograms = channels
        }
    }

    // MARK: - Zoom

    private func recenter() {
        blackCenter = cameraManager.stretch.blackPoint
        whiteCenter = cameraManager.stretch.whitePoint
        redBlackCenter = cameraManager.channelStretch.red.blackPoint
        redWhiteCenter = cameraManager.channelStretch.red.whitePoint
        greenBlackCenter = cameraManager.channelStretch.green.blackPoint
        greenWhiteCenter = cameraManager.channelStretch.green.whitePoint
        blueBlackCenter = cameraManager.channelStretch.blue.blackPoint
        blueWhiteCenter = cameraManager.channelStretch.blue.whitePoint
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

    // MARK: - Clipping

    /// Worst-channel clipping when showing Red/Green/Blue separately — a single blown channel
    /// (e.g. a light-polluted orange sky crushing blue) is exactly the case a combined-luma
    /// reading would hide, so this deliberately takes the max rather than an average.
    private var currentClipping: (shadows: Double, highlights: Double)? {
        if showByChannel, let channels = currentChannelHistograms {
            let r = HistogramComputer.clippedFraction(channels.red)
            let g = HistogramComputer.clippedFraction(channels.green)
            let b = HistogramComputer.clippedFraction(channels.blue)
            return (max(r.shadows, g.shadows, b.shadows), max(r.highlights, g.highlights, b.highlights))
        }
        guard let buckets = currentBuckets else { return nil }
        return HistogramComputer.clippedFraction(buckets)
    }

    /// Below ~0.5% of the frame, a few hot pixels or one genuinely black sky-background pixel
    /// trips this on every single frame — not useful information at that level, so the warning
    /// only shows once clipping is actually a meaningful fraction of the image.
    private static let clippingWarningThreshold = 0.005

    @ViewBuilder
    private var clippingWarningView: some View {
        if let clipping = currentClipping {
            let shadowsClipped = clipping.shadows > Self.clippingWarningThreshold
            let highlightsClipped = clipping.highlights > Self.clippingWarningThreshold
            if shadowsClipped || highlightsClipped {
                HStack(spacing: 12) {
                    if shadowsClipped {
                        Label(String(format: "%.1f%% shadows clipped", clipping.shadows * 100), systemImage: "arrow.down.to.line")
                    }
                    if highlightsClipped {
                        Label(String(format: "%.1f%% highlights clipped", clipping.highlights * 100), systemImage: "arrow.up.to.line")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.red)
            }
        }
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

            let clipping = HistogramComputer.clippedFraction(buckets)
            if clipping.shadows > Self.clippingWarningThreshold {
                context.fill(Path(CGRect(x: 0, y: 0, width: max(barWidth, 2), height: size.height)), with: .color(.red.opacity(0.6)))
            }
            if clipping.highlights > Self.clippingWarningThreshold {
                context.fill(Path(CGRect(x: size.width - max(barWidth, 2), y: 0, width: max(barWidth, 2), height: size.height)), with: .color(.red.opacity(0.6)))
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
        .frame(height: 70)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Three overlaid, semi-transparent outline curves (not solid bars, which would just occlude
    /// each other) — the black/white point lines are still drawn on the *combined* domain, since
    /// the stretch itself is a single combined operation regardless of which view is showing.
    private func channelHistogramCanvas(_ channels: (red: [Int], green: [Int], blue: [Int])) -> some View {
        let maxCount = max(channels.red.max() ?? 1, channels.green.max() ?? 1, channels.blue.max() ?? 1, 1)

        func curve(_ buckets: [Int], in size: CGSize) -> Path {
            let barWidth = size.width / CGFloat(buckets.count)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, count) in buckets.enumerated() {
                let height = size.height * CGFloat(count).squareRoot() / CGFloat(maxCount).squareRoot()
                path.addLine(to: CGPoint(x: CGFloat(index) * barWidth, y: size.height - height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            return path
        }

        return Canvas { context, size in
            context.fill(curve(channels.red, in: size), with: .color(.red.opacity(0.35)))
            context.stroke(curve(channels.red, in: size), with: .color(.red), lineWidth: 1)
            context.fill(curve(channels.green, in: size), with: .color(.green.opacity(0.35)))
            context.stroke(curve(channels.green, in: size), with: .color(.green), lineWidth: 1)
            context.fill(curve(channels.blue, in: size), with: .color(.blue.opacity(0.35)))
            context.stroke(curve(channels.blue, in: size), with: .color(.blue), lineWidth: 1)

            let barWidth = size.width / CGFloat(channels.red.count)
            let r = HistogramComputer.clippedFraction(channels.red)
            let g = HistogramComputer.clippedFraction(channels.green)
            let b = HistogramComputer.clippedFraction(channels.blue)
            let shadows = max(r.shadows, g.shadows, b.shadows)
            let highlights = max(r.highlights, g.highlights, b.highlights)
            if shadows > Self.clippingWarningThreshold {
                context.fill(Path(CGRect(x: 0, y: 0, width: max(barWidth, 2), height: size.height)), with: .color(.white.opacity(0.5)))
            }
            if highlights > Self.clippingWarningThreshold {
                context.fill(Path(CGRect(x: size.width - max(barWidth, 2), y: 0, width: max(barWidth, 2), height: size.height)), with: .color(.white.opacity(0.5)))
            }

            let blackX = size.width * cameraManager.stretch.blackPoint
            let whiteX = size.width * cameraManager.stretch.whitePoint
            context.stroke(
                Path { $0.move(to: CGPoint(x: blackX, y: 0)); $0.addLine(to: CGPoint(x: blackX, y: size.height)) },
                with: .color(.white.opacity(0.7)), lineWidth: 1
            )
            context.stroke(
                Path { $0.move(to: CGPoint(x: whiteX, y: 0)); $0.addLine(to: CGPoint(x: whiteX, y: size.height)) },
                with: .color(.white), lineWidth: 1
            )
        }
        .frame(height: 70)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var currentBuckets: [Int]? {
        useMetalRenderer ? cameraManager.gpuHistogramCounts : cachedCPUHistogram
    }

    /// GPU path prefers `CameraManager.gpuChannelHistogramCounts` (`MetalFrameRenderer`'s
    /// `histogramReduceBayerChannels`/`histogramReduceRGB24Channels`); CPU path reads
    /// `cachedCPUHistogram`'s own companion cache, kept current by `body`'s `.task(id:)` — see
    /// that cache's own doc comment for why this isn't computed directly here anymore. `nil` for
    /// a mono camera (nothing to split into channels) either way.
    private var currentChannelHistograms: (red: [Int], green: [Int], blue: [Int])? {
        useMetalRenderer ? cameraManager.gpuChannelHistogramCounts : cachedCPUChannelHistograms
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

    /// Same clamp logic as `blackPointBinding`/`whitePointBinding`, generalized over which of the
    /// three channels a given pair of sliders edits.
    private func channelBlackPointBinding(_ channel: WritableKeyPath<PerChannelStretch, DisplayStretch>) -> Binding<Double> {
        Binding(
            get: { cameraManager.channelStretch[keyPath: channel].blackPoint },
            set: { newValue in
                let whitePoint = cameraManager.channelStretch[keyPath: channel].whitePoint
                cameraManager.channelStretch[keyPath: channel].blackPoint = min(max(newValue, 0), whitePoint - 0.01)
            }
        )
    }

    private func channelWhitePointBinding(_ channel: WritableKeyPath<PerChannelStretch, DisplayStretch>) -> Binding<Double> {
        Binding(
            get: { cameraManager.channelStretch[keyPath: channel].whitePoint },
            set: { newValue in
                let blackPoint = cameraManager.channelStretch[keyPath: channel].blackPoint
                cameraManager.channelStretch[keyPath: channel].whitePoint = max(min(newValue, 1), blackPoint + 0.01)
            }
        )
    }
}
