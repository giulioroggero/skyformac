import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct ImageEditorTests {
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
