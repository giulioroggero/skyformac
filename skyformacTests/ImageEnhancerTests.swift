import Foundation
import Testing
@testable import skyformac

/// Deterministic seeded RNG (a simple splitmix64) so noisy test fixtures are reproducible
/// run-to-run — `Int.random(using:)` needs a `RandomNumberGenerator`, and the system default
/// isn't seedable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

struct ImageEnhancerTests {
    private func variance(of data: Data) -> Double {
        let values = data.map { Double($0) }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    @Test func denoiseReducesNoiseVariance() throws {
        var rng = SeededGenerator(seed: 7)
        var bytes = [UInt8](repeating: 128, count: 32 * 32)
        for i in 0..<bytes.count {
            let noise = Int.random(in: -40...40, using: &rng)
            bytes[i] = UInt8(clamping: 128 + noise)
        }
        let noisy = CapturedFrame(width: 32, height: 32, imageType: ASI_IMG_RAW8, data: Data(bytes))
        let denoised = try #require(ImageEnhancer.denoise(noisy))

        #expect(variance(of: denoised.data) < variance(of: noisy.data))
    }

    @Test func denoiseLeavesFlatFieldUnchanged() throws {
        let flat = CapturedFrame(width: 16, height: 16, imageType: ASI_IMG_RAW8, data: Data(repeating: 100, count: 16 * 16))
        let denoised = try #require(ImageEnhancer.denoise(flat))
        // A perfectly flat field has no edges to preserve and no noise to remove — should stay
        // (very close to) the same value everywhere, modulo integer rounding.
        for byte in denoised.data {
            #expect(abs(Int(byte) - 100) <= 1)
        }
    }

    @Test func waveletSharpenIncreasesEdgeContrast() throws {
        // A soft (blurred) step edge: left half low, right half high, blurred at the boundary.
        var bytes = [UInt8](repeating: 50, count: 32 * 32)
        for y in 0..<32 {
            for x in 0..<32 {
                let value: UInt8 = x < 16 ? 50 : 200
                bytes[y * 32 + x] = value
            }
        }
        let original = CapturedFrame(width: 32, height: 32, imageType: ASI_IMG_RAW8, data: Data(bytes))
        let sharpened = try #require(ImageEnhancer.waveletSharpen(original, fineGain: 2.0, midGain: 1.0))

        // Right at the boundary, sharpening should push the dark side darker and/or the bright
        // side brighter relative to the unsharpened original (increased local contrast).
        let leftIndexAtEdge = 32 * 15 + 15
        let rightIndexAtEdge = 32 * 15 + 16
        let originalContrast = Int(original.data[rightIndexAtEdge]) - Int(original.data[leftIndexAtEdge])
        let sharpenedContrast = Int(sharpened.data[rightIndexAtEdge]) - Int(sharpened.data[leftIndexAtEdge])
        #expect(sharpenedContrast >= originalContrast)
    }

    @Test func zeroGainWaveletSharpenIsNearIdentity() throws {
        let frame = CapturedFrame(width: 16, height: 16, imageType: ASI_IMG_RAW8, data: Data((0..<256).map { UInt8($0 % 256) }))
        let result = try #require(ImageEnhancer.waveletSharpen(frame, fineGain: 0, midGain: 0))
        for (original, processed) in zip(frame.data, result.data) {
            #expect(abs(Int(original) - Int(processed)) <= 2) // rounding tolerance
        }
    }

    @Test func unsupportedImageTypeReturnsNil() {
        // `ASI_IMG_END` (-1) is the SDK's own "no such format" sentinel — a genuinely
        // unsupported `ASI_IMG_TYPE`, unlike RGB24 (see the RGB24-specific tests below, which
        // confirm that one *is* supported).
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_END, data: Data(count: 12))
        #expect(ImageEnhancer.denoise(frame) == nil)
        #expect(ImageEnhancer.waveletSharpen(frame, fineGain: 1, midGain: 1) == nil)
    }

    // MARK: - RGB24 (webcam/iPhone)

    private func rgb24Variance(of data: Data) -> Double {
        let values = data.map { Double($0) }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    }

    @Test func denoiseRGB24ReducesNoiseVariance() throws {
        var rng = SeededGenerator(seed: 11)
        var bytes = [UInt8](repeating: 128, count: 32 * 32 * 3)
        for i in 0..<bytes.count {
            let noise = Int.random(in: -40...40, using: &rng)
            bytes[i] = UInt8(clamping: 128 + noise)
        }
        let noisy = CapturedFrame(width: 32, height: 32, imageType: ASI_IMG_RGB24, data: Data(bytes))
        let denoised = try #require(ImageEnhancer.denoise(noisy))

        #expect(denoised.imageType == ASI_IMG_RGB24)
        #expect(denoised.data.count == noisy.data.count)
        #expect(rgb24Variance(of: denoised.data) < rgb24Variance(of: noisy.data))
    }

    @Test func denoiseRGB24LeavesFlatFieldUnchanged() throws {
        let flat = CapturedFrame(width: 16, height: 16, imageType: ASI_IMG_RGB24, data: Data(repeating: 100, count: 16 * 16 * 3))
        let denoised = try #require(ImageEnhancer.denoise(flat))
        for byte in denoised.data {
            #expect(abs(Int(byte) - 100) <= 1)
        }
    }

    @Test func denoiseRGB24PreservesColorAtAUniformlyColoredEdge() throws {
        // A hard color edge (not just brightness) — left half red, right half green, both at
        // full intensity in their own channel and zero in the other two. A per-channel-blind
        // (full-RGB-distance) range weight should still smooth each side toward its own color
        // rather than bleeding one channel's high value across the edge asymmetrically enough to
        // flip which channel dominates on either side.
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 3)
        for y in 0..<32 {
            for x in 0..<32 {
                let index = (y * 32 + x) * 3
                if x < 16 {
                    bytes[index] = 255 // R
                } else {
                    bytes[index + 1] = 255 // G
                }
            }
        }
        let original = CapturedFrame(width: 32, height: 32, imageType: ASI_IMG_RGB24, data: Data(bytes))
        let denoised = try #require(ImageEnhancer.denoise(original))

        let leftIndex = (32 * 15 + 5) * 3
        let rightIndex = (32 * 15 + 26) * 3
        #expect(denoised.data[leftIndex] > denoised.data[leftIndex + 1]) // still red-dominant
        #expect(denoised.data[rightIndex + 1] > denoised.data[rightIndex]) // still green-dominant
    }

    @Test func waveletSharpenRGB24IncreasesEdgeContrastOnEachChannel() throws {
        var bytes = [UInt8](repeating: 0, count: 32 * 32 * 3)
        for y in 0..<32 {
            for x in 0..<32 {
                let index = (y * 32 + x) * 3
                let value: UInt8 = x < 16 ? 50 : 200
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
            }
        }
        let original = CapturedFrame(width: 32, height: 32, imageType: ASI_IMG_RGB24, data: Data(bytes))
        let sharpened = try #require(ImageEnhancer.waveletSharpen(original, fineGain: 2.0, midGain: 1.0))

        let leftIndex = (32 * 15 + 15) * 3
        let rightIndex = (32 * 15 + 16) * 3
        for channel in 0..<3 {
            let originalContrast = Int(original.data[rightIndex + channel]) - Int(original.data[leftIndex + channel])
            let sharpenedContrast = Int(sharpened.data[rightIndex + channel]) - Int(sharpened.data[leftIndex + channel])
            #expect(sharpenedContrast >= originalContrast)
        }
    }

    @Test func zeroGainWaveletSharpenRGB24IsNearIdentity() throws {
        var bytes = [UInt8](repeating: 0, count: 16 * 16 * 3)
        for i in 0..<bytes.count { bytes[i] = UInt8(i % 256) }
        let frame = CapturedFrame(width: 16, height: 16, imageType: ASI_IMG_RGB24, data: Data(bytes))
        let result = try #require(ImageEnhancer.waveletSharpen(frame, fineGain: 0, midGain: 0))
        for (original, processed) in zip(frame.data, result.data) {
            #expect(abs(Int(original) - Int(processed)) <= 2) // rounding tolerance
        }
    }
}
