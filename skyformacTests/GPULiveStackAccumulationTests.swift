import Foundation
import Metal
import Testing
@testable import skyformac

/// Dispatches the actual `accumulateMono`/`accumulateMonoAligned`/`stretchMono` kernels directly
/// (same technique as `MaskedLiveStackGPUTests` — `MetalFrameRenderer.process` is private) to
/// verify, end to end, that GPU live stacking does what it's supposed to: average incoming frames
/// into a lower-noise result, not just repeatedly overwrite/overlap the display with whatever
/// frame arrived last. Written in response to a real "live stacking looks identical to a single
/// frame" report — see the two conclusions below (`stackedAverageIsMeaningfullyCloserToTheTrueMeanThanASingleFrame`,
/// `alignedAccumulateRecentersADriftingFeatureInsteadOfSmearingIt`) for what was actually checked.
struct GPULiveStackAccumulationTests {
    private struct Kernels {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let accumulatePipeline: MTLComputePipelineState
        let accumulateAlignedPipeline: MTLComputePipelineState
        let clearPipeline: MTLComputePipelineState
        let accumulateSigmaClippedPipeline: MTLComputePipelineState
        let normalizeMaskedAccumulatorPipeline: MTLComputePipelineState
    }

    private func makeKernels() throws -> Kernels {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let library = try #require(device.makeDefaultLibrary())
        let accumulateFn = try #require(library.makeFunction(name: "accumulateMono"))
        let accumulateAlignedFn = try #require(library.makeFunction(name: "accumulateMonoAligned"))
        let clearFn = try #require(library.makeFunction(name: "clearMono"))
        let accumulateSigmaClippedFn = try #require(library.makeFunction(name: "accumulateMonoSigmaClipped"))
        let normalizeMaskedAccumulatorFn = try #require(library.makeFunction(name: "normalizeMaskedAccumulator"))
        return Kernels(
            device: device, queue: queue,
            accumulatePipeline: try device.makeComputePipelineState(function: accumulateFn),
            accumulateAlignedPipeline: try device.makeComputePipelineState(function: accumulateAlignedFn),
            clearPipeline: try device.makeComputePipelineState(function: clearFn),
            accumulateSigmaClippedPipeline: try device.makeComputePipelineState(function: accumulateSigmaClippedFn),
            normalizeMaskedAccumulatorPipeline: try device.makeComputePipelineState(function: normalizeMaskedAccumulatorFn)
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

    private func clear(_ kernels: Kernels, texture: MTLTexture, width: Int, height: Int) throws {
        let commandBuffer = try #require(kernels.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(kernels.clearPipeline)
        encoder.setTexture(texture, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func accumulate(_ kernels: Kernels, source: MTLTexture, accumulator: MTLTexture, width: Int, height: Int) throws {
        let commandBuffer = try #require(kernels.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(kernels.accumulatePipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(accumulator, index: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func accumulateAligned(_ kernels: Kernels, source: MTLTexture, accumulator: MTLTexture, shift: SIMD2<Float>, width: Int, height: Int) throws {
        var shiftValue = shift
        let commandBuffer = try #require(kernels.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(kernels.accumulateAlignedPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(accumulator, index: 1)
        encoder.setBytes(&shiftValue, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func accumulateSigmaClipped(_ kernels: Kernels, source: MTLTexture, sum: MTLTexture, counts: MTLTexture, kappaSigma: Float, width: Int, height: Int) throws {
        var kappaSigmaValue = kappaSigma
        let commandBuffer = try #require(kernels.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(kernels.accumulateSigmaClippedPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(sum, index: 1)
        encoder.setTexture(counts, index: 2)
        encoder.setBytes(&kappaSigmaValue, length: MemoryLayout<Float>.size, index: 0)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func normalizeMaskedAccumulator(_ kernels: Kernels, sum: MTLTexture, counts: MTLTexture, destination: MTLTexture, width: Int, height: Int) throws {
        let commandBuffer = try #require(kernels.queue.makeCommandBuffer())
        let encoder = try #require(commandBuffer.makeComputeCommandEncoder())
        encoder.setComputePipelineState(kernels.normalizeMaskedAccumulatorPipeline)
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

    // MARK: - Basic running-sum correctness

    @Test func accumulateMonoIsAPlainRunningSumAcrossFrames() throws {
        let kernels = try makeKernels()
        let width = 2
        let height = 1
        let accumulator = try makeTexture(kernels.device, width: width, height: height)
        try clear(kernels, texture: accumulator, width: width, height: height)

        let frame1 = try makeTexture(kernels.device, width: width, height: height)
        fillMono(frame1, values: [0.1, 0.4], width: width, height: height)
        try accumulate(kernels, source: frame1, accumulator: accumulator, width: width, height: height)

        let frame2 = try makeTexture(kernels.device, width: width, height: height)
        fillMono(frame2, values: [0.2, 0.4], width: width, height: height)
        try accumulate(kernels, source: frame2, accumulator: accumulator, width: width, height: height)

        let frame3 = try makeTexture(kernels.device, width: width, height: height)
        fillMono(frame3, values: [0.3, 0.4], width: width, height: height)
        try accumulate(kernels, source: frame3, accumulator: accumulator, width: width, height: height)

        let sum = readMono(accumulator, width: width, height: height)
        // Exactly the sum of the three frames — this is what `stretchMono`/`debayerAndStretch`
        // then divide by `accumulatedFrameCount` to turn back into an average. If this weren't a
        // true accumulating sum (say, each frame silently replaced the previous one instead of
        // adding to it — "the only stacking is that it is overlapped the image"), pixel 0 would
        // read back as 0.3 (the last frame alone), not 0.6.
        #expect(abs(sum[0] - 0.6) < 0.0001)
        #expect(abs(sum[1] - 1.2) < 0.0001)
    }

    // MARK: - Does stacking actually reduce noise, not just overwrite?

    /// The direct answer to "is there something to change in the algorithm... how does live
    /// stacking work, are you sure you don't introduce strange behavior": stacks 40 noisy frames
    /// of a flat 8x8 patch (true value 0.5, independent per-pixel-per-frame noise) and checks that
    /// the resulting average is far closer to the true value — and has far lower pixel-to-pixel
    /// spread — than any single one of those frames. A pure "last frame wins"/overlap bug would
    /// make the "stacked" result statistically indistinguishable from a single frame; a real
    /// running average does not.
    @Test func stackedAverageIsMeaningfullyCloserToTheTrueMeanThanASingleFrame() throws {
        let kernels = try makeKernels()
        let width = 8
        let height = 8
        let pixelCount = width * height
        let trueValue: Float = 0.5
        let frameCount = 40

        let accumulator = try makeTexture(kernels.device, width: width, height: height)
        try clear(kernels, texture: accumulator, width: width, height: height)

        var rng = SeededGenerator(seed: 42)
        var firstFrameValues: [Float] = []
        for frameIndex in 0..<frameCount {
            var values = [Float](repeating: 0, count: pixelCount)
            for i in 0..<pixelCount {
                let noise = Float.random(in: -0.2...0.2, using: &rng)
                values[i] = trueValue + noise
            }
            if frameIndex == 0 { firstFrameValues = values }
            let frame = try makeTexture(kernels.device, width: width, height: height)
            fillMono(frame, values: values, width: width, height: height)
            try accumulate(kernels, source: frame, accumulator: accumulator, width: width, height: height)
        }

        let sum = readMono(accumulator, width: width, height: height)
        let stackedAverage = sum.map { $0 / Float(frameCount) }

        func meanAbsoluteError(_ values: [Float]) -> Float {
            values.map { abs($0 - trueValue) }.reduce(0, +) / Float(values.count)
        }
        let singleFrameError = meanAbsoluteError(firstFrameValues)
        let stackedError = meanAbsoluteError(stackedAverage)

        // With ~±0.2 uniform noise averaged over 40 independent frames, the stack's error should
        // drop by roughly sqrt(40) ≈ 6x — asserting a conservative 3x margin keeps this robust to
        // the specific seed/RNG while still failing hard if stacking weren't averaging at all
        // (in which case stackedError would equal singleFrameError, not be smaller).
        #expect(stackedError < singleFrameError / 3)

        func standardDeviation(_ values: [Float]) -> Float {
            let mean = values.reduce(0, +) / Float(values.count)
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(values.count)
            return variance.squareRoot()
        }
        // Same story from a different angle: the stacked image's pixel-to-pixel spread (every
        // pixel shares the same true value, so any spread is pure noise) should be much tighter
        // than one frame's own spread.
        #expect(standardDeviation(stackedAverage) < standardDeviation(firstFrameValues) / 3)
    }

    // MARK: - Drift correction: does it actually re-center a moving feature?

    /// Feeds a bright point that's drifted from (2,2) to (4,2) between two frames, accumulating
    /// the second one through `accumulateMonoAligned` with the shift `DriftAligner.shift(current:
    /// reference:)` would compute for that exact drift. If the shift's sign/sampling direction
    /// were backwards, this would either smear the accumulator's peak away from (2,2) entirely or
    /// double the drift instead of canceling it — either way, the peak would land somewhere other
    /// than (2,2).
    @Test func alignedAccumulateRecentersADriftingFeatureInsteadOfSmearingIt() throws {
        let kernels = try makeKernels()
        let width = 8
        let height = 8
        let accumulator = try makeTexture(kernels.device, width: width, height: height)
        try clear(kernels, texture: accumulator, width: width, height: height)

        func makeSpot(at point: (x: Int, y: Int)) -> MTLTexture {
            var values = [Float](repeating: 0, count: width * height)
            values[point.y * width + point.x] = 1.0
            let texture = try! makeTexture(kernels.device, width: width, height: height)
            fillMono(texture, values: values, width: width, height: height)
            return texture
        }

        let reference = SIMD2<Float>(2, 2)
        let drifted = SIMD2<Float>(4, 2)

        // Frame 1: the reference position, added unaligned (as the very first stacked frame
        // always is — there's nothing to align it against yet).
        try accumulate(kernels, source: makeSpot(at: (2, 2)), accumulator: accumulator, width: width, height: height)

        // Frame 2: the same feature, now at (4, 2) — exactly the drift `computeDriftShift` would
        // detect and hand to `accumulateMonoAligned` as `DriftAligner.shift(current:reference:)`.
        let shift = DriftAligner.shift(current: drifted, reference: reference)
        try accumulateAligned(kernels, source: makeSpot(at: (4, 2)), accumulator: accumulator, shift: shift, width: width, height: height)

        let result = readMono(accumulator, width: width, height: height)
        let peakIndex = result.indices.max { result[$0] < result[$1] }!
        let peakX = peakIndex % width
        let peakY = peakIndex / width

        // Both frames' contributions landed on the *reference* position, not the drifted one —
        // the whole point of drift correction. (Bilinear sampling spreads a single-pixel spot's
        // energy across its neighbors a little, which is why this checks the peak's location
        // rather than requiring an exact value of 2.0 at that one pixel.)
        #expect(peakX == 2)
        #expect(peakY == 2)
        // The peak actually gained energy from both frames (not just one) — ruling out a shift
        // so wrong that frame 2 contributed nothing overlapping frame 1 at all.
        #expect(result[peakIndex] > 1.0)
    }

    // MARK: - Sigma clipping (specs/live-stackig-fix-spec.md, step 4)

    /// The first few frames (`currentCount <= 2`) always accumulate, even with wildly different
    /// values — there's no running average yet to judge an "outlier" against, matching
    /// `SmartLiveStackGate`'s own "no baseline yet always keeps" reasoning.
    @Test func firstFewFramesAlwaysAccumulateRegardlessOfSpread() throws {
        let kernels = try makeKernels()
        let width = 1
        let height = 1
        let sum = try makeTexture(kernels.device, width: width, height: height)
        let counts = try makeTexture(kernels.device, width: width, height: height)
        fillMono(sum, values: [0], width: width, height: height)
        fillMono(counts, values: [0], width: width, height: height)

        let values: [Float] = [0.1, 0.9, 0.2] // wildly spread — would all be "outliers" of each other
        for value in values {
            let frame = try makeTexture(kernels.device, width: width, height: height)
            fillMono(frame, values: [value], width: width, height: height)
            try accumulateSigmaClipped(kernels, source: frame, sum: sum, counts: counts, kappaSigma: 0.01, width: width, height: height)
        }

        let resultCounts = readMono(counts, width: width, height: height)
        #expect(resultCounts[0] == 3) // all three counted, none rejected
    }

    /// Once a baseline exists (more than 2 frames in), a pixel that deviates from its own running
    /// average by more than `kappaSigma` is rejected outright — not folded in at a reduced weight,
    /// not zeroed, just skipped, the same "skip, don't corrupt" semantics `accumulateMonoMasked`
    /// already uses for streak-masked pixels. This is what protects a stack against a satellite
    /// trail, cosmic ray hit, or hot pixel that only ever shows up on one frame.
    @Test func outlierPixelIsRejectedOnceABaselineExists() throws {
        let kernels = try makeKernels()
        let width = 1
        let height = 1
        let sum = try makeTexture(kernels.device, width: width, height: height)
        let counts = try makeTexture(kernels.device, width: width, height: height)
        fillMono(sum, values: [0], width: width, height: height)
        fillMono(counts, values: [0], width: width, height: height)

        // Establish a tight baseline around 0.5 (three frames, kappaSigma loose enough to accept
        // all of them — deviation from a running mean starting at the very first value is at most
        // small here).
        for value: Float in [0.50, 0.51, 0.49, 0.50] {
            let frame = try makeTexture(kernels.device, width: width, height: height)
            fillMono(frame, values: [value], width: width, height: height)
            try accumulateSigmaClipped(kernels, source: frame, sum: sum, counts: counts, kappaSigma: 0.05, width: width, height: height)
        }
        let baselineCounts = readMono(counts, width: width, height: height)
        #expect(baselineCounts[0] == 4)

        // A satellite trail hits this pixel on exactly one frame — far outside the tight ±0.05
        // baseline established above.
        let outlierFrame = try makeTexture(kernels.device, width: width, height: height)
        fillMono(outlierFrame, values: [0.95], width: width, height: height)
        try accumulateSigmaClipped(kernels, source: outlierFrame, sum: sum, counts: counts, kappaSigma: 0.05, width: width, height: height)

        let finalCounts = readMono(counts, width: width, height: height)
        let finalSum = readMono(sum, width: width, height: height)
        // Rejected: count didn't advance, and the outlier's value never entered the sum.
        #expect(finalCounts[0] == 4)
        #expect(abs(finalSum[0] - (0.50 + 0.51 + 0.49 + 0.50)) < 0.0001)

        // A normal frame right after the rejected outlier still accumulates fine — rejection is
        // per-frame, not a stuck/broken state.
        let normalFrame = try makeTexture(kernels.device, width: width, height: height)
        fillMono(normalFrame, values: [0.50], width: width, height: height)
        try accumulateSigmaClipped(kernels, source: normalFrame, sum: sum, counts: counts, kappaSigma: 0.05, width: width, height: height)
        let afterCounts = readMono(counts, width: width, height: height)
        #expect(afterCounts[0] == 5)
    }

    /// End-to-end: sigma clipping keeps a stack's average close to the true signal even when one
    /// frame out of many is corrupted by an extreme outlier (a cosmic ray hit) — a plain average
    /// (`accumulateMono`) would instead permanently bake a chunk of that outlier into every future
    /// frame's displayed value, just diluted rather than removed.
    @Test func sigmaClippingKeepsTheAverageCloseToTrueValueDespiteOneCorruptedFrame() throws {
        let kernels = try makeKernels()
        let width = 1
        let height = 1
        let trueValue: Float = 0.5

        let clippedSum = try makeTexture(kernels.device, width: width, height: height)
        let clippedCounts = try makeTexture(kernels.device, width: width, height: height)
        let clippedResult = try makeTexture(kernels.device, width: width, height: height)
        fillMono(clippedSum, values: [0], width: width, height: height)
        fillMono(clippedCounts, values: [0], width: width, height: height)

        let plainAccumulator = try makeTexture(kernels.device, width: width, height: height)
        try clear(kernels, texture: plainAccumulator, width: width, height: height)

        var rng = SeededGenerator(seed: 99)
        for frameIndex in 0..<20 {
            // One frame, well after a baseline is established, gets hit by a cosmic ray —
            // pegged to 1.0 (fully saturated) instead of the real ~0.5 signal.
            let value: Float = frameIndex == 10 ? 1.0 : trueValue + Float.random(in: -0.02...0.02, using: &rng)
            let frame = try makeTexture(kernels.device, width: width, height: height)
            fillMono(frame, values: [value], width: width, height: height)
            try accumulateSigmaClipped(kernels, source: frame, sum: clippedSum, counts: clippedCounts, kappaSigma: 0.1, width: width, height: height)
            try accumulate(kernels, source: frame, accumulator: plainAccumulator, width: width, height: height)
        }
        try normalizeMaskedAccumulator(kernels, sum: clippedSum, counts: clippedCounts, destination: clippedResult, width: width, height: height)

        let clippedAverage = readMono(clippedResult, width: width, height: height)[0]
        let plainAverage = readMono(plainAccumulator, width: width, height: height)[0] / 20

        #expect(abs(clippedAverage - trueValue) < 0.03) // rejected the outlier — stays near 0.5
        #expect(abs(plainAverage - trueValue) > 0.02) // plain average visibly dragged toward 1.0
        #expect(abs(clippedAverage - trueValue) < abs(plainAverage - trueValue))
    }
}
