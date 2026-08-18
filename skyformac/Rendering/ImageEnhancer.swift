import Foundation

/// CPU fallback for `MetalFrameRenderer`'s GPU denoise/wavelet-sharpen compute kernels
/// (`bilateralDenoise`/`waveletBlur`/`waveletCombine` for mono ZWO RAW8/RAW16/Y8 frames,
/// `bilateralDenoiseRGBA`/`waveletBlurRGBA`/`waveletCombineRGBA` for RGB24 webcam/iPhone frames)
/// — same algorithms, same math, operating on normalized `0...1` samples exactly like the Metal
/// textures do, so the CPU (`CGImage`) render path gets the same real-time enhancement options
/// as the Metal path instead of silently doing nothing when "Metal Renderer" is off.
///
/// - Note: unoptimized (no vDSP/SIMD); the bilateral filter is O(25) samples/pixel and the
///   wavelet pass makes three full-image sweeps. Fine for the CPU preview path at typical camera
///   resolutions/frame rates; a large sensor at high frame rate will want the Metal path instead.
enum ImageEnhancer {
    /// `isColorCamera`/`bayerPattern` restrict the blur to same-Bayer-color neighbors for a color
    /// camera's still-mosaiced RAW8/RAW16 buffer — the same fix as the GPU `bilateralDenoise`
    /// kernel's doc comment explains: a plain spatial window here runs *before* debayering, so
    /// without this it averages neighboring red/green/blue photosites together and visibly
    /// desaturates the image. `isColorCamera == false` (mono camera) skips the check — every
    /// neighbor is already the same channel.
    static func denoise(
        _ frame: CapturedFrame, spatialSigma: Double = 1.5, rangeSigma: Double = 0.08,
        isColorCamera: Bool = false, bayerPattern: ASI_BAYER_PATTERN = ASI_BAYER_RG
    ) -> CapturedFrame? {
        if frame.imageType == ASI_IMG_RGB24 {
            return denoiseRGB24(frame, spatialSigma: spatialSigma, rangeSigma: rangeSigma)
        }
        guard let (samples, maxValue) = normalizedSamples(frame) else { return nil }
        let width = frame.width
        let height = frame.height
        let radius = 2

        var output = [Double](repeating: 0, count: samples.count)
        for y in 0..<height {
            for x in 0..<width {
                let center = samples[y * width + x]
                let centerChannel = isColorCamera ? Debayer.channel(atX: x, y: y, pattern: bayerPattern) : nil
                var sumWeight = 0.0
                var sumValue = 0.0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let sx = min(max(x + dx, 0), width - 1)
                        let sy = min(max(y + dy, 0), height - 1)
                        if let centerChannel, Debayer.channel(atX: sx, y: sy, pattern: bayerPattern) != centerChannel {
                            continue
                        }
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
        if frame.imageType == ASI_IMG_RGB24 {
            return waveletSharpenRGB24(frame, fineGain: fineGain, midGain: midGain)
        }
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

    // MARK: - RGB24 (webcam/iPhone) — same math as `bilateralDenoiseRGBA`/`waveletBlurRGBA`/
    // `waveletCombineRGBA` in `Shaders.metal`, so the CPU and GPU render paths produce matching
    // results for a webcam/iPhone source, not just for the ZWO RAW8/RAW16/Y8 path
    // `normalizedSamples`/`denormalizedFrame` below already covered.

    /// Full-RGB-distance range weight (not per-channel-independent, which would let the three
    /// channels blend by different amounts and introduce color fringing at edges) — mirrors
    /// `bilateralDenoiseRGBA`'s `length(sample.rgb - center.rgb)` exactly.
    private static func denoiseRGB24(_ frame: CapturedFrame, spatialSigma: Double, rangeSigma: Double) -> CapturedFrame? {
        let width = frame.width
        let height = frame.height
        let count = width * height
        guard frame.data.count >= count * 3 else { return nil }

        let samples = frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            return (0..<(count * 3)).map { Double(base[$0]) / 255.0 }
        }
        guard samples.count == count * 3 else { return nil }

        var output = [Double](repeating: 0, count: samples.count)
        let radius = 2
        for y in 0..<height {
            for x in 0..<width {
                let centerIndex = (y * width + x) * 3
                let centerR = samples[centerIndex]
                let centerG = samples[centerIndex + 1]
                let centerB = samples[centerIndex + 2]
                var sumWeight = 0.0
                var sumR = 0.0
                var sumG = 0.0
                var sumB = 0.0
                for dy in -radius...radius {
                    for dx in -radius...radius {
                        let sx = min(max(x + dx, 0), width - 1)
                        let sy = min(max(y + dy, 0), height - 1)
                        let sampleIndex = (sy * width + sx) * 3
                        let r = samples[sampleIndex]
                        let g = samples[sampleIndex + 1]
                        let b = samples[sampleIndex + 2]
                        let spatialWeight = exp(-Double(dx * dx + dy * dy) / (2 * spatialSigma * spatialSigma))
                        let dr = r - centerR
                        let dg = g - centerG
                        let db = b - centerB
                        let delta = (dr * dr + dg * dg + db * db).squareRoot()
                        let rangeWeight = exp(-(delta * delta) / (2 * rangeSigma * rangeSigma))
                        let w = spatialWeight * rangeWeight
                        sumWeight += w
                        sumR += w * r
                        sumG += w * g
                        sumB += w * b
                    }
                }
                let safeWeight = max(sumWeight, 1e-6)
                output[centerIndex] = sumR / safeWeight
                output[centerIndex + 1] = sumG / safeWeight
                output[centerIndex + 2] = sumB / safeWeight
            }
        }
        return denormalizedRGB24Frame(output, width: width, height: height)
    }

    /// The à trous blur weights are color-agnostic (unlike `denoiseRGB24`'s range weight), so
    /// each channel plane can run through the exact same `waveletBlur` used for mono frames
    /// independently, then get recombined with the same fine/mid gains per channel — mirrors
    /// `waveletBlurRGBA`/`waveletCombineRGBA` exactly.
    private static func waveletSharpenRGB24(_ frame: CapturedFrame, fineGain: Double, midGain: Double) -> CapturedFrame? {
        let width = frame.width
        let height = frame.height
        let count = width * height
        guard frame.data.count >= count * 3 else { return nil }

        let samples = frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
            return (0..<(count * 3)).map { Double(base[$0]) / 255.0 }
        }
        guard samples.count == count * 3 else { return nil }

        var output = [Double](repeating: 0, count: samples.count)
        for channel in 0..<3 {
            var plane = [Double](repeating: 0, count: count)
            for i in 0..<count { plane[i] = samples[i * 3 + channel] }

            let layer0 = waveletBlur(plane, width: width, height: height, spacing: 1)
            let layer1 = waveletBlur(layer0, width: width, height: height, spacing: 2)
            for i in 0..<count {
                let fineDetail = plane[i] - layer0[i]
                let midDetail = layer0[i] - layer1[i]
                let sharpened = layer1[i] + midDetail * (1 + midGain) + fineDetail * (1 + fineGain)
                output[i * 3 + channel] = min(max(sharpened, 0), 1)
            }
        }
        return denormalizedRGB24Frame(output, width: width, height: height)
    }

    private static func denormalizedRGB24Frame(_ values: [Double], width: Int, height: Int) -> CapturedFrame? {
        var data = Data(count: values.count)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<values.count { base[i] = UInt8(clamping: Int((values[i] * 255.0).rounded())) }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RGB24, data: data)
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
