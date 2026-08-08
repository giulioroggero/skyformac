import Foundation

/// CPU fallback for `MetalFrameRenderer`'s GPU denoise/wavelet-sharpen compute kernels
/// (`bilateralDenoise`, `waveletBlur`/`waveletCombine` in `Shaders.metal`) — same algorithms,
/// same math, operating on normalized `0...1` samples exactly like the Metal textures do, so the
/// CPU (`CGImage`) render path gets the same real-time enhancement options as the Metal path
/// instead of silently doing nothing when "Metal Renderer" is off.
///
/// - Note: unoptimized (no vDSP/SIMD); the bilateral filter is O(25) samples/pixel and the
///   wavelet pass makes three full-image sweeps. Fine for the CPU preview path at typical camera
///   resolutions/frame rates; a large sensor at high frame rate will want the Metal path instead.
enum ImageEnhancer {
    static func denoise(_ frame: CapturedFrame, spatialSigma: Double = 1.5, rangeSigma: Double = 0.08) -> CapturedFrame? {
        guard let (samples, maxValue) = normalizedSamples(frame) else { return nil }
        let width = frame.width
        let height = frame.height
        let radius = 2

        var output = [Double](repeating: 0, count: samples.count)
        for y in 0..<height {
            for x in 0..<width {
                let center = samples[y * width + x]
                var sumWeight = 0.0
                var sumValue = 0.0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let sx = min(max(x + dx, 0), width - 1)
                        let sy = min(max(y + dy, 0), height - 1)
                        let sample = samples[sy * width + sx]
                        let spatialWeight = exp(-Double(dx * dx + dy * dy) / (2 * spatialSigma * spatialSigma))
                        let delta = sample - center
                        let rangeWeight = exp(-(delta * delta) / (2 * rangeSigma * rangeSigma))
                        let w = spatialWeight * rangeWeight
                        sumWeight += w
                        sumValue += w * sample
                    }
                }
                output[y * width + x] = sumValue / max(sumWeight, 1e-6)
            }
        }
        return denormalizedFrame(output, width: width, height: height, imageType: frame.imageType, maxValue: maxValue)
    }

    static func waveletSharpen(_ frame: CapturedFrame, fineGain: Double, midGain: Double) -> CapturedFrame? {
        guard let (samples, maxValue) = normalizedSamples(frame) else { return nil }
        let width = frame.width
        let height = frame.height

        let layer0 = waveletBlur(samples, width: width, height: height, spacing: 1)
        let layer1 = waveletBlur(layer0, width: width, height: height, spacing: 2)

        var output = [Double](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let fineDetail = samples[i] - layer0[i]
            let midDetail = layer0[i] - layer1[i]
            let sharpened = layer1[i] + midDetail * (1 + midGain) + fineDetail * (1 + fineGain)
            output[i] = min(max(sharpened, 0), 1)
        }
        return denormalizedFrame(output, width: width, height: height, imageType: frame.imageType, maxValue: maxValue)
    }

    /// One à trous B3-spline blur level — identical weights/spacing scheme to `waveletBlur` in
    /// `Shaders.metal`, so CPU and GPU sharpening produce matching results. The 2D kernel is a
    /// true outer product of the 1D kernel with itself, so it's separable into a horizontal pass
    /// followed by a vertical pass — 2×5 taps/pixel instead of 25, the same mathematical result
    /// for a fraction of the cost (this matters a lot in an unoptimized Swift loop).
    private static func waveletBlur(_ samples: [Double], width: Int, height: Int, spacing: Int) -> [Double] {
        let k: [Double] = [1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16]

        var horizontal = [Double](repeating: 0, count: samples.count)
        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width {
                var sum = 0.0
                for i in -2...2 {
                    let sx = min(max(x + i * spacing, 0), width - 1)
                    sum += k[i + 2] * samples[rowBase + sx]
                }
                horizontal[rowBase + x] = sum
            }
        }

        var output = [Double](repeating: 0, count: samples.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0.0
                for j in -2...2 {
                    let sy = min(max(y + j * spacing, 0), height - 1)
                    sum += k[j + 2] * horizontal[sy * width + x]
                }
                output[y * width + x] = sum
            }
        }
        return output
    }

    // MARK: - Normalize / denormalize

    private static func normalizedSamples(_ frame: CapturedFrame) -> (values: [Double], maxValue: Double)? {
        let count = frame.width * frame.height
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            guard frame.data.count >= count else { return nil }
            let values = frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
                return (0..<count).map { Double(base[$0]) / 255.0 }
            }
            return (values, 255.0)
        case ASI_IMG_RAW16:
            guard frame.data.count >= count * 2 else { return nil }
            let values = frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return [] }
                return (0..<count).map { Double(base[$0]) / 65535.0 }
            }
            return (values, 65535.0)
        default:
            return nil
        }
    }

    private static func denormalizedFrame(
        _ values: [Double], width: Int, height: Int, imageType: ASI_IMG_TYPE, maxValue: Double
    ) -> CapturedFrame? {
        switch imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            var data = Data(count: values.count)
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<values.count { base[i] = UInt8(clamping: Int((values[i] * maxValue).rounded())) }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: data)
        case ASI_IMG_RAW16:
            var data = Data(count: values.count * 2)
            data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<values.count { base[i] = UInt16(clamping: Int((values[i] * maxValue).rounded())) }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: data)
        default:
            return nil
        }
    }
}
