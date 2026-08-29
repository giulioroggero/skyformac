import CoreGraphics
import CoreML
import Foundation
import Testing
@testable import skyformac

struct CosmicRayRemoverTests {
    /// A smooth gray field with one small, extremely bright, sharp-edged spike near the corner —
    /// a stand-in for a cosmic-ray hit (a single/few-pixel, unnaturally bright, isolated blob),
    /// distinct from a broad soft "star" the model is meant to leave alone.
    private func makeImageWithSpike(width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let offset = i * 4
            pixels[offset] = 60
            pixels[offset + 1] = 60
            pixels[offset + 2] = 60
        }
        for y in 20..<22 {
            for x in 20..<22 {
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

    @Test func modelIsBundledAndAvailable() {
        // If this fails, the .mlpackage didn't compile into the test bundle — check the Xcode
        // project's Resources build phase, not the Swift code itself.
        #expect(CosmicRayRemover.isAvailable)
    }

    @Test func cleanPreservesImageDimensions() throws {
        try #require(CosmicRayRemover.isAvailable)
        let image = makeImageWithSpike(width: 64, height: 64)
        let cleaned = try CosmicRayRemover.clean(image)
        #expect(cleaned.width == 64)
        #expect(cleaned.height == 64)
    }

    @Test func cleanReturnsAValidImageForAFlatField() throws {
        try #require(CosmicRayRemover.isAvailable)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: 80, count: 64 * 64 * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i + 3] = 255 }
        let context = CGContext(
            data: &pixels, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = context.makeImage()!
        let cleaned = try CosmicRayRemover.clean(image)
        #expect(cleaned.width == 64)
        #expect(cleaned.height == 64)
    }

    // MARK: - maskImage(from:threshold:) — regression coverage for a real field crash

    /// The actual bug: `maskImage` used to assume a packed `Float32` buffer sized exactly
    /// `width * height` — a real crash (`EXC_BAD_ACCESS`) on a Mac with an ANE, where Core ML
    /// handed back a differently-typed and/or differently-strided output depending on which
    /// compute unit actually ran the model. These three cases exercise exactly that: a normal
    /// packed `Float32` array (the case that happened to work before), a packed `Float16` array
    /// (plausible ANE output), and a `Float32` array with a *padded* row stride (plausible
    /// alignment padding) — none of which should crash or misread pixels.

    @Test func maskImageHandlesAPackedFloat32Array() throws {
        let array = try MLMultiArray(shape: [1, 1, 2, 3], dataType: .float32)
        let values: [Float] = [0, 1, 0, 1, 0, 1]
        for (i, value) in values.enumerated() { array[i] = NSNumber(value: value) }
        let mask = try #require(CosmicRayRemover.maskImage(from: array, threshold: 0.5))
        #expect(mask.width == 3)
        #expect(mask.height == 2)
    }

    /// `float16BitsToDouble` replaced a direct `Float16` bind (arm64-only — a universal
    /// x86_64+arm64 Release build fails to compile at all otherwise) with hand-rolled IEEE 754
    /// half-precision bit math; this pins down that the conversion is actually correct against
    /// known bit patterns, independent of `maskImage`'s own threshold-comparison behavior.
    @Test func float16BitsToDoubleConvertsKnownBitPatterns() {
        #expect(CosmicRayRemover.float16BitsToDouble(0x0000) == 0) // +0
        #expect(CosmicRayRemover.float16BitsToDouble(0x8000) == 0) // -0
        #expect(CosmicRayRemover.float16BitsToDouble(0x3C00) == 1.0) // 1.0
        #expect(CosmicRayRemover.float16BitsToDouble(0xBC00) == -1.0) // -1.0
        #expect(CosmicRayRemover.float16BitsToDouble(0x4000) == 2.0) // 2.0
        #expect(abs(CosmicRayRemover.float16BitsToDouble(0x3800) - 0.5) < 1e-9) // 0.5
    }

    @Test func maskImageHandlesAPackedFloat16Array() throws {
        let array = try MLMultiArray(shape: [1, 1, 2, 3], dataType: .float16)
        for i in 0..<6 { array[i] = NSNumber(value: i % 2 == 0 ? 0.0 : 1.0) }
        let mask = try #require(CosmicRayRemover.maskImage(from: array, threshold: 0.5))
        #expect(mask.width == 3)
        #expect(mask.height == 2)
    }

    /// A row stride bigger than the actual width — simulating alignment padding a compute unit
    /// might introduce — with a sentinel value placed *only* in the padding gap. If `maskImage`
    /// ever goes back to assuming a packed layout, this sentinel would either get read as real
    /// image data (corrupting a pixel) or the real data after it would be misaligned; neither
    /// happens when indexing genuinely respects `array.strides`.
    @Test func maskImageRespectsAPaddedRowStrideRatherThanAssumingPackedLayout() throws {
        let width = 3, height = 2, rowStride = 5 // 2 padding elements per row
        let elementCount = rowStride * height
        // `MLMultiArray(dataPointer:...)` doesn't copy or retain the buffer it's given — it must
        // stay alive (and at a stable address) for as long as `array` is used, which a Swift
        // `Array`'s own `withUnsafeMutableBufferPointer` can't guarantee once its closure returns.
        // A manually-allocated, manually-freed buffer is what actually satisfies that contract.
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: elementCount)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: -999, count: elementCount) // -999 marks padding/unused
        for y in 0..<height {
            for x in 0..<width {
                buffer[y * rowStride + x] = (x == 1) ? 1 : 0 // column 1 "damaged", rest clean
            }
        }
        let array = try MLMultiArray(
            dataPointer: buffer, shape: [1, 1, NSNumber(value: height), NSNumber(value: width)],
            dataType: .float32,
            strides: [NSNumber(value: elementCount), NSNumber(value: elementCount), NSNumber(value: rowStride), 1]
        )
        // Sanity check on the array itself, independent of `maskImage`/`CGImage` round-tripping —
        // confirms the custom-stride construction actually holds what this test intends before
        // blaming `maskImage` for a mismatch.
        #expect(array[[0, 0, 0, 1] as [NSNumber]].floatValue == 1)
        #expect(array[[0, 0, 0, 0] as [NSNumber]].floatValue == 0)
        #expect(array.strides.map(\.intValue) == [elementCount, elementCount, rowStride, 1])

        let mask = try #require(CosmicRayRemover.maskImage(from: array, threshold: 0.5))
        #expect(mask.width == width)
        #expect(mask.height == height)

        // Read the mask's own raw bitmap data directly (no second CGContext draw/redraw, which
        // would introduce Core Graphics' own coordinate-space conventions as a separate variable)
        // — `CGImageRenderer`-style raw pixel access, same reasoning `ImageEditorTests
        // .pixelValue(at:_:in:)` already uses elsewhere.
        let provider = try #require(mask.dataProvider)
        let data = try #require(provider.data)
        let rawPointer = CFDataGetBytePtr(data)!
        let bytesPerRow = mask.bytesPerRow
        // Column 1 (the "damaged" one) should read white (255); columns 0 and 2 should read
        // black (0) — proving the padding gap was skipped, not read as real pixel data.
        for y in 0..<height {
            #expect(rawPointer[y * bytesPerRow + 0] == 0)
            #expect(rawPointer[y * bytesPerRow + 1] == 255)
            #expect(rawPointer[y * bytesPerRow + 2] == 0)
        }
    }
}
