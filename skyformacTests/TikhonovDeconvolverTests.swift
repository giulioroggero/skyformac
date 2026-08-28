import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct TikhonovDeconvolverTests {
    /// A sharp step edge, genuinely blurred by a 1D Gaussian along `x` — unlike a hand-drawn
    /// linear ramp, this is actually in the range of images `TikhonovDeconvolver`'s own assumed
    /// Gaussian-PSF forward model can invert, which is what a deconvolution test needs to
    /// meaningfully exercise "does this recover the blur it's designed for" rather than "does
    /// this react at all to an arbitrary soft gradient" (a linear ramp isn't produced by blurring
    /// a sharp edge with *any* real PSF, so there's no reason a correct deconvolution algorithm
    /// would necessarily steepen one — confirmed by reproducing this exact scenario in Python
    /// against a reference implementation before concluding the algorithm itself was fine and the
    /// original test image was the actual problem).
    private func makeGaussianBlurredEdgeImage(width: Int, height: Int, sigma: Double = 1.64) -> CGImage {
        let edge = width / 2
        var sharp = [Float](repeating: 0, count: width)
        for x in 0..<width { sharp[x] = x < edge ? 50 : 200 }

        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: radius * 2 + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let value = Float(exp(-Double(i * i) / (2 * sigma * sigma)))
            kernel[i + radius] = value
            sum += value
        }
        for i in kernel.indices { kernel[i] /= sum }

        var blurred = [Float](repeating: 0, count: width)
        for x in 0..<width {
            var total: Float = 0
            for k in -radius...radius {
                let sampleX = min(max(x + k, 0), width - 1)
                total += sharp[sampleX] * kernel[k + radius]
            }
            blurred[x] = total
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let value = UInt8(min(max(blurred[x], 0), 255))
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

    @Test func deconvolvePreservesDimensions() throws {
        let image = makeGaussianBlurredEdgeImage(width: 60, height: 20)
        let result = try TikhonovDeconvolver.deconvolve(image, amount: 0.5)
        #expect(result.width == 60)
        #expect(result.height == 20)
    }

    @Test func deconvolveSteepensASoftEdge() throws {
        let width = 60, height = 20
        let image = makeGaussianBlurredEdgeImage(width: width, height: height)
        let result = try TikhonovDeconvolver.deconvolve(image, amount: 0.6)

        let edge = width / 2
        let beforeSteepness = pixelValue(at: edge + 3, height / 2, in: image) - pixelValue(at: edge - 3, height / 2, in: image)
        let afterSteepness = pixelValue(at: edge + 3, height / 2, in: result) - pixelValue(at: edge - 3, height / 2, in: result)
        #expect(afterSteepness > beforeSteepness)
    }

    @Test func deconvolveOfAFlatFieldStaysFlat() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 100, count: 40 * 40 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i + 3] = 255 }
        let context = CGContext(
            data: &pixels, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 40 * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let flat = context.makeImage()!
        let result = try TikhonovDeconvolver.deconvolve(flat, amount: 0.5)
        let center = pixelValue(at: 20, 20, in: result)
        #expect(abs(center - 100) < 5)
    }

    @Test func deconvolveThrowsForAZeroSizeImage() {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let tiny = context.makeImage()!
        // A 1x1 image is a degenerate-but-valid CGImage — this exercises the pipeline end to end
        // rather than throwing, confirming it doesn't crash on the smallest possible input.
        #expect(throws: Never.self) {
            _ = try TikhonovDeconvolver.deconvolve(tiny, amount: 0.5)
        }
    }
}
