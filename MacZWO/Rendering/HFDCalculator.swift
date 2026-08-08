import CoreGraphics
import Foundation

/// Computes Half-Flux Diameter (HFD) — the standard autofocus sharpness metric used by tools
/// like FocusMax/PHD2/NINA: the diameter of the circle (centered on a star's flux-weighted
/// centroid) that contains half of the star's total measured flux. Smaller HFD = tighter,
/// better-focused star. Unlike `SharpnessScorer`'s Laplacian-variance (a fast, comparative,
/// whole-frame "is this frame sharper than that one" metric for lucky imaging), HFD is a
/// per-star photometric measurement, standard practice for tracking focus quality over time.
enum HFDCalculator {
    /// HFD in pixels for one star, from a small window of raw sensor data around its detected
    /// position. Background is estimated as the window's median (cheap, robust enough for a
    /// tight crop dominated by sky background plus one star).
    static func hfd(for star: DetectedStar, in frame: CapturedFrame, cropRadius: Int = 12) -> Double? {
        guard frame.imageType == ASI_IMG_RAW8 || frame.imageType == ASI_IMG_RAW16 else { return nil }

        let box = star.boundingBoxNormalized
        let centerX = Int(box.midX * CGFloat(frame.width))
        let centerY = Int((1 - box.midY) * CGFloat(frame.height)) // Vision: bottom-left origin, y-up
        let minX = max(0, centerX - cropRadius)
        let maxX = min(frame.width - 1, centerX + cropRadius)
        let minY = max(0, centerY - cropRadius)
        let maxY = min(frame.height - 1, centerY + cropRadius)
        guard maxX > minX, maxY > minY else { return nil }

        guard let samples = cropSamples(frame, minX: minX, maxX: maxX, minY: minY, maxY: maxY) else { return nil }
        let background = median(samples)

        var sumFlux = 0.0, sumFluxX = 0.0, sumFluxY = 0.0
        let width = maxX - minX + 1
        for (index, value) in samples.enumerated() {
            let flux = max(0, value - background)
            let x = Double(index % width)
            let y = Double(index / width)
            sumFlux += flux
            sumFluxX += flux * x
            sumFluxY += flux * y
        }
        guard sumFlux > 0 else { return nil }
        let centroidX = sumFluxX / sumFlux
        let centroidY = sumFluxY / sumFlux

        var sumFluxRadius = 0.0
        for (index, value) in samples.enumerated() {
            let flux = max(0, value - background)
            let x = Double(index % width)
            let y = Double(index / width)
            let dx = x - centroidX
            let dy = y - centroidY
            sumFluxRadius += flux * (dx * dx + dy * dy).squareRoot()
        }

        return 2 * sumFluxRadius / sumFlux
    }

    /// Median HFD across all detected stars — the per-frame focus-quality number to track over
    /// time. `nil` if no star yielded a valid measurement (e.g. no stars detected at all).
    static func medianHFD(frame: CapturedFrame, stars: [DetectedStar], cropRadius: Int = 12) -> Double? {
        let values = stars.compactMap { hfd(for: $0, in: frame, cropRadius: cropRadius) }
        guard !values.isEmpty else { return nil }
        return median(values)
    }

    private static func cropSamples(_ frame: CapturedFrame, minX: Int, maxX: Int, minY: Int, maxY: Int) -> [Double]? {
        let width = maxX - minX + 1
        let height = maxY - minY + 1
        var result = [Double](repeating: 0, count: width * height)

        return frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double]? in
            switch frame.imageType {
            case ASI_IMG_RAW8, ASI_IMG_Y8:
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return nil }
                for y in minY...maxY {
                    for x in minX...maxX {
                        result[(y - minY) * width + (x - minX)] = Double(base[y * frame.width + x])
                    }
                }
            case ASI_IMG_RAW16:
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return nil }
                for y in minY...maxY {
                    for x in minX...maxX {
                        result[(y - minY) * width + (x - minX)] = Double(base[y * frame.width + x])
                    }
                }
            default:
                return nil
            }
            return result
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
