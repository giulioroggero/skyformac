import Foundation
import Testing
@testable import MacZWO

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
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RGB24, data: Data(count: 12))
        #expect(ImageEnhancer.denoise(frame) == nil)
        #expect(ImageEnhancer.waveletSharpen(frame, fineGain: 1, midGain: 1) == nil)
    }
}
