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

    @State private var isApplyingMagicWand = false
    @State private var isSaving = false
    @State private var savedImage: ElaboratedImage?
    @State private var saveErrorMessage: String?

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
                    sharpenSection
                }
                .padding(16)
            }
            .frame(width: 320)
        }
    }

    private var previewPane: some View {
        ZStack {
            Color.black
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else {
                ProgressView()
            }
        }
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
            }
        }
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crop").font(.title3.bold())
            cropSlider("Left", value: $cropLeft)
            cropSlider("Right", value: $cropRight)
            cropSlider("Top", value: $cropTop)
            cropSlider("Bottom", value: $cropBottom)
        }
    }

    private func cropSlider(_ label: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack {
                Slider(value: value, in: 0...0.49, step: 0.01)
                Text("\(Int(value.wrappedValue * 100))%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
        }
        .onChange(of: value.wrappedValue) { _, _ in scheduleRender() }
    }

    private var rotateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rotate").font(.title3.bold())
            HStack {
                Slider(value: $adjustments.rotationDegrees, in: -180...180, step: 0.5)
                Text(String(format: "%.1f°", adjustments.rotationDegrees)).font(.caption.monospacedDigit()).frame(width: 50, alignment: .trailing)
            }
            .onChange(of: adjustments.rotationDegrees) { _, _ in scheduleRender() }
            HStack {
                Button("-90°") { adjustments.rotationDegrees -= 90; scheduleRender() }
                Button("+90°") { adjustments.rotationDegrees += 90; scheduleRender() }
                Button("Reset") { adjustments.rotationDegrees = 0; scheduleRender() }
            }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color & Contrast").font(.title3.bold())
            LabeledContent("Brightness") {
                Slider(value: $adjustments.brightness, in: -1...1, step: 0.01)
            }
            .onChange(of: adjustments.brightness) { _, _ in scheduleRender() }
            LabeledContent("Contrast") {
                Slider(value: $adjustments.contrast, in: 0.25...4, step: 0.01)
            }
            .onChange(of: adjustments.contrast) { _, _ in scheduleRender() }
            LabeledContent("Saturation") {
                Slider(value: $adjustments.saturation, in: 0...2, step: 0.01)
            }
            .onChange(of: adjustments.saturation) { _, _ in scheduleRender() }
            LabeledContent("Curve (Gamma)") {
                Slider(value: $adjustments.gamma, in: 0.1...4, step: 0.01)
            }
            .onChange(of: adjustments.gamma) { _, _ in scheduleRender() }
            Text("Gamma lifts or crushes midtones without clipping black/white — the one-knob \"curves\" control for a quick touch-up.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var sharpenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sharpen").font(.title3.bold())
            Slider(value: $adjustments.sharpenIntensity, in: 0...2, step: 0.01)
                .onChange(of: adjustments.sharpenIntensity) { _, _ in scheduleRender() }
        }
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
