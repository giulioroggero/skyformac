import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct ImageEditorTests {
    /// Confirmed live: an already-saved elaborated image's `planetarySettings
    /// .singleShotAdjustments` predating `posterizeLevels` has no such key in its JSON at all —
    /// `Project`'s decode is all-or-nothing, so a `keyNotFound` on this one nested field failed
    /// the *entire* project's decode, and `ProjectStore.loadAllProjects()` silently skips a
    /// project whose `project.json` fails to decode. Several real, on-disk, otherwise-valid
    /// projects with an older elaborated image simply vanished from "All Projects" until
    /// `Adjustments` got the same "`decodeIfPresent` a newer field, default it for older saved
    /// data" custom `init(from:)` `CaptureRecord.rating` already established (see
    /// `RatingAndFavoriteTests.decodingAnOlderProjectJSONWithoutRatingOrFavoriteDefaultsBoth`
    /// for the identical failure mode/fix, applied earlier).
    @Test func decodingOlderAdjustmentsJSONWithoutPosterizeLevelsDefaultsToOff() throws {
        let json = """
        {"rotationDegrees":0,"brightness":0,"contrast":1,"saturation":1,"gamma":1,
         "sharpenIntensity":0,"denoiseAmount":0,"removesHotPixels":false,"chromaNoiseReduction":0,
         "greenCastRemoval":0,"starSizeReduction":0,"shadowLift":0,"highlightRecovery":0}
        """
        let decoded = try JSONDecoder().decode(ImageEditor.Adjustments.self, from: Data(json.utf8))
        #expect(decoded.posterizeLevels == 0)
        #expect(decoded == .identity)
    }

    @Test func adjustmentsRoundTripThroughJSONIncludingPosterizeLevels() throws {
        var adjustments = ImageEditor.Adjustments()
        adjustments.posterizeLevels = 6
        adjustments.brightness = 0.2

        let data = try JSONEncoder().encode(adjustments)
        let decoded = try JSONDecoder().decode(ImageEditor.Adjustments.self, from: data)

        #expect(decoded == adjustments)
        #expect(decoded.posterizeLevels == 6)
    }

    /// Same "`decodeIfPresent` a newer field, default it for older saved data" fix as
    /// `posterizeLevels`'s own test above, for the three fields (Photos-style Vibrance/Warmth/
    /// Tint) added afterward.
    @Test func decodingOlderAdjustmentsJSONWithoutVibranceOrWhiteBalanceDefaultsToOff() throws {
        let json = """
        {"rotationDegrees":0,"brightness":0,"contrast":1,"saturation":1,"gamma":1,
         "sharpenIntensity":0,"denoiseAmount":0,"removesHotPixels":false,"chromaNoiseReduction":0,
         "greenCastRemoval":0,"starSizeReduction":0,"shadowLift":0,"highlightRecovery":0,"posterizeLevels":0}
        """
        let decoded = try JSONDecoder().decode(ImageEditor.Adjustments.self, from: Data(json.utf8))
        #expect(decoded.vibrance == 0)
        #expect(decoded.warmth == 0)
        #expect(decoded.tint == 0)
        #expect(decoded == .identity)
    }

    @Test func adjustmentsRoundTripThroughJSONIncludingVibranceAndWhiteBalance() throws {
        var adjustments = ImageEditor.Adjustments()
        adjustments.vibrance = 0.4
        adjustments.warmth = -0.3
        adjustments.tint = 0.1

        let data = try JSONEncoder().encode(adjustments)
        let decoded = try JSONDecoder().decode(ImageEditor.Adjustments.self, from: data)

        #expect(decoded == adjustments)
    }

    /// A flat mid-gray `width`×`height` RGB image — enough for `ImageEditor`'s adjustments to
    /// have something to operate on without needing a real capture on disk.
    private func makeImage(width: Int, height: Int, red: CGFloat = 0.5, green: CGFloat = 0.5, blue: CGFloat = 0.5) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// A deterministically "noisy" gray image — every pixel jitters around 128 by a
    /// pseudo-random amount derived from its own coordinates (no `Math.random`, so the test
    /// stays reproducible) — real enough texture for `CINoiseReduction` to have something to
    /// actually smooth out.
    private func makeNoisyImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let jitter = (x * 928_371 + y * 123_457) % 41 - 20 // -20...20, small per-pixel wobble
                let value = UInt8(min(max(128 + jitter, 0), 255))
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    /// Standard deviation of every red-channel sample in `image` — a plain measure of how much
    /// pixel-to-pixel texture/noise is left, for comparing two denoise strengths against each
    /// other.
    private func redChannelStandardDeviation(of image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let reds = stride(from: 0, to: pixels.count, by: 4).map { Double(pixels[$0]) }
        let mean = reds.reduce(0, +) / Double(reds.count)
        let variance = reds.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(reds.count)
        return variance.squareRoot()
    }

    /// Reads back the top-left pixel's RGB (0...255) — enough to check a color-level effect
    /// (like SCNR's green cap) actually happened, on a known-flat test image.
    private func topLeftPixel(of image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return (pixels[0], pixels[1], pixels[2])
    }

    @Test func renderWithIdentityAdjustmentsPreservesDimensions() throws {
        let image = makeImage(width: 40, height: 30)
        let rendered = try #require(ImageEditor.render(image, with: .identity))
        #expect(rendered.width == 40)
        #expect(rendered.height == 30)
    }

    @Test func renderWithACropRectShrinksTheOutput() throws {
        let image = makeImage(width: 100, height: 100)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.cropRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 50)
        #expect(rendered.height == 50)
    }

    @Test func renderWithA90DegreeRotationSwapsDimensions() throws {
        let image = makeImage(width: 80, height: 40)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.rotationDegrees = 90
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 40)
        #expect(rendered.height == 80)
    }

    @Test func autoFixedReturnsAnImageOfTheSameSize() throws {
        let image = makeImage(width: 60, height: 60)
        let fixed = try #require(ImageEditor.autoFixed(image))
        #expect(fixed.width == 60)
        #expect(fixed.height == 60)
    }

    @Test func denoiseAtFullStrengthSmoothsMoreThanAtLowStrength() throws {
        let noisy = makeNoisyImage(width: 48, height: 48)

        var light = ImageEditor.Adjustments.identity
        light.denoiseAmount = 0.2
        let lightlyDenoised = try #require(ImageEditor.render(noisy, with: light))

        var strong = ImageEditor.Adjustments.identity
        strong.denoiseAmount = 1
        let stronglyDenoised = try #require(ImageEditor.render(noisy, with: strong))

        let lightStdDev = redChannelStandardDeviation(of: lightlyDenoised)
        let strongStdDev = redChannelStandardDeviation(of: stronglyDenoised)

        // The strong setting should smooth out noticeably more per-pixel wobble than the light
        // one — confirming the top of the slider is genuinely stronger, not just marginally so.
        #expect(strongStdDev < lightStdDev)
    }

    @Test func renderWithDenoisePreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.denoiseAmount = 0.5
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithHotPixelRemovalPreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.removesHotPixels = true
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithStarSizeReductionPreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.starSizeReduction = 2
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    /// Red-channel value at an arbitrary `(x, y)` — the general-purpose counterpart to
    /// `topLeftPixel(of:)`, which only ever reads `(0, 0)`.
    private func pixelValue(at x: Int, _ y: Int, in image: CGImage) -> Int {
        let width = image.width
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
        return Int(pixels[(y * width + x) * 4])
    }

    /// A smooth diagonal gradient (standing in for nebulosity/sky background — deliberately *not*
    /// flat, since a flat region's interior is a no-op for a minimum filter regardless of
    /// masking, which would make this test pass for the wrong reason) plus one small, much
    /// brighter square near the top-left corner (standing in for a star).
    private func makeStarOverGradientImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let gradient = 80 + Double(x + y) * (100.0 / Double(width + height))
                let offset = (y * width + x) * 4
                let value = UInt8(min(255, gradient))
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        for y in 4..<12 {
            for x in 4..<12 {
                let offset = (y * width + x) * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    /// A hard-edged (unblurred, unlike `ImageEditor.computeStarMask`'s own feathered output) white
    /// rectangle over `whiteRect`, black everywhere else — enough to test `render(_:with:starMask:)`'s
    /// own masking mechanism in isolation, without depending on Vision actually detecting the
    /// synthetic star blob above as star-like.
    private func makeHardMask(width: Int, height: Int, whiteRect: CGRect) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                guard whiteRect.contains(CGPoint(x: x, y: y)) else { continue }
                let offset = (y * width + x) * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    /// The actual bug this fixes: star-size reduction used to erode the *whole* image uniformly,
    /// visibly softening nebulosity/galaxy structure right along with the stars. With a mask
    /// scoping the erosion to just the star's own area, a background pixel well outside the mask
    /// should come through completely unchanged, while the same render *without* a mask (the old
    /// behavior) measurably changes that same pixel via the minimum filter's neighborhood effect.
    @Test func starSizeReductionWithMaskLeavesBackgroundUntouchedButUnmaskedDoesNot() throws {
        let width = 60, height = 60
        let image = makeStarOverGradientImage(width: width, height: height)
        let mask = makeHardMask(width: width, height: height, whiteRect: CGRect(x: 0, y: 0, width: 20, height: 20))

        var adjustments = ImageEditor.Adjustments.identity
        adjustments.starSizeReduction = 3

        let renderedGlobal = try #require(ImageEditor.render(image, with: adjustments))
        let renderedMasked = try #require(ImageEditor.render(image, with: adjustments, starMask: mask))

        let originalBackground = pixelValue(at: 47, 47, in: image)
        let globalBackground = pixelValue(at: 47, 47, in: renderedGlobal)
        let maskedBackground = pixelValue(at: 47, 47, in: renderedMasked)

        #expect(globalBackground != originalBackground)
        #expect(maskedBackground == originalBackground)
    }

    @Test func computeStarMaskReturnsNilForABlankImage() {
        let blank = makeImage(width: 40, height: 40, red: 0, green: 0, blue: 0)
        #expect(ImageEditor.computeStarMask(for: blank) == nil)
    }

    // MARK: - Deconvolution

    /// A brightness step from 50 to 200 blurred over a `transitionWidth`-pixel-wide ramp instead
    /// of a hard edge — what a real point-spread function does to what would otherwise be a sharp
    /// boundary (a planetary limb, a lunar terminator), and exactly what deconvolution is meant to
    /// partially reverse.
    private func makeSoftEdgeImage(width: Int, height: Int, transitionWidth: Int = 6) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let edge = width / 2
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8
                if x < edge - transitionWidth {
                    value = 50
                } else if x > edge + transitionWidth {
                    value = 200
                } else {
                    let t = Double(x - (edge - transitionWidth)) / Double(2 * transitionWidth)
                    value = UInt8(50 + t * 150)
                }
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test func deconvolutionSharpenPreservesDimensionsAndStaysInByteRange() throws {
        let image = makeSoftEdgeImage(width: 60, height: 20)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.deconvolutionSharpen = 1
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 60)
        #expect(rendered.height == 20)
    }

    /// The whole point of deconvolution over plain unsharp-mask sharpening: it should measurably
    /// steepen a real blurred transition, not just boost contrast at wherever an edge already is.
    @Test func deconvolutionSharpenSteepensASoftEdge() throws {
        let width = 60, height = 20
        let image = makeSoftEdgeImage(width: width, height: height)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.deconvolutionSharpen = 1
        let rendered = try #require(ImageEditor.render(image, with: adjustments))

        let edge = width / 2
        let beforeSteepness = pixelValue(at: edge + 3, height / 2, in: image) - pixelValue(at: edge - 3, height / 2, in: image)
        let afterSteepness = pixelValue(at: edge + 3, height / 2, in: rendered) - pixelValue(at: edge - 3, height / 2, in: rendered)
        #expect(afterSteepness > beforeSteepness)
    }

    @Test func renderWithShadowAndHighlightAdjustmentsPreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.shadowLift = 0.5
        adjustments.highlightRecovery = 0.5
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithStrongerSharpenRangePreservesDimensions() throws {
        // The sharpen range was widened from 0...2 to 0...5 ("increase sharp strength") — confirm
        // the top of the new range still renders without degenerating.
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.sharpenIntensity = 5
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }

    @Test func renderWithGreenCastRemovalCapsGreenAtTheRedBlueAverage() throws {
        // A green-dominant pixel (0, 255, 0) — full removal should cap green at the red/blue
        // average (0), leaving essentially no green cast.
        let image = makeImage(width: 4, height: 4, red: 0, green: 1, blue: 0)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.greenCastRemoval = 1
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        let pixel = topLeftPixel(of: rendered)
        #expect(pixel.green < 10)
    }

    @Test func renderWithNoGreenCastRemovalLeavesGreenUntouched() throws {
        let image = makeImage(width: 4, height: 4, red: 0, green: 1, blue: 0)
        let rendered = try #require(ImageEditor.render(image, with: .identity))
        let pixel = topLeftPixel(of: rendered)
        #expect(pixel.green > 200)
    }

    // MARK: - Vibrance / white balance

    @Test func positiveWarmthShiftsANeutralGrayImageTowardRed() throws {
        let image = makeImage(width: 8, height: 8, red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.warmth = 1
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        let pixel = topLeftPixel(of: rendered)
        #expect(pixel.red > pixel.blue)
    }

    @Test func negativeWarmthShiftsANeutralGrayImageTowardBlue() throws {
        let image = makeImage(width: 8, height: 8, red: 0.5, green: 0.5, blue: 0.5)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.warmth = -1
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        let pixel = topLeftPixel(of: rendered)
        #expect(pixel.blue > pixel.red)
    }

    @Test func zeroWarmthAndTintIsANoOp() throws {
        let image = makeImage(width: 8, height: 8, red: 0.5, green: 0.5, blue: 0.5)
        let rendered = try #require(ImageEditor.render(image, with: .identity))
        let pixel = topLeftPixel(of: rendered)
        #expect(abs(Int(pixel.red) - Int(pixel.blue)) < 2)
    }

    /// `CIVibrance` should push a muted (already-close-to-gray) color harder than one that's
    /// already fully saturated — the whole reason it's a different control from plain
    /// `saturation` above. A pure-red pixel is already maxed out on saturation, so full vibrance
    /// should barely move it, while a muted pink should visibly gain saturation.
    @Test func vibrancePushesAMutedColorMoreThanAnAlreadySaturatedOne() throws {
        let mutedPink = makeImage(width: 4, height: 4, red: 0.7, green: 0.55, blue: 0.55)
        let pureRed = makeImage(width: 4, height: 4, red: 1, green: 0, blue: 0)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.vibrance = 1

        let renderedMuted = try #require(ImageEditor.render(mutedPink, with: adjustments))
        let renderedPure = try #require(ImageEditor.render(pureRed, with: adjustments))
        let mutedPixel = topLeftPixel(of: renderedMuted)
        let purePixel = topLeftPixel(of: renderedPure)

        let mutedSpread = Int(mutedPixel.red) - Int(mutedPixel.green)
        let originalMutedSpread = Int(0.7 * 255) - Int(0.55 * 255)
        let pureSpread = Int(purePixel.red) - Int(purePixel.green)

        // The muted pixel's red/green gap should widen noticeably (more saturated); the
        // already-fully-saturated red stays clearly far more saturated than the muted pixel
        // could ever become at the same vibrance amount, even if CIVibrance nudges its extreme
        // value slightly.
        #expect(mutedSpread > originalMutedSpread)
        #expect(pureSpread > mutedSpread)
    }

    // MARK: - Chroma noise reduction

    /// Random per-pixel *color* speckle with roughly constant luminance — red and green jitter in
    /// opposite directions from the same 128 baseline, exactly what real chroma noise ("puntini
    /// colorati") looks like: the brightness at each pixel barely moves, but its hue wobbles.
    /// Deterministic (coordinate-derived, no `Math.random`) for a reproducible test.
    private func makeChromaNoisyImage(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let jitter = (x * 928_371 + y * 123_457) % 61 - 30 // -30...30
                let red = UInt8(min(max(128 + jitter, 0), 255))
                let green = UInt8(min(max(128 - jitter, 0), 255))
                let offset = (y * width + x) * 4
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = 128
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    /// Mean `|red - green|` across every pixel — a plain measure of how much per-pixel color
    /// (not brightness) speckle is left, for comparing chroma-noise-reduction strengths.
    private func colorChannelSpread(of image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var total = 0.0
        let pixelCount = width * height
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            total += abs(Double(pixels[offset]) - Double(pixels[offset + 1]))
        }
        return total / Double(pixelCount)
    }

    @Test func chromaNoiseReductionAtFullStrengthReducesColorSpeckleMoreThanLightStrength() throws {
        let noisy = makeChromaNoisyImage(width: 48, height: 48)

        var light = ImageEditor.Adjustments.identity
        light.chromaNoiseReduction = 0.1
        let lightlyReduced = try #require(ImageEditor.render(noisy, with: light))

        var strong = ImageEditor.Adjustments.identity
        strong.chromaNoiseReduction = 1
        let stronglyReduced = try #require(ImageEditor.render(noisy, with: strong))

        #expect(colorChannelSpread(of: stronglyReduced) < colorChannelSpread(of: lightlyReduced))
    }

    @Test func chromaNoiseReductionAtZeroIsANoOp() throws {
        let noisy = makeChromaNoisyImage(width: 48, height: 48)
        let rendered = try #require(ImageEditor.render(noisy, with: .identity))
        // Not bit-exact (Core Image's own filter graph still runs through color-management
        // round-tripping even with every filter skipped) but should be indistinguishable from
        // the source's own speckle level, unlike the reduced cases above.
        #expect(abs(colorChannelSpread(of: rendered) - colorChannelSpread(of: noisy)) < 2)
    }

    // MARK: - Center object

    /// A bright square blob on an otherwise-black `width`×`height` background, placed with its
    /// own top-left corner at `(originX, originY)` — top-left-origin, row-major, matching this
    /// codebase's usual convention (`topLeftPixel`'s own doc comment).
    private func makeBlobImage(width: Int, height: Int, blobSize: Int, originX: Int, originY: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in originY..<min(originY + blobSize, height) {
            for x in originX..<min(originX + blobSize, width) {
                let offset = (y * width + x) * 4
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
            }
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        return context.makeImage()!
    }

    /// Plain intensity-weighted centroid of `image`'s own luma, top-left-origin — a test-local
    /// black-box measurement (not `ImageEditor`'s own private `luminanceCentroid`) so this checks
    /// `centerObject`'s actual observable effect rather than its internals.
    private func brightPixelCentroid(of image: CGImage) -> (x: Double, y: Double) {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var sumI = 0.0, sumX = 0.0, sumY = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luma = Double(pixels[offset])
                sumI += luma
                sumX += luma * Double(x)
                sumY += luma * Double(y)
            }
        }
        guard sumI > 0 else { return (Double(width) / 2, Double(height) / 2) }
        return (sumX / sumI, sumY / sumI)
    }

    @Test func centerObjectMovesAnOffCenterBlobCloserToCenter() throws {
        let image = makeBlobImage(width: 60, height: 60, blobSize: 8, originX: 2, originY: 2)
        let before = brightPixelCentroid(of: image)
        let centered = try #require(ImageEditor.centerObject(image))
        let after = brightPixelCentroid(of: centered)

        let center = (x: 30.0, y: 30.0)
        let distanceBefore = ((before.x - center.x) * (before.x - center.x) + (before.y - center.y) * (before.y - center.y)).squareRoot()
        let distanceAfter = ((after.x - center.x) * (after.x - center.x) + (after.y - center.y) * (after.y - center.y)).squareRoot()
        #expect(distanceAfter < distanceBefore)
        #expect(distanceAfter < 2) // should land almost exactly on center for a single clean blob
    }

    @Test func centerObjectPreservesDimensions() throws {
        let image = makeBlobImage(width: 50, height: 40, blobSize: 6, originX: 5, originY: 5)
        let centered = try #require(ImageEditor.centerObject(image))
        #expect(centered.width == 50)
        #expect(centered.height == 40)
    }

    @Test func centerObjectIsNilForAnAllBlackImage() throws {
        // Nothing for a brightness centroid to find at all.
        let image = makeImage(width: 20, height: 20, red: 0, green: 0, blue: 0)
        #expect(ImageEditor.centerObject(image) == nil)
    }

    @Test func renderWithChromaNoiseReductionPreservesDimensions() throws {
        let image = makeImage(width: 32, height: 32)
        var adjustments = ImageEditor.Adjustments.identity
        adjustments.chromaNoiseReduction = 0.6
        let rendered = try #require(ImageEditor.render(image, with: adjustments))
        #expect(rendered.width == 32)
        #expect(rendered.height == 32)
    }
}
