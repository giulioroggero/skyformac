import Foundation

/// Generates synthetic `CapturedFrame`s so the full pipeline (debayer, histogram, CGImage and
/// Metal rendering) can be exercised end-to-end without a physical ASI camera attached — used
/// by the "Simulate Test Pattern" debug action, and handy for UI development in general.
enum TestPatternGenerator {
    /// A diagonal gradient ramp with a bright Gaussian-ish "star" blob, RAW8 mono.
    static func mono8(width: Int, height: Int) -> CapturedFrame {
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    base[y * width + x] = samplePattern(x: x, y: y, width: width, height: height)
                }
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: data)
    }

    /// The same test pattern, RGGB-Bayer-encoded as RAW8 so `Debayer` has real work to do:
    /// each output channel gets a distinct tint so debayer artifacts are visible.
    static func bayerRAW8(width: Int, height: Int) -> CapturedFrame {
        var data = Data(count: width * height)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                for x in 0..<width {
                    let luminance = samplePattern(x: x, y: y, width: width, height: height)
                    let evenX = x % 2 == 0
                    let evenY = y % 2 == 0
                    // RGGB: (even,even)=R (odd,even)=G (even,odd)=G (odd,odd)=B
                    let value: UInt8
                    if evenX, evenY {
                        value = UInt8(clamping: Int(luminance) + 20) // R tint
                    } else if !evenX, !evenY {
                        value = UInt8(clamping: Int(luminance) - 20) // B tint
                    } else {
                        value = luminance // G
                    }
                    base[y * width + x] = value
                }
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: data)
    }

    /// A flat bias level plus Gaussian read-noise, RAW8 mono — a synthetic stand-in for a real
    /// bias/minimum-exposure frame, used by the "Smart Exposure" sub-exposure calculator's
    /// demo/no-hardware path so it has something realistic to measure a standard deviation from.
    static func syntheticBias(width: Int, height: Int, biasLevel: UInt8 = 20, noiseSigma: Double = 3.0) -> CapturedFrame {
        var data = Data(count: width * height)
        var rng = SeededGenerator(seed: 42)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<(width * height) {
                // Box-Muller for approximately-Gaussian noise around the bias level.
                let u1 = Double.random(in: 0.0001...1, using: &rng)
                let u2 = Double.random(in: 0...1, using: &rng)
                let gaussian = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
                base[i] = UInt8(clamping: Int(Double(biasLevel) + gaussian * noiseSigma))
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: data)
    }

    private static func samplePattern(x: Int, y: Int, width: Int, height: Int) -> UInt8 {
        let gradient = Double(x + y) / Double(width + height) * 180.0

        let cx = Double(width) * 0.5
        let cy = Double(height) * 0.5
        let dx = Double(x) - cx
        let dy = Double(y) - cy
        let distanceSquared = dx * dx + dy * dy
        let star = 200.0 * exp(-distanceSquared / (2.0 * 12.0 * 12.0))

        return UInt8(clamping: Int(gradient + star))
    }
}
