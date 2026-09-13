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
    /// green-cast removal → denoise → white balance → color/contrast/gamma/vibrance →
    /// highlights/shadows → star-size reduction → sharpen) regardless of which the user actually
    /// touched. Extracted to the top-level `ImageAdjustments` in `PlanetaryElaborationSnapshot.swift`
    /// so `ObservationModels.swift` can share it with the iOS Remote target.
    typealias Adjustments = ImageAdjustments

    enum RenderError: Error { case unreadableImage }

    /// A shared `CIContext` — cheap to reuse across renders (it owns the Metal command queue/
    /// pipeline cache Core Image builds under the hood), expensive to recreate per call.
    /// `nonisolated(unsafe)` — `CIContext` isn't `Sendable`-annotated by Core Image despite being
    /// documented as safe to use concurrently from multiple threads; this is the same kind of
    /// annotated-but-actually-safe case as elsewhere in this codebase (e.g. `CGImage`).
    private nonisolated(unsafe) static let context = CIContext()

    /// Renders `image` with `adjustments` applied. `nil` only if Core Image itself fails to
    /// produce a bitmap (e.g. a degenerate zero-size crop).
    ///
    /// - Parameter starMask: An optional precomputed mask from `computeStarMask(for:)`, scoping
    ///   `starSizeReduction` to just the star locations it marks rather than eroding the whole
    ///   image uniformly. `nil` (the default) keeps the old whole-image behavior — every existing
    ///   caller not yet computing a mask keeps compiling and rendering unchanged. Deliberately not
    ///   computed *inside* this function: `StarDetector.detectStars` runs a synchronous, possibly-
    ///   slow Vision request, and `render` is called on every single slider tweak for a live
    ///   preview — callers compute a mask once (e.g. after loading the image, or after Magic Wand/
    ///   Center Object/Remove Background Gradient change its pixels) and pass the same mask into
    ///   every subsequent render instead.
    static func render(_ image: CGImage, with adjustments: Adjustments, starMask: CGImage? = nil) -> CGImage? {
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

        // Snapshot before the whole "Color & Contrast" block (white balance → brightness/
        // contrast/saturation → vibrance → gamma → highlights/shadows) — if `protectBackground`
        // is on, this is blended back in afterward wherever the *original* image was near-black,
        // so raising Brightness/Contrast/etc. can't lift a planet's black sky background along
        // with it. See the blend below (right after highlightShadow) for why this is deliberately
        // one mask over the whole block, not each slider independently.
        let preColorAdjustmentImage = ciImage

        if adjustments.warmth != 0 || adjustments.tint != 0 {
            // Standard "re-render as if captured under a different illuminant" white-balance
            // trick — `inputNeutral` is a fixed reference point (an arbitrary but consistent
            // 6500K/0 daylight baseline); moving `inputTargetNeutral` *below* it warms the
            // result (targeting a cooler assumed light source makes the filter compensate
            // toward orange), moving it *above* cools it. Tint's green/magenta axis works the
            // same way on the y component. Scaled to comfortably visible but not extreme ranges
            // (±1500K, ±50) across the full -1...1 slider.
            let temperatureAndTint = CIFilter.temperatureAndTint()
            temperatureAndTint.inputImage = ciImage
            temperatureAndTint.neutral = CIVector(x: 6500, y: 0)
            temperatureAndTint.targetNeutral = CIVector(
                x: 6500 - adjustments.warmth * 1500, y: adjustments.tint * 50
            )
            if let output = temperatureAndTint.outputImage { ciImage = output }
        }

        let colorControls = CIFilter.colorControls()
        colorControls.inputImage = ciImage
        colorControls.brightness = Float(adjustments.brightness)
        colorControls.contrast = Float(adjustments.contrast)
        colorControls.saturation = Float(adjustments.saturation)
        if let output = colorControls.outputImage { ciImage = output }

        if adjustments.vibrance != 0 {
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = ciImage
            vibrance.amount = Float(adjustments.vibrance)
            if let output = vibrance.outputImage { ciImage = output }
        }

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

        if adjustments.protectBackground {
            ciImage = maskedByBrightness(adjusted: ciImage, original: preColorAdjustmentImage)
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
            if let eroded = erode.outputImage?.cropped(to: extentBeforeErosion) {
                if let starMask {
                    // Scoped to just the star locations `starMask` marks (white = star, feathered
                    // to black elsewhere) — `CIBlendWithMask` picks `eroded` wherever the mask is
                    // white and the untouched `ciImage` wherever it's black, so nebulosity/galaxy
                    // structure away from any detected star is left completely alone instead of
                    // being eroded right along with the stars the way the old whole-image pass did.
                    let blend = CIFilter.blendWithMask()
                    blend.inputImage = eroded
                    blend.backgroundImage = ciImage
                    blend.maskImage = CIImage(cgImage: starMask)
                    if let output = blend.outputImage { ciImage = output.cropped(to: extentBeforeErosion) }
                } else {
                    ciImage = eroded
                }
            }
        }

        if adjustments.deconvolutionSharpen > 0 {
            ciImage = richardsonLucyDeconvolve(ciImage, amount: adjustments.deconvolutionSharpen)
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

    /// "Protect Background" — blends `adjusted` (the image after the whole Color & Contrast
    /// block) back toward `original` (the same image just before it) wherever `original` was
    /// near-black, so a planet/star field's genuinely empty sky background can't be lifted toward
    /// gray by Brightness/Contrast/Gamma/etc. the way it otherwise would be (`CIColorControls` and
    /// friends operate on every pixel uniformly, background included — there's no "only the
    /// subject" concept built into any of them). Masking the whole block as one unit, from a
    /// single snapshot taken *before* any of it ran, rather than masking each slider independently
    /// — `original`'s own luminance is a stable reference the whole time; masking against a
    /// *moving* target (each filter's own output) would fight the very brightening/darkening
    /// that's the point of these controls in the first place.
    ///
    /// Deliberately an additive blend, not a multiplicative gray-world rescale — the mask is a
    /// smooth two-point threshold (`CIToneCurve`) on `original`'s own luminance: fully protected
    /// (mask = 0, `original` wins) at or below 2%, fully adjusted (mask = 1, `adjusted` wins) at
    /// or above 8%, smoothly feathered in between so there's no hard edge around the subject.
    /// Those two thresholds are fixed, not user-adjustable — a real astrophoto's sky background
    /// sits far below 2% and any real subject (a planetary disk, a star, actual nebulosity) clears
    /// 8% quickly, so this needs no per-image tuning for the cases it's meant for.
    private static func maskedByBrightness(adjusted: CIImage, original: CIImage) -> CIImage {
        let luminanceWeights = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        let luminanceMatrix = CIFilter.colorMatrix()
        luminanceMatrix.inputImage = original
        luminanceMatrix.rVector = luminanceWeights
        luminanceMatrix.gVector = luminanceWeights
        luminanceMatrix.bVector = luminanceWeights
        luminanceMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        guard let luminanceImage = luminanceMatrix.outputImage else { return adjusted }

        let toneCurve = CIFilter.toneCurve()
        toneCurve.inputImage = luminanceImage
        toneCurve.point0 = CGPoint(x: 0, y: 0)
        toneCurve.point1 = CGPoint(x: 0.02, y: 0)
        toneCurve.point2 = CGPoint(x: 0.08, y: 1)
        toneCurve.point3 = CGPoint(x: 0.5, y: 1)
        toneCurve.point4 = CGPoint(x: 1, y: 1)
        guard let maskImage = toneCurve.outputImage else { return adjusted }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = adjusted
        blend.backgroundImage = original
        blend.maskImage = maskImage
        return blend.outputImage?.cropped(to: adjusted.extent) ?? adjusted
    }

    /// A small, fixed number of Richardson-Lucy deconvolution iterations, modeling the blur as a
    /// symmetric Gaussian point-spread function (`CIGaussianBlur` itself, reused as both the
    /// forward and reverse convolution operator — a Gaussian is its own transpose, so the same
    /// blur works for both directions of the algorithm). Real deconvolution recovers detail a PSF
    /// (seeing, focus, diffraction) genuinely destroyed, rather than just boosting existing edge
    /// contrast the way `CIUnsharpMask` (`sharpenIntensity`) does — at the cost of several
    /// sequential GPU passes instead of one. `amount` (0...1) scales both the assumed PSF radius
    /// and the iteration count; kept well short of "iterate until it stops changing" since more
    /// iterations extract more fine detail but also amplify more noise, and a background this
    /// noisy already needs `denoiseAmount` applied first (upstream of this call in `render`) far
    /// more than it needs a longer deconvolution loop.
    private static func richardsonLucyDeconvolve(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        let radius = Float(1 + amount * 2) // 1...3px assumed PSF radius
        let iterations = 3 + Int(amount * 7) // 3...10
        var estimate = image
        for _ in 0..<iterations {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = estimate.clampedToExtent()
            blur.radius = radius
            guard let blurredEstimate = blur.outputImage?.cropped(to: extent) else { break }

            // ratio = image / blurredEstimate — how far the current estimate's own reblur is from
            // the real observed image, per pixel.
            let divide = CIFilter.divideBlendMode()
            divide.inputImage = blurredEstimate
            divide.backgroundImage = image
            guard let ratio = divide.outputImage?.cropped(to: extent) else { break }

            let blurRatio = CIFilter.gaussianBlur()
            blurRatio.inputImage = ratio.clampedToExtent()
            blurRatio.radius = radius
            guard let correction = blurRatio.outputImage?.cropped(to: extent) else { break }

            // estimate *= correction — the standard Richardson-Lucy multiplicative update.
            let multiply = CIFilter.multiplyBlendMode()
            multiply.inputImage = correction
            multiply.backgroundImage = estimate
            guard let updated = multiply.outputImage?.cropped(to: extent) else { break }
            estimate = updated
        }

        // The repeated divide/multiply passes can push a handful of pixels slightly outside
        // 0...1 (dividing by a near-zero background, most often) — clamping once at the end
        // avoids a stray bright/dark speckle surviving into the final render.
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = estimate
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        return clamp.outputImage?.cropped(to: extent) ?? estimate
    }

    /// Builds a `starSizeReduction`/`render(_:with:starMask:)` mask: white (fully affected) over
    /// each detected star's own area — padded well past Vision's tight contour box to also cover
    /// a bloated star's softer outer halo — blurred for a smooth blend edge, black (untouched)
    /// everywhere else. `nil` if star detection fails or finds nothing (a caller should just pass
    /// `nil` on to `render`, which falls back to the old whole-image erosion in that case) —
    /// this is a nice-to-have precision improvement, not something worth surfacing an error for.
    /// Slow-ish (a synchronous Vision request) — call from a background `Task`, same as
    /// `StarDetector.detectStars` itself.
    static func computeStarMask(for image: CGImage) -> CGImage? {
        guard let detected = try? StarDetector.detectStars(in: image), !detected.stars.isEmpty else { return nil }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let drawContext = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        drawContext.setFillColor(CGColor(gray: 0, alpha: 1))
        drawContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawContext.setFillColor(CGColor(gray: 1, alpha: 1))
        for star in detected.stars {
            // Vision's own bottom-left-origin normalized box, converted to this app's usual
            // top-left-origin pixel space — the same conversion `MosaicComposer.pixelPoints` and
            // `StarPatternRecognizer` already use.
            let box = star.boundingBoxNormalized
            let pixelBox = CGRect(
                x: box.minX * CGFloat(width), y: (1 - box.maxY) * CGFloat(height),
                width: box.width * CGFloat(width), height: box.height * CGFloat(height)
            )
            let padded = pixelBox.insetBy(dx: -pixelBox.width * 0.6, dy: -pixelBox.height * 0.6)
            drawContext.fillEllipse(in: padded)
        }
        guard let raw = drawContext.makeImage() else { return nil }

        let ciMask = CIImage(cgImage: raw)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = ciMask.clampedToExtent()
        blur.radius = 3
        let blurred = blur.outputImage?.cropped(to: ciMask.extent) ?? ciMask
        return context.createCGImage(blurred, from: ciMask.extent) ?? raw
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
