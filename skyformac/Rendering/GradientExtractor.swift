import CoreGraphics
import Foundation

/// Removes a smooth background gradient (light-pollution sky glow, moon glow, vignetting) from a
/// finished still image — the "Background Extraction"/"DBE" step most deep-sky processing
/// workflows need, previously only reachable by handing the image off to GraXpert. Samples the
/// image at a grid of points, automatically discarding any point too close to a detected star
/// (`StarDetector`) or unusually bright relative to the rest (nebulosity/galaxy structure —
/// sampling that into the "background" model would subtract part of the actual target, not just
/// sky glow), fits a smooth 2nd-order polynomial surface through the surviving samples per color
/// channel, and subtracts it back out while preserving the image's overall brightness. The same
/// statistical-background-modeling idea PixInsight's DBE/GraXpert's background tool use, just
/// automatic sampling and a fixed low polynomial order instead of a manual point editor — real
/// sky-glow/vignetting gradients are smooth, low-frequency, single-lobed shapes a 2nd-order
/// surface (one dominant slope or bowl) already captures well, without needing a user to place
/// points by hand.
enum GradientExtractor {
    enum ExtractionError: Error {
        /// Fewer than 6 usable background samples survived star/brightness exclusion — a
        /// 2nd-order polynomial has 6 coefficients per channel, so there's nothing to fit. Most
        /// likely a mostly-nebulosity/galaxy frame with barely any plain sky visible; a caller can
        /// retry with a coarser `gridSize` or a looser `brightPercentile`, but often there's
        /// genuinely no clean background here to model.
        case tooFewSamples
        case renderFailed
    }

    /// Lays a `gridSize` x `gridSize` grid of candidate points over `image` (margin-inset so no
    /// candidate sits right at the frame edge, where vignetting itself would bias the sample) and
    /// keeps the ones that look like plain sky background: outside every detected star's own
    /// (padded) bounding box, and not among the brightest `brightPercentile` fraction of the
    /// surviving candidates by patch-averaged luminance. `nil` `image` dimensions or too few
    /// surviving candidates both throw `.tooFewSamples`.
    static func detectBackgroundSamples(
        in image: CGImage, gridSize: Int = 12, brightPercentile: Double = 0.6
    ) throws -> [CGPoint] {
        let width = image.width
        let height = image.height
        guard width > 4, height > 4 else { throw ExtractionError.tooFewSamples }

        let stars = (try? StarDetector.detectStars(in: image))?.stars ?? []
        let starBoxesPixels: [CGRect] = stars.map { star in
            let box = star.boundingBoxNormalized
            let pixelBox = CGRect(
                x: box.minX * CGFloat(width), y: (1 - box.maxY) * CGFloat(height),
                width: box.width * CGFloat(width), height: box.height * CGFloat(height)
            )
            return pixelBox.insetBy(dx: -pixelBox.width * 1.5, dy: -pixelBox.height * 1.5)
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { throw ExtractionError.tooFewSamples }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let drawContext = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ExtractionError.tooFewSamples }
        drawContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let marginFraction = 1.0 / Double(gridSize + 2)
        var candidates: [(point: CGPoint, luminance: Double)] = []
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let fx = marginFraction + Double(col) / Double(gridSize - 1) * (1 - 2 * marginFraction)
                let fy = marginFraction + Double(row) / Double(gridSize - 1) * (1 - 2 * marginFraction)
                let point = CGPoint(x: fx * Double(width), y: fy * Double(height))
                guard !starBoxesPixels.contains(where: { $0.contains(point) }) else { continue }
                guard let luminance = patchLuminance(at: point, pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
                else { continue }
                candidates.append((point, luminance))
            }
        }

        guard candidates.count >= 6 else { throw ExtractionError.tooFewSamples }
        let sortedLuminances = candidates.map(\.luminance).sorted()
        let cutoffIndex = min(sortedLuminances.count - 1, Int(Double(sortedLuminances.count) * brightPercentile))
        let cutoff = sortedLuminances[cutoffIndex]
        let samples = candidates.filter { $0.luminance <= cutoff }.map(\.point)
        guard samples.count >= 6 else { throw ExtractionError.tooFewSamples }
        return samples
    }

    /// Fits a 2nd-order polynomial (`a + b·x + c·y + d·x² + e·xy + f·y²`, in normalized -1...1
    /// coordinates for numerically stable fitting) per RGB channel through `samplePoints`'s own
    /// measured (patch-averaged) color, evaluates that surface at every pixel, and subtracts it
    /// from `image` — re-adding each channel's mean sampled value afterward so the corrected
    /// image's overall brightness stays where it was instead of darkening by however bright the
    /// modeled gradient happened to be on average.
    static func removeGradient(from image: CGImage, samplePoints: [CGPoint]) throws -> CGImage {
        guard samplePoints.count >= 6 else { throw ExtractionError.tooFewSamples }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { throw ExtractionError.renderFailed }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        guard let drawContext = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw ExtractionError.renderFailed }
        drawContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        func normalized(_ point: CGPoint) -> (x: Double, y: Double) {
            (x: Double(point.x) / Double(width) * 2 - 1, y: Double(point.y) / Double(height) * 2 - 1)
        }
        func designRow(_ x: Double, _ y: Double) -> [Double] {
            [1, x, y, x * x, x * y, y * y]
        }

        var rows: [[Double]] = []
        var redValues: [Double] = []
        var greenValues: [Double] = []
        var blueValues: [Double] = []
        for point in samplePoints {
            guard let color = patchColor(at: point, pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
            else { continue }
            let (nx, ny) = normalized(point)
            rows.append(designRow(nx, ny))
            redValues.append(color.red)
            greenValues.append(color.green)
            blueValues.append(color.blue)
        }
        guard rows.count >= 6,
              let redCoefficients = fitLeastSquares(rows: rows, values: redValues),
              let greenCoefficients = fitLeastSquares(rows: rows, values: greenValues),
              let blueCoefficients = fitLeastSquares(rows: rows, values: blueValues)
        else { throw ExtractionError.tooFewSamples }

        let redMean = redValues.reduce(0, +) / Double(redValues.count)
        let greenMean = greenValues.reduce(0, +) / Double(greenValues.count)
        let blueMean = blueValues.reduce(0, +) / Double(blueValues.count)

        func evaluate(_ coefficients: [Double], _ x: Double, _ y: Double) -> Double {
            let row = designRow(x, y)
            return zip(coefficients, row).reduce(0) { $0 + $1.0 * $1.1 }
        }

        for y in 0..<height {
            let ny = Double(y) / Double(height) * 2 - 1
            for x in 0..<width {
                let nx = Double(x) / Double(width) * 2 - 1
                let offset = y * bytesPerRow + x * 4
                let redBackground = evaluate(redCoefficients, nx, ny)
                let greenBackground = evaluate(greenCoefficients, nx, ny)
                let blueBackground = evaluate(blueCoefficients, nx, ny)
                pixels[offset] = correctedByte(pixels[offset], background: redBackground, mean: redMean)
                pixels[offset + 1] = correctedByte(pixels[offset + 1], background: greenBackground, mean: greenMean)
                pixels[offset + 2] = correctedByte(pixels[offset + 2], background: blueBackground, mean: blueMean)
            }
        }

        guard let corrected = drawContext.makeImage() else { throw ExtractionError.renderFailed }
        return corrected
    }

    /// Convenience — detects background samples automatically, then removes the gradient in one
    /// call ("do it the proper way" without needing a manual point editor).
    static func removeGradient(from image: CGImage) throws -> CGImage {
        let samples = try detectBackgroundSamples(in: image)
        return try removeGradient(from: image, samplePoints: samples)
    }

    private static func correctedByte(_ original: UInt8, background: Double, mean: Double) -> UInt8 {
        let corrected = Double(original) - background + mean
        return UInt8(min(max(corrected, 0), 255))
    }

    /// A small (5x5) box-averaged luminance around `point` — robust against a single stray bright/
    /// hot pixel landing exactly on a candidate sample the way reading one raw pixel wouldn't be.
    private static func patchLuminance(
        at point: CGPoint, pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) -> Double? {
        guard let color = patchColor(at: point, pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
        else { return nil }
        return 0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
    }

    private static func patchColor(
        at point: CGPoint, pixels: [UInt8], width: Int, height: Int, bytesPerRow: Int
    ) -> (red: Double, green: Double, blue: Double)? {
        let centerX = Int(point.x)
        let centerY = Int(point.y)
        guard centerX >= 0, centerX < width, centerY >= 0, centerY < height else { return nil }
        var redSum = 0.0, greenSum = 0.0, blueSum = 0.0, count = 0.0
        for dy in -2...2 {
            let y = centerY + dy
            guard y >= 0, y < height else { continue }
            for dx in -2...2 {
                let x = centerX + dx
                guard x >= 0, x < width else { continue }
                let offset = y * bytesPerRow + x * 4
                redSum += Double(pixels[offset])
                greenSum += Double(pixels[offset + 1])
                blueSum += Double(pixels[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return (redSum / count, greenSum / count, blueSum / count)
    }

    /// Solves the 6-coefficient normal-equations linear system (`(AᵀA)c = Aᵀb`) for a 2nd-order
    /// polynomial fit via plain Gaussian elimination with partial pivoting — small and fixed-size
    /// (6x6) regardless of how many samples feed into it, so this is cheap enough to not need
    /// `Accelerate`'s LAPACK bindings. `nil` if the system is singular (e.g. every sample point
    /// coincides, which `detectBackgroundSamples`'s own grid spacing makes practically impossible).
    private static func fitLeastSquares(rows: [[Double]], values: [Double]) -> [Double]? {
        let termCount = rows[0].count
        var normalMatrix = [[Double]](repeating: [Double](repeating: 0, count: termCount), count: termCount)
        var normalVector = [Double](repeating: 0, count: termCount)
        for (row, value) in zip(rows, values) {
            for i in 0..<termCount {
                normalVector[i] += row[i] * value
                for j in 0..<termCount {
                    normalMatrix[i][j] += row[i] * row[j]
                }
            }
        }
        return solveLinearSystem(normalMatrix, normalVector)
    }

    private static func solveLinearSystem(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let n = vector.count
        var a = matrix
        var b = vector
        for pivotIndex in 0..<n {
            var maxRow = pivotIndex
            var maxValue = abs(a[pivotIndex][pivotIndex])
            for row in (pivotIndex + 1)..<n where abs(a[row][pivotIndex]) > maxValue {
                maxRow = row
                maxValue = abs(a[row][pivotIndex])
            }
            guard maxValue > 1e-9 else { return nil }
            if maxRow != pivotIndex {
                a.swapAt(pivotIndex, maxRow)
                b.swapAt(pivotIndex, maxRow)
            }
            for row in (pivotIndex + 1)..<n {
                let factor = a[row][pivotIndex] / a[pivotIndex][pivotIndex]
                guard factor != 0 else { continue }
                for col in pivotIndex..<n { a[row][col] -= factor * a[pivotIndex][col] }
                b[row] -= factor * b[pivotIndex]
            }
        }
        var solution = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for col in (row + 1)..<n { sum -= a[row][col] * solution[col] }
            solution[row] = sum / a[row][row]
        }
        return solution
    }
}
