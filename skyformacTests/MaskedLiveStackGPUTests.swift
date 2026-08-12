import Foundation
import Metal
import Testing
@testable import skyformac

/// Dispatches `accumulateMonoMasked`/`normalizeMaskedAccumulator` directly (not through
/// `MetalFrameRenderer`, which keeps `process` private) to verify the GPU masked-accumulation
/// path matches `LiveStacker.add(_:mask:)`'s CPU semantics exactly: a masked-out pixel on one
/// frame is skipped entirely (not zeroed) — its final average is over fewer frames, not the
/// same frame count with a zero mixed in.
struct MaskedLiveStackGPUTests {
    private struct Kernels {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let accumulatePipeline: MTLComputePipelineState
        let normalizePipeline: MTLComputePipelineState
    }

    private func makeKernels() throws -> Kernels {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try #require(device.makeDefaultLibrary())
        let accumulateFn = try #require(library.makeFunction(name: "accumulateMonoMasked"))
        let normalizeFn = try #require(library.makeFunction(name: "normalizeMaskedAccumulator"))
        return Kernels(
            device: device, queue: queue,
            accumulatePipeline: try device.makeComputePipelineState(function: accumulateFn),
            normalizePipeline: try device.makeComputePipelineState(function: normalizeFn)
        )
    }

    private func makeTexture(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        return try #require(device.makeTexture(descriptor: descriptor))
    }

    private func fillMono(_ texture: MTLTexture, values: [Float], width: Int, height: Int) {
        var floats = values
        floats.withUnsafeMutableBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: raw.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.size
            )
        }
    }

    private func readMono(_ texture: MTLTexture, width: Int, height: Int) -> [Float] {
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!, bytesPerRow: width * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        return values
    }

    private func accumulate(_ kernels: Kernels, source: MTLTexture, sum: MTLTexture, counts: MTLTexture, mask: [UInt8], width: Int, height: Int) throws {
        let maskBuffer = try #require(kernels.device.makeBuffer(bytes: mask, length: mask.count, options: .storageModeShared))
        let commandBuffer = try #require(kernels.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        var maskWidth = UInt32(width)
        encoder.setComputePipelineState(kernels.accumulatePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(sum, index: 1)
        encoder.setTexture(counts, index: 2)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)
        encoder.setBytes(&maskWidth, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func normalize(_ kernels: Kernels, sum: MTLTexture, counts: MTLTexture, destination: MTLTexture, width: Int, height: Int) throws {
        let commandBuffer = try #require(kernels.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(kernels.normalizePipeline)
        encoder.setTexture(sum, index: 0)
        encoder.setTexture(counts, index: 1)
        encoder.setTexture(destination, index: 2)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    @Test func maskedPixelIsExcludedNotZeroed() throws {
        let kernels = try makeKernels()
        let width = 2
        let height = 1
        let sum = try makeTexture(kernels.device, width: width, height: height)
        let counts = try makeTexture(kernels.device, width: width, height: height)
        let destination = try makeTexture(kernels.device, width: width, height: height)
        fillMono(sum, values: [0, 0], width: width, height: height)
        fillMono(counts, values: [0, 0], width: width, height: height)

        // Pixel 0 is masked out (a detected streak) on frame 1 only; pixel 1 is never masked.
        let frame1 = try makeTexture(kernels.device, width: width, height: height)
        fillMono(frame1, values: [100, 100], width: width, height: height)
        try accumulate(kernels, source: frame1, sum: sum, counts: counts, mask: [1, 0], width: width, height: height)

        let frame2 = try makeTexture(kernels.device, width: width, height: height)
        fillMono(frame2, values: [200, 200], width: width, height: height)
        try accumulate(kernels, source: frame2, sum: sum, counts: counts, mask: [0, 0], width: width, height: height)

        try normalize(kernels, sum: sum, counts: counts, destination: destination, width: width, height: height)
        let result = readMono(destination, width: width, height: height)

        // Pixel 0: only frame2's value of 200 ever counted (frame1 was masked out) -> average
        // is exactly 200, not (0 + 200) / 2 = 100 (which is what zeroing the masked frame would
        // have produced instead of skipping it).
        #expect(result[0] == 200)
        // Pixel 1: both frames counted normally -> (100 + 200) / 2 = 150.
        #expect(result[1] == 150)
    }

    @Test func normalizeClampsCountToAtLeastOneForNeverAccumulatedPixels() throws {
        let kernels = try makeKernels()
        let width = 1
        let height = 1
        let sum = try makeTexture(kernels.device, width: width, height: height)
        let counts = try makeTexture(kernels.device, width: width, height: height)
        let destination = try makeTexture(kernels.device, width: width, height: height)
        fillMono(sum, values: [0], width: width, height: height)
        fillMono(counts, values: [0], width: width, height: height)

        try normalize(kernels, sum: sum, counts: counts, destination: destination, width: width, height: height)
        let result = readMono(destination, width: width, height: height)

        #expect(result[0] == 0) // 0 / max(0, 1) == 0, not a division-by-zero NaN/inf.
    }

    @Test func fullyMaskedPixelAcrossAllFramesStaysAtZero() throws {
        let kernels = try makeKernels()
        let width = 1
        let height = 1
        let sum = try makeTexture(kernels.device, width: width, height: height)
        let counts = try makeTexture(kernels.device, width: width, height: height)
        let destination = try makeTexture(kernels.device, width: width, height: height)
        fillMono(sum, values: [0], width: width, height: height)
        fillMono(counts, values: [0], width: width, height: height)

        for _ in 0..<3 {
            let frame = try makeTexture(kernels.device, width: width, height: height)
            fillMono(frame, values: [255], width: width, height: height)
            try accumulate(kernels, source: frame, sum: sum, counts: counts, mask: [1], width: width, height: height)
        }

        try normalize(kernels, sum: sum, counts: counts, destination: destination, width: width, height: height)
        let result = readMono(destination, width: width, height: height)
        #expect(result[0] == 0)
    }
}
