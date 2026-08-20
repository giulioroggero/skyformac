import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// GPU-accelerated single-image touch-up for an already-captured/already-debayered still (a
/// `.fits`/`.png`/`.tiff` capture, or a Lucky Imaging/Live Capture result) — color, curves, crop,
/// sharpen, contrast, and rotate, plus a one-tap "magic wand" auto-fix. Unlike
/// `PlanetaryPostProcessor` (which stacks/aligns a whole `.ser` burst of raw linear frames), this
/// operates on a single already-rendered `CGImage` and leans entirely on Core Image's built-in
/// filters — `CIContext` renders through Metal by default on macOS, so every adjustment here runs
/// on the GPU without hand-written Metal kernels, the same way Photos.app's own adjustment
/// sliders do.
enum ImageEditor {
    /// One slider per adjustment, all independent — `render(_:with:)` composes them in a fixed
    /// order (rotate → crop → color/contrast/gamma → sharpen) regardless of which the user
    /// actually touched.
    struct Adjustments: Equatable, Sendable {
        var rotationDegrees: Double = 0
        /// Normalized (`0...1`, top-left origin, matching `CaptureRecord`/`PlanetaryPostProcessor`
        /// crop conventions elsewhere in this app), applied to the image *after* rotation — `nil`
        /// (the default) keeps the full frame.
        var cropRect: CGRect?
        var brightness: Double = 0 // -1...1, CIColorControls' own range
        var contrast: Double = 1 // 0.25...4, 1 = unchanged
        var saturation: Double = 1 // 0...2, 1 = unchanged
        /// A single-knob midtone curve (`CIGammaAdjust`) — the "curves" ask, scoped to the one
        /// control that actually matters for a quick touch-up (brighten/darken midtones without
        /// clipping black/white) rather than a full multi-point spline editor.
        var gamma: Double = 1 // 0.1...4, 1 = unchanged
        var sharpenIntensity: Double = 0 // 0...2, 0 = off

        static let identity = Adjustments()
    }

    /// A shared `CIContext` — cheap to reuse across renders (it owns the Metal command queue/
    /// pipeline cache Core Image builds under the hood), expensive to recreate per call.
    private static let context = CIContext()

    /// Renders `image` with `adjustments` applied, entirely via Core Image (GPU-backed). `nil`
    /// only if Core Image itself fails to produce a bitmap (e.g. a degenerate zero-size crop).
    static func render(_ image: CGImage, with adjustments: Adjustments) -> CGImage? {
        var ciImage = CIImage(cgImage: image)

        if adjustments.rotationDegrees != 0 {
            let radians = adjustments.rotationDegrees * .pi / 180
            ciImage = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))
        }

        if let cropRect = adjustments.cropRect, cropRect.width > 0.01, cropRect.height > 0.01 {
            let extent = ciImage.extent
            let pixelRect = CGRect(
                x: extent.minX + cropRect.minX * extent.width,
                y: extent.minY + (1 - cropRect.maxY) * extent.height,
                width: cropRect.width * extent.width,
                height: cropRect.height * extent.height
            ).intersection(extent)
            guard !pixelRect.isEmpty else { return nil }
            ciImage = ciImage.cropped(to: pixelRect)
        }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = ciImage
        colorControls.brightness = Float(adjustments.brightness)
        colorControls.contrast = Float(adjustments.contrast)
        colorControls.saturation = Float(adjustments.saturation)
        if let output = colorControls.outputImage { ciImage = output }

        if adjustments.gamma != 1 {
            let gammaFilter = CIFilter.gammaAdjust()
            gammaFilter.inputImage = ciImage
            gammaFilter.power = Float(adjustments.gamma)
            if let output = gammaFilter.outputImage { ciImage = output }
        }

        if adjustments.sharpenIntensity > 0 {
            let sharpen = CIFilter.unsharpMask()
            sharpen.inputImage = ciImage
            sharpen.radius = 2.5
            sharpen.intensity = Float(adjustments.sharpenIntensity)
            if let output = sharpen.outputImage { ciImage = output }
        }

        // `cropped(to:)` above only changes `extent`, not the pixel origin CI tracks internally —
        // rendering from `ciImage.extent` (not the original image's) is what actually produces a
        // bitmap sized to the crop instead of the full original frame with the crop silently
        // ignored.
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    /// The "magic wand" — Core Image's own scene-analysis auto-enhance (`CIImage
    /// .autoAdjustmentFilters()`, the same technology behind Photos.app's one-tap "Auto Enhance"),
    /// composed directly rather than mapped back into `Adjustments`' own sliders since Core
    /// Image's analysis picks parameters (e.g. per-channel color balance) `Adjustments` has no
    /// slot for. Returns the auto-enhanced image directly — `render(_:with:)` can still be
    /// applied on top of its result for further manual tweaks (crop, rotate, extra sharpen).
    static func autoFixed(_ image: CGImage) -> CGImage? {
        var ciImage = CIImage(cgImage: image)
        let filters = ciImage.autoAdjustmentFilters(options: [.enhance: true, .redEye: false])
        for filter in filters {
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            if let output = filter.outputImage { ciImage = output }
        }
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
}
