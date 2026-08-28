import Accelerate
import CoreGraphics
import Foundation

/// Tikhonov-regularized image deconvolution — a linear, L2-regularized alternative to
/// `ImageEditor.richardsonLucyDeconvolve`'s Poisson-ML (Richardson-Lucy) approach, in the same
/// spirit as [AlessandroGhiotto/deconvolution-Tikhonov](https://github.com/AlessandroGhiotto/deconvolution-Tikhonov)
/// (classical numerical linear algebra, not a trained model — reimplemented natively here rather
/// than wrapping that Python/NumPy code, so there's nothing to convert or bundle). Minimizes
/// `‖Hx - y‖² + λ‖x‖²` for a symmetric Gaussian blur operator `H` via Landweber iteration (the
/// standard fixed-point way to solve a Tikhonov-regularized least-squares problem without a
/// closed-form matrix inverse): `x_{k+1} = x_k + τ·(H(y - H·x_k) - λ·x_k)`. Tends to produce a
/// smoother, more noise-robust result than Richardson-Lucy at the cost of being less aggressive
/// about recovering fine detail — a real, different tool, not a duplicate.
///
/// Runs entirely on CPU via `Accelerate`/`vDSP` rather than Core Image — the additive, genuinely
/// *signed* intermediate values this iteration needs (a residual `y - H·x_k` can and does go
/// negative) don't fit Core Image's own clamped-working-space pipeline safely the way
/// Richardson-Lucy's strictly-positive multiplicative updates do. Always call from a background
/// `Task`/`Task.detached` — see `ImageEditor.computeStarMask`'s own doc comment for the identical
/// "don't do this on the main actor" reasoning.
enum TikhonovDeconvolver {
    enum DeconvolutionError: Error { case invalidImage }

    /// `amount` (0...1, matching every other `ImageEditor.Adjustments` slider's own convention)
    /// scales the assumed Gaussian PSF's sigma, the regularization weight, and the iteration
    /// count together — a small, safe number of iterations (8...20) rather than iterating to
    /// convergence, since more iterations of an *unregularized* least-squares deconvolution
    /// eventually just re-amplifies noise back out (this is exactly what the `λ‖x‖²` term exists
    /// to keep in check, but a hard iteration cap is cheap extra insurance).
    static func deconvolve(_ image: CGImage, amount: Double) throws -> CGImage {
        guard image.width > 0, image.height > 0 else { throw DeconvolutionError.invalidImage }
        let sigma = 0.8 + amount * 1.4 // 0.8...2.2px assumed PSF sigma
        let lambda = Float(0.002 + amount * 0.018) // 0.002...0.02 regularization weight
        let iterations = 8 + Int(amount * 12) // 8...20
        let stepSize: Float = 1.2

        let kernel = gaussianKernel1D(sigma: sigma)
        let width = image.width
        let height = image.height
        guard let (redPlane, greenPlane, bluePlane) = planarChannels(of: image) else {
            throw DeconvolutionError.invalidImage
        }

        var planes = [redPlane, greenPlane, bluePlane]
        for index in planes.indices {
            planes[index] = landweberIterate(
                observed: planes[index], width: width, height: height, kernel: kernel,
                lambda: lambda, stepSize: stepSize, iterations: iterations
            )
        }

        guard let result = makeImage(width: width, height: height, red: planes[0], green: planes[1], blue: planes[2])
        else { throw DeconvolutionError.invalidImage }
        return result
    }

    /// One Landweber iteration is: blur the current estimate (`H·x`), take the residual against
    /// the real observed image, blur *that* residual too (`H` is symmetric — a Gaussian blur is
    /// its own adjoint, the same fact `ImageEditor.richardsonLucyDeconvolve` relies on), shrink
    /// the estimate itself by `λ` (the actual Tikhonov regularization term), and step in the
    /// resulting direction.
    private static func landweberIterate(
        observed: [Float], width: Int, height: Int, kernel: [Float], lambda: Float, stepSize: Float, iterations: Int
    ) -> [Float] {
        var estimate = observed
        for _ in 0..<iterations {
            let blurredEstimate = separableGaussianBlur(estimate, width: width, height: height, kernel: kernel)
            var residual = [Float](repeating: 0, count: observed.count)
            vDSP_vsub(blurredEstimate, 1, observed, 1, &residual, 1, vDSP_Length(observed.count))
            // residual = observed - blurredEstimate (vDSP_vsub computes b - a for vsub(a, ..., b, ...))
            let blurredResidual = separableGaussianBlur(residual, width: width, height: height, kernel: kernel)

            var shrunkEstimate = [Float](repeating: 0, count: estimate.count)
            var negativeLambda = -lambda
            vDSP_vsmul(estimate, 1, &negativeLambda, &shrunkEstimate, 1, vDSP_Length(estimate.count))

            var gradient = [Float](repeating: 0, count: estimate.count)
            vDSP_vadd(blurredResidual, 1, shrunkEstimate, 1, &gradient, 1, vDSP_Length(estimate.count))

            var scaledGradient = [Float](repeating: 0, count: estimate.count)
            var step = stepSize
            vDSP_vsmul(gradient, 1, &step, &scaledGradient, 1, vDSP_Length(estimate.count))

            var updated = [Float](repeating: 0, count: estimate.count)
            vDSP_vadd(estimate, 1, scaledGradient, 1, &updated, 1, vDSP_Length(estimate.count))
            estimate = updated
        }
        return estimate
    }

    /// A normalized 1D Gaussian sampled out to `±3σ` — `separableGaussianBlur` applies this as
    /// the horizontal pass then the vertical pass, the standard O(W·H·K) separable-convolution
    /// trick rather than a full O(W·H·K²) 2D kernel.
    private static func gaussianKernel1D(sigma: Double) -> [Float] {
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var kernel = [Float](repeating: 0, count: radius * 2 + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let value = Float(exp(-Double(i * i) / (2 * sigma * sigma)))
            kernel[i + radius] = value
            sum += value
        }
        guard sum > 0 else { return kernel }
        var invSum = 1 / sum
        vDSP_vsmul(kernel, 1, &invSum, &kernel, 1, vDSP_Length(kernel.count))
        return kernel
    }

    /// Edge-clamped separable convolution via `vDSP_conv` — horizontal pass over every row, then
    /// vertical pass over every column of the result. `vDSP_conv` itself has no built-in edge
    /// handling, so each row/column is padded by replicating its own edge value (`radius` samples
    /// on each side) before convolving, then the padding is dropped — plain zero-padding would
    /// darken every image's border with each iteration, which replication avoids.
    private static func separableGaussianBlur(_ input: [Float], width: Int, height: Int, kernel: [Float]) -> [Float] {
        let radius = (kernel.count - 1) / 2
        var horizontal = [Float](repeating: 0, count: width * height)
        var paddedRow = [Float](repeating: 0, count: width + radius * 2)
        var rowResult = [Float](repeating: 0, count: width)
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<radius { paddedRow[x] = input[rowStart] }
            for x in 0..<width { paddedRow[radius + x] = input[rowStart + x] }
            for x in 0..<radius { paddedRow[radius + width + x] = input[rowStart + width - 1] }
            paddedRow.withUnsafeBufferPointer { paddedPointer in
                kernel.withUnsafeBufferPointer { kernelPointer in
                    vDSP_conv(paddedPointer.baseAddress!, 1, kernelPointer.baseAddress!, 1, &rowResult, 1, vDSP_Length(width), vDSP_Length(kernel.count))
                }
            }
            for x in 0..<width { horizontal[rowStart + x] = rowResult[x] }
        }

        var vertical = [Float](repeating: 0, count: width * height)
        var paddedColumn = [Float](repeating: 0, count: height + radius * 2)
        var columnResult = [Float](repeating: 0, count: height)
        for x in 0..<width {
            for y in 0..<radius { paddedColumn[y] = horizontal[x] }
            for y in 0..<height { paddedColumn[radius + y] = horizontal[y * width + x] }
            for y in 0..<radius { paddedColumn[radius + height + y] = horizontal[(height - 1) * width + x] }
            paddedColumn.withUnsafeBufferPointer { paddedPointer in
                kernel.withUnsafeBufferPointer { kernelPointer in
                    vDSP_conv(paddedPointer.baseAddress!, 1, kernelPointer.baseAddress!, 1, &columnResult, 1, vDSP_Length(height), vDSP_Length(kernel.count))
                }
            }
            for y in 0..<height { vertical[y * width + x] = columnResult[y] }
        }
        return vertical
    }

    /// Reads `image` into three `Float` (0...255-scaled) planes — plain `UInt8` would silently
    /// clamp/wrap the signed intermediate arithmetic `landweberIterate` needs.
    private static func planarChannels(of image: CGImage) -> (red: [Float], green: [Float], blue: [Float])? {
        let width = image.width
        let height = image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var red = [Float](repeating: 0, count: width * height)
        var green = [Float](repeating: 0, count: width * height)
        var blue = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            // Normalized to 0...1, not left at 0...255 — `landweberIterate`'s regularization
            // weight `λ` is tuned for a 0...1 scale (matching every other `ImageEditor.Adjustments`
            // slider's own convention); applied directly to 0...255 values it was ~255x too weak
            // relative to what the slider's numbers actually meant, letting the `-λ·x` shrinkage
            // term wash out the sharpening term entirely (confirmed: a synthetic edge came back
            // *softer*, not sharper, before this fix).
            let offset = i * 4
            red[i] = Float(pixels[offset]) / 255
            green[i] = Float(pixels[offset + 1]) / 255
            blue[i] = Float(pixels[offset + 2]) / 255
        }
        return (red, green, blue)
    }

    private static func makeImage(width: Int, height: Int, red: [Float], green: [Float], blue: [Float]) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let offset = i * 4
            pixels[offset] = UInt8(min(max(red[i] * 255, 0), 255))
            pixels[offset + 1] = UInt8(min(max(green[i] * 255, 0), 255))
            pixels[offset + 2] = UInt8(min(max(blue[i] * 255, 0), 255))
            pixels[offset + 3] = 255
        }
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }
}
