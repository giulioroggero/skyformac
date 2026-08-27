import AppKit
import SwiftUI

/// A full-size modal for touching up a single already-captured still — a `.fits`/`.png`/`.tiff`
/// capture, or a Lucky Imaging/Live Capture frame exported and reopened here — with GPU-backed
/// color/contrast/curves/sharpen/rotate/crop adjustments (`ImageEditor`, Core Image-based) plus a
/// one-tap "Magic Wand" auto-fix. The single-image counterpart to
/// `PlanetaryPostProcessingView`, which is for stacking a whole `.ser` burst instead — this view
/// has no registration/stacking stage at all, just load → adjust → save.
struct SingleImagePostProcessingView: View {
    let sourceURL: URL
    let sourceDescription: String
    /// Where `onSave`'s result actually lands on disk — just enough for the "Saved as…" banner's
    /// own "Publish to AstroBin…" button to point at the right file, without this view needing to
    /// know about `CameraManager`/`Project` at all.
    let elaboratedImagesFolderURL: URL
    var onSave: (CGImage) async throws -> ElaboratedImage

    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable { case loading, ready, failed }
    @State private var stage: Stage = .loading
    @State private var errorMessage: String?

    /// The loaded source, never mutated — "Reset" and the crop/rotate/color sliders all measure
    /// from this. `Magic Wand` instead mutates `workingImage` (below), so a manual reset can
    /// still get back to the true original even after auto-fixing.
    @State private var originalImage: CGImage?
    /// What every adjustment slider actually renders from — starts equal to `originalImage`,
    /// replaced by `ImageEditor.autoFixed(_:)`'s result when Magic Wand is used, so a further
    /// manual tweak (say, a bit more sharpening) layers on top of the auto-fix instead of
    /// overwriting it.
    @State private var workingImage: CGImage?
    @State private var previewImage: CGImage?
    @State private var renderTask: Task<Void, Never>?

    @State private var adjustments = ImageEditor.Adjustments()
    // Crop expressed as four independent edge insets (0...0.49 each) rather than a draggable
    // rectangle — real crop control with far less UI/gesture code; a live drag-rect selector
    // would be a reasonable follow-up but isn't needed for "allow the user to crop."
    @State private var cropLeft: Double = 0
    @State private var cropRight: Double = 0
    @State private var cropTop: Double = 0
    @State private var cropBottom: Double = 0

    // Preview zoom/pan — lets a sharpen/denoise/star-size result be checked at real pixel scale
    // instead of only ever seeing the whole image shrunk to fit the pane.
    @State private var zoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero

    /// "Split View" compare — stacks the untouched `originalImage` above the live `previewImage`
    /// instead of showing only the edited result, so a subtle adjustment (a touch of denoise, a
    /// small gamma nudge) is actually visible against the source rather than trusted from memory.
    /// Vertical (original on top, edited below), not side-by-side — the preview pane itself is
    /// usually wider than it is tall, so a vertical split keeps each half at a more useful size
    /// than halving the width would.
    @State private var isComparingToOriginal = false
    @State private var isApplyingMagicWand = false
    @State private var isSaving = false
    @State private var savedImage: ElaboratedImage?
    @State private var saveErrorMessage: String?

    /// See `PlanetaryPostProcessingView.fullScreenSize`'s own doc comment — a margin below
    /// `visibleFrame`, not exactly equal to it, so macOS never repositions the presenting window
    /// itself to make room for this sheet's own title bar.
    private var fullScreenSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        return CGSize(width: max(visible.width - 40, 980), height: max(visible.height - 40, 660))
    }

    private var cropRect: CGRect? {
        guard cropLeft > 0 || cropRight > 0 || cropTop > 0 || cropBottom > 0 else { return nil }
        let width = max(0.02, 1 - cropLeft - cropRight)
        let height = max(0.02, 1 - cropTop - cropBottom)
        return CGRect(x: cropLeft, y: cropTop, width: width, height: height)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch stage {
            case .loading:
                Spacer()
                ProgressView("Loading \(sourceURL.lastPathComponent)…")
                Spacer()
            case .failed:
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.red)
                    Text(errorMessage ?? "Something went wrong.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            case .ready:
                readyBody
            }
        }
        .frame(width: fullScreenSize.width, height: fullScreenSize.height)
        .background(.background)
        .task { await loadImage() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Image").font(.headline)
                Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let savedImage {
                Label("Saved as \(savedImage.fileName)", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Button("Publish to AstroBin…", systemImage: "arrow.up.forward.app") {
                    AstroBinPublisher.publish(elaboratedImagesFolderURL.appendingPathComponent(savedImage.fileName))
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if let saveErrorMessage {
                    Text(saveErrorMessage).font(.caption).foregroundStyle(.red)
                }
                Button("Cancel") { dismiss() }
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save as Elaborated Image")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(stage != .ready || previewImage == nil || isSaving)
            }
        }
        .padding(16)
    }

    private var readyBody: some View {
        HSplitView {
            previewPane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    magicWandSection
                    Divider()
                    cropSection
                    Divider()
                    rotateSection
                    Divider()
                    colorSection
                    Divider()
                    cleanUpSection
                    Divider()
                    sharpenSection
                    Divider()
                    astronomyToolsSection
                }
                .padding(16)
            }
            .frame(width: 320)
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            if isComparingToOriginal {
                VStack(spacing: 2) {
                    labeledComparisonImage("Original", image: originalImage)
                    labeledComparisonImage("Edited", image: previewImage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    Color.black
                    if let previewImage {
                        Image(decorative: previewImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(12)
                            .scaleEffect(zoomScale)
                            .offset(zoomOffset)
                            // Pinch-to-zoom (trackpad) and the slider below both drive the same
                            // `zoomScale` — checking a sharpen/denoise/star-size result at real
                            // pixel scale needs more than "fit the whole image in the pane."
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in zoomScale = min(max(1, value), Self.maxZoomScale) }
                            )
                            // Only actually pans once zoomed in — at 1x there's nothing to pan to,
                            // and a plain drag shouldn't fight with anything else on the page.
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        guard zoomScale > 1 else { return }
                                        zoomOffset = CGSize(
                                            width: dragStartOffset.width + value.translation.width,
                                            height: dragStartOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in dragStartOffset = zoomOffset }
                            )
                    } else {
                        ProgressView()
                    }
                }
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            zoomControlBar
        }
    }

    /// One half of the vertical compare split — no zoom/pan gesture of its own (unlike the
    /// single-image pane above): comparing two images at a glance is the point, and each already
    /// gets roughly half the pane's height, which is plenty to judge "did this actually help."
    @ViewBuilder
    private func labeledComparisonImage(_ label: String, image: CGImage?) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else {
                ProgressView()
            }
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private static let maxZoomScale: CGFloat = 8

    private var zoomControlBar: some View {
        HStack {
            Text("Zoom").font(.caption)
            Button {
                withAnimation { resetZoom() }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoomScale <= 1)
            Slider(value: $zoomScale, in: 1...Self.maxZoomScale)
            Button {
                withAnimation { zoomScale = Self.maxZoomScale }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Text(String(format: "%.1fx", zoomScale))
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            if zoomScale != 1 {
                Button("Reset") { withAnimation { resetZoom() } }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .help("Pinch, or drag this slider, to zoom into the preview — drag the image itself to pan once zoomed in.")
    }

    private func resetZoom() {
        zoomScale = 1
        zoomOffset = .zero
        dragStartOffset = .zero
    }

    private var magicWandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto-Fix").font(.title3.bold())
            Text("Analyzes the image and picks color/contrast adjustments automatically — the same technology behind Photos.app's \"Auto Enhance.\" Manual sliders below still apply on top afterward.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    applyMagicWand()
                } label: {
                    if isApplyingMagicWand {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Magic Wand", systemImage: "wand.and.stars")
                    }
                }
                .disabled(isApplyingMagicWand)
                Button("Reset") { reset() }
                    .disabled(isApplyingMagicWand)
                Toggle("Compare to Original", systemImage: "rectangle.split.1x2", isOn: $isComparingToOriginal)
                    .toggleStyle(.button)
                    .help("Show the untouched original stacked above the current edit, instead of only the edit.")
            }
        }
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crop").font(.title3.bold())
            resettableSlider("Left", value: $cropLeft, range: 0...0.49, defaultValue: 0, format: "%.0f%%", displayScale: 100)
            resettableSlider("Right", value: $cropRight, range: 0...0.49, defaultValue: 0, format: "%.0f%%", displayScale: 100)
            resettableSlider("Top", value: $cropTop, range: 0...0.49, defaultValue: 0, format: "%.0f%%", displayScale: 100)
            resettableSlider("Bottom", value: $cropBottom, range: 0...0.49, defaultValue: 0, format: "%.0f%%", displayScale: 100)
        }
    }

    private var rotateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rotate").font(.title3.bold())
            resettableSlider(
                "Angle", value: $adjustments.rotationDegrees, range: -180...180, defaultValue: 0,
                step: 0.5, format: "%.1f°"
            )
            HStack {
                Button("-90°") { adjustments.rotationDegrees -= 90; scheduleRender() }
                Button("+90°") { adjustments.rotationDegrees += 90; scheduleRender() }
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color & Contrast").font(.title3.bold())
            resettableSlider("Brightness", value: $adjustments.brightness, range: -1...1, defaultValue: 0)
            resettableSlider("Contrast", value: $adjustments.contrast, range: 0.25...4, defaultValue: 1)
            resettableSlider("Saturation", value: $adjustments.saturation, range: 0...2, defaultValue: 1)
            resettableSlider("Curve (Gamma)", value: $adjustments.gamma, range: 0.1...4, defaultValue: 1)
            Text("Gamma lifts or crushes midtones without clipping black/white — the one-knob \"curves\" control for a quick touch-up.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var cleanUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean Up").font(.title3.bold())
            resettableSlider("Denoise", value: $adjustments.denoiseAmount, range: 0...1, defaultValue: 0)
            Text("Smooths sensor/read noise out of faint backgrounds — push too far and it starts to soften real detail too.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle("Remove Hot Pixels", isOn: $adjustments.removesHotPixels)
                .onChange(of: adjustments.removesHotPixels) { _, _ in scheduleRender() }
            Text("A median filter that knocks out isolated single-pixel hot pixels/cosmic-ray hits without softening real detail.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var sharpenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sharpen").font(.title3.bold())
            resettableSlider("Strength", value: $adjustments.sharpenIntensity, range: 0...5, defaultValue: 0)
        }
    }

    private var astronomyToolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Astronomy Tools").font(.title3.bold())
            resettableSlider("Remove Green Cast", value: $adjustments.greenCastRemoval, range: 0...1, defaultValue: 0)
            Text("SCNR — caps the green channel at the red/blue average, the standard fix for the green cast stacking software often leaves behind.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            resettableSlider("Reduce Star Size", value: $adjustments.starSizeReduction, range: 0...5, defaultValue: 0)
            Text("Erodes bloated star images down without touching the fainter background/nebulosity around them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            resettableSlider("Shadow Lift", value: $adjustments.shadowLift, range: 0...1, defaultValue: 0)
            Text("Brings out faint nebulosity/dim planetary features hiding in the shadows.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            resettableSlider("Highlight Recovery", value: $adjustments.highlightRecovery, range: 0...1, defaultValue: 0)
            Text("Pulls back a blown-out planetary disk or bright core.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// A slider paired with its own small reset control — every adjustment gets one, not just
    /// the single global "Reset" in the Auto-Fix section, so one parameter can be dialed back
    /// without losing every other tweak already made.
    private func resettableSlider(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double,
        step: Double = 0.01, format: String = "%.2f", displayScale: Double = 1
    ) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(String(format: format, value.wrappedValue * displayScale))
                    .font(.caption.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
                Button {
                    value.wrappedValue = defaultValue
                    scheduleRender()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(value.wrappedValue == defaultValue ? 0.25 : 1)
                .disabled(value.wrappedValue == defaultValue)
                .help("Reset to default")
            }
        }
        .onChange(of: value.wrappedValue) { _, _ in scheduleRender() }
    }

    // MARK: - Pipeline

    private func loadImage() async {
        do {
            let image = try await Task.detached(priority: .userInitiated) {
                try CGImageRenderer.loadDisplayImage(from: sourceURL)
            }.value
            originalImage = image
            workingImage = image
            previewImage = image
            stage = .ready
        } catch {
            errorMessage = "Couldn't open \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            stage = .failed
        }
    }

    /// Not `Task.detached` — `CGImage` isn't `Sendable`-annotated by CoreGraphics (despite being
    /// safe to read from any thread once created), which trips Swift 6's "sending" checker on
    /// every attempt to hand one into a detached task. `ImageEditor.render`/`autoFixed` already
    /// do their actual work on the GPU via Core Image's own Metal-backed `CIContext` — the CPU
    /// side here is just building/dispatching that filter graph, cheap enough (unlike
    /// `PlanetaryPostProcessor`'s hand-written per-pixel Swift loops) that running it directly
    /// inside a plain, cancellable `Task` is fine without also detaching it off the main actor.
    private func scheduleRender() {
        renderTask?.cancel()
        guard let workingImage else { return }
        var adj = adjustments
        adj.cropRect = cropRect
        renderTask = Task {
            guard !Task.isCancelled else { return }
            previewImage = ImageEditor.render(workingImage, with: adj) ?? workingImage
        }
    }

    private func applyMagicWand() {
        guard let originalImage else { return }
        isApplyingMagicWand = true
        Task {
            let fixed = ImageEditor.autoFixed(originalImage)
            isApplyingMagicWand = false
            guard let fixed else { return }
            workingImage = fixed
            // Magic Wand bakes Core Image's own scene-analysis auto-enhance directly into
            // `workingImage`'s pixels — there's no `Adjustments` slot that corresponds to what it
            // actually computed (per-channel exposure, vibrance, tone curve), so the sliders
            // below can't *show* the change. But leaving `adjustments` at whatever it was before
            // is worse: it keeps displaying values that no longer describe anything real (measured
            // against the pre-wand image, now silently stale), which reads as "the wand did
            // nothing" or "these values are wrong." Resetting to identity means the sliders
            // honestly reflect the new baseline — no adjustment on top of it yet — and any further
            // slider tweak still layers on top of the wand's result via `workingImage`.
            adjustments = .identity
            scheduleRender()
        }
    }

    private func reset() {
        workingImage = originalImage
        adjustments = .identity
        cropLeft = 0
        cropRight = 0
        cropTop = 0
        cropBottom = 0
        previewImage = originalImage
    }

    private func save() async {
        guard let previewImage else { return }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }
        do {
            savedImage = try await onSave(previewImage)
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}
