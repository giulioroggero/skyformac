import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// GPU-accelerated single-image touch-up for an already-captured/already-debayered still (a
/// `.fits`/`.png`/`.tiff` capture, or a Lucky Imaging/Live Capture result) — color, curves, crop,
/// sharpen, contrast, rotate, denoise, and a few astrophotography-specific tools (green-cast
/// removal, star-size reduction, hot-pixel cleanup), plus a one-tap "magic wand" auto-fix. Unlike
/// `PlanetaryPostProcessor` (which stacks/aligns a whole `.ser` burst of raw linear frames), this
/// operates on a single already-rendered `CGImage` and leans almost entirely on Core Image's
/// built-in filters — `CIContext` renders through Metal by default on macOS, so every adjustment
/// here runs on the GPU without hand-written Metal kernels, the same way Photos.app's own
/// adjustment sliders do. The one exception (`removesGreenCast`) has no Core Image built-in
/// equivalent and runs as a small CPU pixel pass instead — see its own doc comment below.
enum ImageEditor {
    /// One control per adjustment, all independent and all reversible back to their own default
    /// — `render(_:with:)` composes them in a fixed order (rotate → crop → hot-pixel cleanup →
    /// green-cast removal → denoise → color/contrast/gamma → highlights/shadows → star-size
    /// reduction → sharpen) regardless of which the user actually touched.
    struct Adjustments: Equatable, Sendable, Codable {
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
        /// 0...5 — widened from an earlier 0...2 ("increase sharp strength"); scales both
        /// `CIUnsharpMask`'s intensity *and* radius together so pushing this higher visibly
        /// sharpens more instead of flattening out.
        var sharpenIntensity: Double = 0
        /// `CINoiseReduction`'s own `inputNoiseLevel` — smooths sensor/read noise in faint
        /// backgrounds. 0 = off.
        var denoiseAmount: Double = 0
        /// `CIMedianFilter` — a "clean" pass that knocks out isolated single-pixel hot
        /// pixels/cosmic-ray hits without softening real detail the way a blur would, since a
        /// median filter only replaces a pixel that's genuinely an outlier among its neighbors.
        var removesHotPixels: Bool = false
        /// The "puntini colorati"/chroma-noise fix — random red/green speckle in the background,
        /// distinct from `denoiseAmount` (which smooths *luminance* noise and would have to blur
        /// real detail to touch this) and `greenCastRemoval` (a systematic per-pixel green
        /// excess, not per-pixel color-channel randomness). 0...1 scales a Gaussian blur radius
        /// applied to *only* the image's color, not its luminosity — see `render(_:with:)`'s own
        /// `CIColorBlendMode` step for how. 0 = off.
        var chromaNoiseReduction: Double = 0
        /// SCNR ("Subtractive Chromatic Noise Reduction") — a standard astrophotography fix for
        /// the green color cast/blotches stacking software often leaves behind, by capping each
        /// pixel's green channel at the average of its red and blue. 0...1 blends between the
        /// original green (0) and the fully-capped result (1).
        var greenCastRemoval: Double = 0
        /// `CIMorphologyMinimum`'s `inputRadius` — eroding bright blobs shrinks bloated star
        /// images (a common finishing touch on a stacked deep-sky or planetary image) without
        /// touching the fainter background/nebulosity around them. 0 = off.
        var starSizeReduction: Double = 0
        /// `CIHighlightShadowAdjust`'s `inputShadowAmount` — lifts shadow detail (faint
        /// nebulosity, dim planetary features) without touching highlights. 0...1, 0 = off.
        var shadowLift: Double = 0
        /// The same filter's `inputHighlightAmount`, inverted (0 = untouched, 1 = highlights
        /// pulled all the way down) — recovers a blown-out planetary disk/bright core.
        var highlightRecovery: Double = 0
        /// `CIColorPosterize`'s `inputLevels` — a stylistic finishing effect (flattens each
        /// channel to a handful of discrete bands, the classic "posterize" look), not a
        /// restoration tool like everything else here. `0` = off; otherwise `2...32` bands.
        var posterizeLevels: Double = 0

        static let identity = Adjustments()

        // Hand-rolled `Codable` for exactly one reason: an already-saved elaborated image's
        // `planetarySettings.singleShotAdjustments` (or a `CaptureRecord`-style settings blob
        // anywhere else this struct is embedded) predating `posterizeLevels` has no such key in
        // its JSON at all — real bug, confirmed live: `Project`'s decode is all-or-nothing, so a
        // `keyNotFound` on this one field failed the *entire* project's decode, and
        // `ProjectStore.loadAllProjects()` silently skips a project whose `project.json` fails to
        // decode (see its own doc comment) — several real, on-disk, otherwise-perfectly-valid
        // projects with an older elaborated image simply vanished from "All Projects." Same
        // "`decodeIfPresent` a newer field, default it for older saved data" fix
        // `CaptureRecord.rating`'s own custom `init(from:)` already established this session for
        // the identical failure mode.
        enum CodingKeys: String, CodingKey {
            case rotationDegrees, cropRect, brightness, contrast, saturation, gamma, sharpenIntensity,
                 denoiseAmount, removesHotPixels, chromaNoiseReduction, greenCastRemoval, starSizeReduction,
                 shadowLift, highlightRecovery, posterizeLevels
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rotationDegrees = try container.decode(Double.self, forKey: .rotationDegrees)
            cropRect = try container.decodeIfPresent(CGRect.self, forKey: .cropRect)
            brightness = try container.decode(Double.self, forKey: .brightness)
            contrast = try container.decode(Double.self, forKey: .contrast)
            saturation = try container.decode(Double.self, forKey: .saturation)
            gamma = try container.decode(Double.self, forKey: .gamma)
            sharpenIntensity = try container.decode(Double.self, forKey: .sharpenIntensity)
            denoiseAmount = try container.decode(Double.self, forKey: .denoiseAmount)
            removesHotPixels = try container.decode(Bool.self, forKey: .removesHotPixels)
            chromaNoiseReduction = try container.decode(Double.self, forKey: .chromaNoiseReduction)
            greenCastRemoval = try container.decode(Double.self, forKey: .greenCastRemoval)
            starSizeReduction = try container.decode(Double.self, forKey: .starSizeReduction)
            shadowLift = try container.decode(Double.self, forKey: .shadowLift)
            highlightRecovery = try container.decode(Double.self, forKey: .highlightRecovery)
            posterizeLevels = try container.decodeIfPresent(Double.self, forKey: .posterizeLevels) ?? 0
        }

        init(
            rotationDegrees: Double = 0, cropRect: CGRect? = nil, brightness: Double = 0, contrast: Double = 1,
            saturation: Double = 1, gamma: Double = 1, sharpenIntensity: Double = 0, denoiseAmount: Double = 0,
            removesHotPixels: Bool = false, chromaNoiseReduction: Double = 0, greenCastRemoval: Double = 0,
            starSizeReduction: Double = 0, shadowLift: Double = 0, highlightRecovery: Double = 0, posterizeLevels: Double = 0
        ) {
            self.rotationDegrees = rotationDegrees
            self.cropRect = cropRect
            self.brightness = brightness
            self.contrast = contrast
            self.saturation = saturation
            self.gamma = gamma
            self.sharpenIntensity = sharpenIntensity
            self.denoiseAmount = denoiseAmount
            self.removesHotPixels = removesHotPixels
            self.chromaNoiseReduction = chromaNoiseReduction
            self.greenCastRemoval = greenCastRemoval
            self.starSizeReduction = starSizeReduction
            self.shadowLift = shadowLift
            self.highlightRecovery = highlightRecovery
            self.posterizeLevels = posterizeLevels
        }
    }

    enum RenderError: Error { case unreadableImage }

    /// A shared `CIContext` — cheap to reuse across renders (it owns the Metal command queue/
    /// pipeline cache Core Image builds under the hood), expensive to recreate per call.
    /// `nonisolated(unsafe)` — `CIContext` isn't `Sendable`-annotated by Core Image despite being
    /// documented as safe to use concurrently from multiple threads; this is the same kind of
    /// annotated-but-actually-safe case as elsewhere in this codebase (e.g. `CGImage`).
    private nonisolated(unsafe) static let context = CIContext()

    /// Renders `image` with `adjustments` applied. `nil` only if Core Image itself fails to
    /// produce a bitmap (e.g. a degenerate zero-size crop).
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

        if adjustments.removesHotPixels {
            let median = CIFilter.median()
            median.inputImage = ciImage
            if let output = median.outputImage { ciImage = output }
        }

        if adjustments.denoiseAmount > 0 {
            // `CINoiseReduction`'s own `inputNoiseLevel` tops out doing much beyond ~0.1 in a
            // single pass before `inputSharpness` (detail retention) starts fighting it back to
            // a standstill — mapping the slider's full `0...1` to that alone left "max denoise"
            // barely stronger than "a little." Widening the noise-level range to 0.3, easing
            // sharpness down as the slider goes up (less detail retention fights the smoothing
            // less), and compounding a second pass in the top half of the range all push the
            // achievable strength well past what a single default-sharpness pass could ever do.
            let passes = adjustments.denoiseAmount > 0.5 ? 2 : 1
            let noiseLevel = Float(0.02 + adjustments.denoiseAmount * 0.28)
            let sharpness = Float(max(0.05, 0.4 - adjustments.denoiseAmount * 0.35))
            for _ in 0..<passes {
                let noiseReduction = CIFilter.noiseReduction()
                noiseReduction.inputImage = ciImage
                noiseReduction.noiseLevel = noiseLevel
                noiseReduction.sharpness = sharpness
                if let output = noiseReduction.outputImage { ciImage = output }
            }
        }

        if adjustments.chromaNoiseReduction > 0 {
            // The standard "blur only the color, keep the luminance sharp" chroma-noise recipe:
            // blur a copy of the image heavily, then recombine using `CIColorBlendMode` — it
            // composites the *top* image's hue/saturation with the *background* image's
            // luminosity (the same math Photoshop's "Color" blend mode uses), so the result keeps
            // every bit of real structural detail (stars, the object's own edges) from the
            // unblurred original while the red/green color speckle a blur naturally averages away
            // disappears. Scaling the blur radius directly by the slider (rather than a separate
            // blend-opacity) is what makes `0` a true no-op: at radius 0 the "blurred" copy is
            // just the original again, so blending it with itself changes nothing.
            let radius = Float(adjustments.chromaNoiseReduction * 10)
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = ciImage.clampedToExtent()
            blur.radius = radius
            if let blurred = blur.outputImage?.cropped(to: ciImage.extent) {
                let colorBlend = CIFilter.colorBlendMode()
                colorBlend.inputImage = blurred
                colorBlend.backgroundImage = ciImage
                if let output = colorBlend.outputImage { ciImage = output.cropped(to: ciImage.extent) }
            }
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

        if adjustments.shadowLift > 0 || adjustments.highlightRecovery > 0 {
            let highlightShadow = CIFilter.highlightShadowAdjust()
            highlightShadow.inputImage = ciImage
            highlightShadow.shadowAmount = Float(adjustments.shadowLift)
            highlightShadow.highlightAmount = Float(1 - adjustments.highlightRecovery)
            if let output = highlightShadow.outputImage { ciImage = output }
        }

        if adjustments.starSizeReduction > 0 {
            // `CIMorphologyMinimum` pads its output extent by roughly its own radius (it needs
            // neighborhood pixels beyond the original edges) — cropping back to the pre-erosion
            // extent keeps the output the same size as everything else in this pipeline instead
            // of growing a black border around it.
            let extentBeforeErosion = ciImage.extent
            let erode = CIFilter.morphologyMinimum()
            erode.inputImage = ciImage
            erode.radius = Float(adjustments.starSizeReduction)
            if let output = erode.outputImage { ciImage = output.cropped(to: extentBeforeErosion) }
        }

        if adjustments.sharpenIntensity > 0 {
            let sharpen = CIFilter.unsharpMask()
            sharpen.inputImage = ciImage
            sharpen.radius = Float(1.5 + adjustments.sharpenIntensity)
            sharpen.intensity = Float(adjustments.sharpenIntensity)
            if let output = sharpen.outputImage { ciImage = output }
        }

        if adjustments.posterizeLevels > 0 {
            let posterize = CIFilter.colorPosterize()
            posterize.inputImage = ciImage
            posterize.levels = Float(adjustments.posterizeLevels)
            if let output = posterize.outputImage { ciImage = output }
        }

        // `cropped(to:)`/the morphology filters above only change `extent`, not the pixel origin
        // CI tracks internally — rendering from `ciImage.extent` (not the original image's) is
        // what actually produces a correctly-sized bitmap instead of silently ignoring them.
        guard let rendered = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return adjustments.greenCastRemoval > 0 ? applyGreenCastRemoval(rendered, amount: adjustments.greenCastRemoval) : rendered
    }

    /// SCNR: caps each pixel's green channel at the average of its red and blue, blended by
    /// `amount` — the standard astrophotography fix for the green color cast/blotches stacking
    /// software often leaves behind (most star colors and background sky have no reason to be
    /// green-dominant, so a green channel brighter than both its neighbors is almost always
    /// exactly this artifact, not real signal). No Core Image built-in filter does this
    /// (`CIColorControls`/`CIColorMatrix` operate per-channel independently, not as a per-pixel
    /// min() across channels), so this runs as a plain CPU pass over the final rendered 8-bit
    /// bitmap instead — a single read-modify-write over `width * height` pixels, cheap enough
    /// (unlike `PlanetaryPostProcessor`'s per-frame stacking work) to not need the GPU.
    private static func applyGreenCastRemoval(_ image: CGImage, amount: Double) -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let drawContext = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        drawContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let blend = min(max(amount, 0), 1)
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[pixel])
            let green = Double(pixels[pixel + 1])
            let blue = Double(pixels[pixel + 2])
            let capped = min(green, (red + blue) / 2)
            pixels[pixel + 1] = UInt8(green + (capped - green) * blend)
        }
        return drawContext.makeImage() ?? image
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

    /// "Allow to center the object in the image" — finds `image`'s own brightness-weighted
    /// centroid (the same intensity-weighted-sum idea `PlanetaryPostProcessor.centroid(ofLuminance:...)`
    /// uses for registration, just run once here directly on the finished image rather than per
    /// burst frame) and translates the whole image so that point lands exactly in the middle.
    /// `nil` only if `image` is degenerate (zero size, or genuinely all-black — nothing for a
    /// brightness centroid to even find).
    static func centerObject(_ image: CGImage) -> CGImage? {
        guard let centroid = luminanceCentroid(of: image) else { return nil }
        let center = CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2)
        // `centroid`/`center` are both in this app's usual top-left-origin, row-major terms
        // (matching `luminanceCentroid`'s own raw-buffer reading below) — Core Image's own
        // coordinate space has its origin at the bottom-left instead, so the Y component of the
        // translation needs flipping to actually move the object *down* when its centroid sits
        // above center in top-left terms (same flip `render(_:with:)`'s own crop-rect handling
        // already does converting the other direction).
        let dx = center.x - centroid.x
        let dy = centroid.y - center.y
        let ciImage = CIImage(cgImage: image)
        let translated = ciImage.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        // `.clampedToExtent()` extends the nearest edge pixels to fill whatever gap the shift
        // opens up at the trailing edge, rather than leaving it transparent/black — in practice
        // that's background sky, not a hard edge worth calling attention to.
        let filled = translated.clampedToExtent().cropped(to: ciImage.extent)
        return context.createCGImage(filled, from: ciImage.extent)
    }

    /// Plain intensity-weighted centroid over every pixel's own luma, in this app's usual
    /// top-left-origin/row-major terms. Reads back through a throwaway `CGContext` (the same
    /// "redraw into a raw buffer" approach `applyGreenCastRemoval` already uses) rather than a
    /// GPU pass — a single one-shot call on an already-finished image, not a per-frame hot loop
    /// worth a Core Image filter graph for.
    private static func luminanceCentroid(of image: CGImage) -> CGPoint? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let drawContext = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        drawContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sumI: Double = 0
        var sumX: Double = 0
        var sumY: Double = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luma = 0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1]) + 0.114 * Double(pixels[offset + 2])
                sumI += luma
                sumX += luma * Double(x)
                sumY += luma * Double(y)
            }
        }
        guard sumI > 0 else { return nil }
        return CGPoint(x: sumX / sumI, y: sumY / sumI)
    }
}
