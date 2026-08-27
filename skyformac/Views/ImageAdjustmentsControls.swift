import SwiftUI

/// A slider paired with its own small reset control, and its label on its own line above the
/// slider (not `LabeledContent`'s side-by-side layout — a longer label like "Chroma Noise
/// Reduction" was squeezing the slider itself down to a sliver). Shared by
/// `SingleImagePostProcessingView`'s crop/rotate sections and `ImageAdjustmentsControls` below,
/// rather than each keeping its own private copy of this same row.
struct ResettableAdjustmentSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let defaultValue: Double
    var step: Double = 0.01
    var format: String = "%.2f"
    var displayScale: Double = 1
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption)
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(String(format: format, value * displayScale))
                    .font(.caption.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
                Button {
                    value = defaultValue
                    onChange()
                } label: {
                    Image(systemName: "arrow.counterclockwise.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(value == defaultValue ? 0.25 : 1)
                .disabled(value == defaultValue)
                .help("Reset to default")
            }
        }
        .onChange(of: value) { _, _ in onChange() }
    }
}

/// Every `ImageEditor.Adjustments` control that isn't crop/rotate (both specific to
/// `SingleImagePostProcessingView` — cropping/rotating a finished planetary stack has little
/// value the way touching up its tone/noise/sharpness does) — Color & Contrast, Clean Up,
/// Sharpen, and Astronomy Tools, shared verbatim by `SingleImagePostProcessingView`'s own
/// sections and `PlanetaryPostProcessingView`'s "Single Shot" tab instead of two independently
/// maintained copies of the same ~15 sliders ("in single shot use the edit functionalities of
/// the edit image from capture page — don't duplicate the code").
struct ImageAdjustmentsControls: View {
    @Binding var adjustments: ImageEditor.Adjustments
    /// Called after every change — each caller decides what "apply" actually means for it
    /// (`SingleImagePostProcessingView.scheduleRender()`,
    /// `PlanetaryPostProcessingView.applySingleShotAdjustments()`).
    var onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            colorSection
            Divider()
            cleanUpSection
            Divider()
            sharpenSection
            Divider()
            astronomyToolsSection
            Divider()
            stylizeSection
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color & Contrast").font(.title3.bold())
            slider("Brightness", value: $adjustments.brightness, range: -1...1, defaultValue: 0)
            slider("Contrast", value: $adjustments.contrast, range: 0.25...4, defaultValue: 1)
            slider("Saturation", value: $adjustments.saturation, range: 0...2, defaultValue: 1)
            slider("Curve (Gamma)", value: $adjustments.gamma, range: 0.1...4, defaultValue: 1)
            Text("Gamma lifts or crushes midtones without clipping black/white — the one-knob \"curves\" control for a quick touch-up.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var cleanUpSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clean Up").font(.title3.bold())
            slider("Denoise", value: $adjustments.denoiseAmount, range: 0...1, defaultValue: 0)
            Text("Smooths sensor/read noise out of faint backgrounds — push too far and it starts to soften real detail too.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            slider("Chroma Noise Reduction", value: $adjustments.chromaNoiseReduction, range: 0...1, defaultValue: 0)
            Text("Cleans up the colored speckle (\"puntini colorati\") long exposures/high gain leave in the background — blurs only the color, not the brightness, so stars and real detail stay sharp.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle("Remove Hot Pixels", isOn: $adjustments.removesHotPixels)
                .onChange(of: adjustments.removesHotPixels) { _, _ in onChange() }
            Text("A median filter that knocks out isolated single-pixel hot pixels/cosmic-ray hits without softening real detail.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var sharpenSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sharpen").font(.title3.bold())
            slider("Strength", value: $adjustments.sharpenIntensity, range: 0...5, defaultValue: 0)
        }
    }

    private var astronomyToolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Astronomy Tools").font(.title3.bold())
            slider("Remove Green Cast", value: $adjustments.greenCastRemoval, range: 0...1, defaultValue: 0)
            Text("SCNR — caps the green channel at the red/blue average, the standard fix for the green cast stacking software often leaves behind.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            slider("Reduce Star Size", value: $adjustments.starSizeReduction, range: 0...5, defaultValue: 0)
            Text("Erodes bloated star images down without touching the fainter background/nebulosity around them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            slider("Shadow Lift", value: $adjustments.shadowLift, range: 0...1, defaultValue: 0)
            Text("Brings out faint nebulosity/dim planetary features hiding in the shadows.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            slider("Highlight Recovery", value: $adjustments.highlightRecovery, range: 0...1, defaultValue: 0)
            Text("Pulls back a blown-out planetary disk or bright core.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// A stylistic finishing effect, not a restoration tool like everything above — its own
    /// section so it doesn't read as "part of cleaning the image up."
    private var stylizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stylize").font(.title3.bold())
            ResettableAdjustmentSlider(
                label: "Posterize", value: $adjustments.posterizeLevels, range: 0...32, defaultValue: 0,
                step: 1, format: "%.0f", onChange: onChange
            )
            Text("Flattens each color channel to a handful of discrete bands — a stylized look, off (0) by default.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func slider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double) -> some View {
        ResettableAdjustmentSlider(label: label, value: value, range: range, defaultValue: defaultValue, onChange: onChange)
    }
}
