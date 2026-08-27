import Foundation
import Testing
@testable import skyformac

struct PlanetaryPostProcessorTests {
    private func monoFrame(width: Int, height: Int, value: (Int, Int) -> UInt8) -> CapturedFrame {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = value(x, y)
            }
        }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(bytes))
    }

    // MARK: - centroid / registration

    @Test func centroidFindsABrightBlobOffCenter() throws {
        // An 8x8 dark field with one bright 2x2 block near (5, 2) — the centroid should land
        // close to the middle of that block, not the frame's own geometric center.
        let frame = monoFrame(width: 8, height: 8) { x, y in
            (x >= 5 && x <= 6 && y >= 2 && y <= 3) ? 255 : 0
        }
        let centroid = try #require(PlanetaryPostProcessor.centroid(of: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, roi: nil))
        #expect(abs(centroid.x - 5.5) < 0.6)
        #expect(abs(centroid.y - 2.5) < 0.6)
    }

    @Test func centroidIsNilForAnEmptyFrame() {
        let frame = monoFrame(width: 8, height: 8) { _, _ in 0 }
        #expect(PlanetaryPostProcessor.centroid(of: frame, isColorCamera: false, bayerPattern: ASI_BAYER_RG, roi: nil) == nil)
    }

    @Test func scoreAndRegisterPicksTheSharpestFrameAsReferenceWithZeroShift() {
        // Two identical-brightness blobs, one sharp (hard edge), one blurred (soft edge) —
        // the sharp one should be picked as the registration reference, so its own shift is zero.
        let sharp = monoFrame(width: 16, height: 16) { x, y in (x >= 7 && x <= 8 && y >= 7 && y <= 8) ? 255 : 0 }
        let blurred = monoFrame(width: 16, height: 16) { x, y in (x >= 6 && x <= 9 && y >= 6 && y <= 9) ? 60 : 0 }
        let registered = PlanetaryPostProcessor.scoreAndRegister(
            frames: [blurred, sharp], isColorCamera: false, bayerPattern: ASI_BAYER_RG
        )
        #expect(registered.count == 2)
        let sharpFrame = registered[1]
        #expect(sharpFrame.shift.x == 0)
        #expect(sharpFrame.shift.y == 0)
        #expect(sharpFrame.quality > registered[0].quality)
    }

    // MARK: - bilinear shift

    @Test func bilinearShiftBySingleWholePixelMovesContentAsExpected() {
        // A single bright pixel at (2, 2) in a 5x5 field. Shifting by dx=1 should sample the
        // source one pixel to the right of each output position, i.e. output[1,2] == source[2,2].
        var values = [Float](repeating: 0, count: 25)
        values[2 * 5 + 2] = 1.0
        let shifted = PlanetaryPostProcessor.bilinearShift(values, width: 5, height: 5, channels: 1, dx: 1, dy: 0)
        #expect(shifted[2 * 5 + 1] == 1.0)
        #expect(shifted[2 * 5 + 2] == 0.0)
    }

    @Test func bilinearShiftByZeroIsIdentity() {
        let values: [Float] = [0.1, 0.2, 0.3, 0.4]
        let shifted = PlanetaryPostProcessor.bilinearShift(values, width: 2, height: 2, channels: 1, dx: 0, dy: 0)
        #expect(shifted == values)
    }

    // MARK: - stacking (mean / median)

    private func makeStackedFrames(width: Int, height: Int, pixelValues: [UInt8]) -> [CapturedFrame] {
        pixelValues.map { value in
            CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(repeating: value, count: width * height))
        }
    }

    @Test func meanStackAveragesFlatFrames() throws {
        let frames = makeStackedFrames(width: 4, height: 4, pixelValues: [100, 150, 200])
        let registered = frames.indices.map { PlanetaryPostProcessor.RegisteredFrame(index: $0, quality: Double($0 + 1), shift: .zero) }
        let result = try #require(PlanetaryPostProcessor.stack(
            frames: frames, registered: registered, isColorCamera: false, bayerPattern: ASI_BAYER_RG,
            keepBestPercent: 100, method: .mean
        ))
        let expected = Float(100 + 150 + 200) / 3 / 255
        #expect(abs(result.values[0] - expected) < 0.001)
    }

    @Test func medianStackRejectsAnOutlierFrame() throws {
        // Two normal frames and one wildly-off outlier — the median should sit with the normal
        // pair, unlike a mean, which the outlier would drag noticeably away from them.
        let frames = makeStackedFrames(width: 4, height: 4, pixelValues: [100, 102, 250])
        let registered = frames.indices.map { PlanetaryPostProcessor.RegisteredFrame(index: $0, quality: Double($0 + 1), shift: .zero) }
        let result = try #require(PlanetaryPostProcessor.stack(
            frames: frames, registered: registered, isColorCamera: false, bayerPattern: ASI_BAYER_RG,
            keepBestPercent: 100, method: .median
        ))
        let medianValue = result.values[0] * 255
        #expect(abs(medianValue - 102) < 1)
    }

    @Test func medianStackReportsItDidNotUseGPU() throws {
        // No GPU path exists for `.median` at all (see `PlanetaryGPUStacker`'s own doc comment) —
        // `didUseGPU` should say so definitively, not leave a caller guessing from the method
        // alone the way "GPU when available" (the log line this feeds) used to.
        let frames = makeStackedFrames(width: 4, height: 4, pixelValues: [100, 102, 250])
        let registered = frames.indices.map { PlanetaryPostProcessor.RegisteredFrame(index: $0, quality: Double($0 + 1), shift: .zero) }
        var reportedGPU: Bool?
        _ = PlanetaryPostProcessor.stack(
            frames: frames, registered: registered, isColorCamera: false, bayerPattern: ASI_BAYER_RG,
            keepBestPercent: 100, method: .median, didUseGPU: { reportedGPU = $0 }
        )
        #expect(reportedGPU == false)
    }

    @Test func meanStackReportsWhetherItUsedGPU() throws {
        let frames = makeStackedFrames(width: 4, height: 4, pixelValues: [100, 150, 200])
        let registered = frames.indices.map { PlanetaryPostProcessor.RegisteredFrame(index: $0, quality: Double($0 + 1), shift: .zero) }
        var reportedGPU: Bool?
        _ = PlanetaryPostProcessor.stack(
            frames: frames, registered: registered, isColorCamera: false, bayerPattern: ASI_BAYER_RG,
            keepBestPercent: 100, method: .mean, didUseGPU: { reportedGPU = $0 }
        )
        // Whichever way it actually went (depends on whether this environment has a usable
        // MTLDevice), the callback must fire exactly once with a real answer.
        #expect(reportedGPU != nil)
    }

    @Test func stackKeepBestPercentOnlyUsesTheSharpestFraction() throws {
        // Three frames at very different brightness; quality ranks frame 2 highest. Keeping only
        // the top 34% (1 of 3) should produce exactly that one frame's own value, not a blend.
        let frames = makeStackedFrames(width: 2, height: 2, pixelValues: [10, 20, 200])
        let registered = [
            PlanetaryPostProcessor.RegisteredFrame(index: 0, quality: 1, shift: .zero),
            PlanetaryPostProcessor.RegisteredFrame(index: 1, quality: 2, shift: .zero),
            PlanetaryPostProcessor.RegisteredFrame(index: 2, quality: 100, shift: .zero),
        ]
        let result = try #require(PlanetaryPostProcessor.stack(
            frames: frames, registered: registered, isColorCamera: false, bayerPattern: ASI_BAYER_RG,
            keepBestPercent: 34, method: .mean
        ))
        #expect(abs(result.values[0] - Float(200) / 255) < 0.001)
    }

    // MARK: - combine's chunk-splitting math

    @Test func chunkPlanNeverLeavesATrailingChunkPastCount() {
        // The exact case that crashed on CI (a core count producing a mismatch that never
        // occurs on a dev machine with enough cores that `count` itself caps the requested
        // chunk count): a requested chunk count that doesn't divide `count` evenly must not
        // still report a `chunkCount` whose last chunk would start at or past `count`.
        for count in 1...40 {
            for requested in 1...40 {
                let (chunkSize, chunkCount) = PlanetaryPostProcessor.chunkPlan(count: count, requestedChunkCount: requested)
                #expect(chunkSize > 0, "count=\(count) requested=\(requested)")
                #expect(chunkCount > 0, "count=\(count) requested=\(requested)")
                let lastChunkStart = (chunkCount - 1) * chunkSize
                #expect(lastChunkStart < count, "count=\(count) requested=\(requested) produced lastChunkStart=\(lastChunkStart)")
            }
        }
    }

    @Test func chunkPlanCoversEveryIndexExactlyOnce() {
        // Every pixel 0..<count must fall in exactly one chunk — no gaps, no overlaps.
        for count in [1, 5, 7, 16, 17, 33] {
            for requested in [1, 3, 5, 12, 16, 32] {
                let (chunkSize, chunkCount) = PlanetaryPostProcessor.chunkPlan(count: count, requestedChunkCount: requested)
                var covered = [Bool](repeating: false, count: count)
                for chunkIndex in 0..<chunkCount {
                    let start = chunkIndex * chunkSize
                    let end = min(start + chunkSize, count)
                    guard start < end else { continue }
                    for pixel in start..<end {
                        #expect(!covered[pixel], "pixel \(pixel) covered twice (count=\(count) requested=\(requested))")
                        covered[pixel] = true
                    }
                }
                #expect(covered.allSatisfy { $0 }, "count=\(count) requested=\(requested) left a gap")
            }
        }
    }

    @Test func chunkPlanIsEmptyForZeroCount() {
        let (chunkSize, chunkCount) = PlanetaryPostProcessor.chunkPlan(count: 0, requestedChunkCount: 8)
        #expect(chunkSize == 0)
        #expect(chunkCount == 0)
    }

    // MARK: - wavelet sharpening

    @Test func waveletSharpenIncreasesEdgeContrastOnAStepEdge() {
        let width = 32, height = 8
        var values = [Float](repeating: 0.2, count: width * height)
        for y in 0..<height {
            for x in 16..<width {
                values[y * width + x] = 0.8
            }
        }
        let image = PlanetaryPostProcessor.StackedImage(width: width, height: height, channels: 1, values: values)
        let layers = [
            PlanetaryPostProcessor.WaveletLayer(id: 0, gain: 2.0),
            PlanetaryPostProcessor.WaveletLayer(id: 1, gain: 1.0),
        ]
        let sharpened = PlanetaryPostProcessor.waveletSharpen(image, layers: layers, denoise: 0)

        let leftIndex = 4 * width + 15
        let rightIndex = 4 * width + 16
        let originalContrast = values[rightIndex] - values[leftIndex]
        let sharpenedContrast = sharpened.values[rightIndex] - sharpened.values[leftIndex]
        #expect(sharpenedContrast >= originalContrast)
    }

    @Test func waveletSharpenWithNoLayersIsIdentity() {
        let image = PlanetaryPostProcessor.StackedImage(width: 4, height: 4, channels: 1, values: [Float](repeating: 0.5, count: 16))
        let result = PlanetaryPostProcessor.waveletSharpen(image, layers: [], denoise: 0)
        #expect(result.values == image.values)
    }

    @Test func waveletSharpenClampsOutputToValidRange() {
        let image = PlanetaryPostProcessor.StackedImage(width: 4, height: 4, channels: 1, values: [Float](repeating: 0.9, count: 16))
        let layers = [PlanetaryPostProcessor.WaveletLayer(id: 0, gain: 50)]
        let result = PlanetaryPostProcessor.waveletSharpen(image, layers: layers, denoise: 0)
        #expect(result.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    // MARK: - RGB channel alignment

    @Test func alignRGBChannelsIsANoOpForMonoImages() {
        let image = PlanetaryPostProcessor.StackedImage(width: 4, height: 4, channels: 1, values: [Float](repeating: 0.5, count: 16))
        let result = PlanetaryPostProcessor.alignRGBChannels(image)
        #expect(result.values == image.values)
    }

    @Test func alignRGBChannelsShiftsAnOffsetRedChannelOntoGreen() {
        let width = 12, height = 12
        var values = [Float](repeating: 0, count: width * height * 3)
        // Green blob centered at (6, 6); red blob (same shape) offset by +1 in x.
        for y in 5...7 {
            for x in 5...7 {
                values[(y * width + x) * 3 + 1] = 1.0 // green
            }
        }
        for y in 5...7 {
            for x in 6...8 {
                values[(y * width + x) * 3] = 1.0 // red, shifted +1 in x
            }
        }
        let image = PlanetaryPostProcessor.StackedImage(width: width, height: height, channels: 3, values: values)
        let aligned = PlanetaryPostProcessor.alignRGBChannels(image)

        var redCentroidX: Float = 0
        var weight: Float = 0
        for y in 0..<height {
            for x in 0..<width {
                let v = aligned.values[(y * width + x) * 3]
                redCentroidX += v * Float(x)
                weight += v
            }
        }
        redCentroidX /= max(weight, 0.001)
        // Before alignment the red blob's own centroid sits at x = 7; after aligning onto green
        // (centroid x = 6) it should have moved measurably closer to 6.
        #expect(abs(redCentroidX - 6) < abs(7 - 6))
    }

    /// Regression test for the exact failure reported: a whole-frame centroid on a small, faint
    /// target against a mostly-empty frame can be dominated by noise/background rather than the
    /// target, computing an implausibly large "correction" that moves a channel's blob somewhere
    /// else entirely instead of the few-pixel nudge real atmospheric dispersion would need —
    /// stacking R/G/B into three separate, non-overlapping blobs instead of one aligned image.
    /// `alignRGBChannels` should recognize a shift far larger than real dispersion could ever be
    /// and leave that channel alone rather than applying it.
    @Test func alignRGBChannelsSkipsAnImplausiblyLargeShift() {
        let width = 40, height = 40
        var values = [Float](repeating: 0, count: width * height * 3)
        // Green blob near the top-left...
        for y in 4...6 {
            for x in 4...6 {
                values[(y * width + x) * 3 + 1] = 1.0
            }
        }
        // ...red blob near the bottom-right — nowhere close to a real dispersion-fringing offset.
        for y in 33...35 {
            for x in 33...35 {
                values[(y * width + x) * 3] = 1.0
            }
        }
        let image = PlanetaryPostProcessor.StackedImage(width: width, height: height, channels: 3, values: values)
        let aligned = PlanetaryPostProcessor.alignRGBChannels(image)

        // Unchanged: the huge, clearly-wrong shift should have been skipped, not applied.
        #expect(aligned.values == image.values)
    }

    // MARK: - GPU registration (PlanetaryGPURegistrar)

    private func luminanceGrid(width: Int, height: Int, value: (Int, Int) -> Float) -> [Float] {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = value(x, y)
            }
        }
        return values
    }

    /// Cross-checks `PlanetaryGPURegistrar`'s centroid kernel against
    /// `PlanetaryPostProcessor.centroid(ofLuminance:...)`'s CPU implementation — both compute the
    /// exact same intensity-weighted-sum formula (unlike quality/variance below, which
    /// deliberately runs at a different scale on GPU), so real numeric parity is expected here,
    /// not just "in the right neighborhood." Skips when this environment has no usable
    /// `MTLDevice`.
    @Test func gpuRegistrarCentroidMatchesCPUCentroid() throws {
        let width = 32, height = 32
        let values = luminanceGrid(width: width, height: height) { x, y in
            (x >= 20 && x <= 23 && y >= 8 && y <= 11) ? 1.0 : 0.02
        }
        guard let gpu = PlanetaryGPURegistrar() else { return }
        let gpuResult = try #require(gpu.scoreAndCentroid(ofLuminance: values, width: width, height: height, roi: nil))
        let gpuCentroid = try #require(gpuResult.centroid)
        let cpuCentroid = try #require(PlanetaryPostProcessor.centroid(ofLuminance: values, width: width, height: height, roi: nil))
        #expect(abs(gpuCentroid.x - cpuCentroid.x) < 0.05)
        #expect(abs(gpuCentroid.y - cpuCentroid.y) < 0.05)
    }

    /// The actual property the "duplicated images" fix depends on: restricting the GPU centroid
    /// to `roi` should land on the blob *inside* it, ignoring an equally-bright blob outside —
    /// not the whole-frame weighted average of both (which is exactly the failure mode being
    /// fixed). Skips when this environment has no usable `MTLDevice`.
    @Test func gpuRegistrarCentroidRespectsROI() throws {
        let width = 40, height = 40
        let values = luminanceGrid(width: width, height: height) { x, y in
            let inTopLeft = x >= 4 && x <= 6 && y >= 4 && y <= 6
            let inBottomRight = x >= 30 && x <= 32 && y >= 30 && y <= 32
            return (inTopLeft || inBottomRight) ? 1.0 : 0.0
        }
        guard let gpu = PlanetaryGPURegistrar() else { return }
        let roi = CGRect(x: 2, y: 2, width: 8, height: 8) // covers only the top-left blob
        let result = try #require(gpu.scoreAndCentroid(ofLuminance: values, width: width, height: height, roi: roi))
        let centroid = try #require(result.centroid)
        #expect(abs(centroid.x - 5) < 1)
        #expect(abs(centroid.y - 5) < 1)
    }

    /// `quality` deliberately runs at full resolution on GPU rather than matching the CPU path's
    /// downsampled-to-512 scale (see `PlanetaryGPURegistrar`'s own doc comment) — so this checks
    /// the property that actually matters (a sharper image scores higher, the same relative
    /// ranking `scoreAndRegister` sorts by), not exact parity with the CPU number. Skips when
    /// this environment has no usable `MTLDevice`.
    @Test func gpuRegistrarQualityRanksASharperImageHigher() throws {
        let width = 16, height = 16
        let sharp = luminanceGrid(width: width, height: height) { x, _ in x < 8 ? 0.0 : 1.0 }
        let blurred = luminanceGrid(width: width, height: height) { x, _ in
            Float(x) / Float(width - 1) // a smooth ramp — no hard edge anywhere
        }
        guard let gpu = PlanetaryGPURegistrar() else { return }
        let sharpResult = try #require(gpu.scoreAndCentroid(ofLuminance: sharp, width: width, height: height, roi: nil))
        let blurredResult = try #require(gpu.scoreAndCentroid(ofLuminance: blurred, width: width, height: height, roi: nil))
        #expect(sharpResult.quality > blurredResult.quality)
    }

    // MARK: - GPU mean-stacking (PlanetaryGPUStacker)

    /// Cross-checks `PlanetaryGPUStacker.meanStack` against the CPU path it replaces for
    /// `.mean` — `bilinearShift` per frame, then a plain per-pixel average — for a mono
    /// (`channels == 1`) burst. Tight tolerance is expected: both sides do the exact same
    /// bilinear-interpolation math, just on GPU vs CPU. Skips when this environment has no
    /// usable `MTLDevice`.
    @Test func gpuMeanStackMatchesCPUBilinearShiftAndAverageForMono() throws {
        let width = 24, height = 24, channels = 1
        let frames: [[Float]] = (0..<5).map { seed in
            luminanceGrid(width: width, height: height) { x, y in
                let cx = 10 + seed, cy = 12 - seed
                return (x >= cx && x <= cx + 2 && y >= cy && y <= cy + 2) ? 0.9 : 0.1
            }
        }
        let shifts: [SIMD2<Float>] = (0..<5).map { SIMD2<Float>(Float($0) * 0.4 - 0.6, Float($0) * -0.3 + 0.5) }

        guard let gpu = PlanetaryGPUStacker() else { return }
        let gpuResult = try #require(
            gpu.meanStack(frames, shifts: shifts, width: width, height: height, channels: channels, isCancelled: { false })
        )

        let cpuShifted = zip(frames, shifts).map {
            PlanetaryPostProcessor.bilinearShift($0, width: width, height: height, channels: channels, dx: $1.x, dy: $1.y)
        }
        var cpuAverage = [Float](repeating: 0, count: width * height * channels)
        for shifted in cpuShifted {
            for i in cpuAverage.indices { cpuAverage[i] += shifted[i] }
        }
        for i in cpuAverage.indices { cpuAverage[i] /= Float(cpuShifted.count) }

        #expect(gpuResult.count == cpuAverage.count)
        for i in gpuResult.indices {
            #expect(abs(gpuResult[i] - cpuAverage[i]) < 0.01)
        }
    }

    /// Same cross-check as above, for a debayered RGB (`channels == 3`) burst — the path
    /// `accumulateRGBAAligned` (as opposed to the pre-existing mono-only `accumulateMonoAligned`)
    /// exists for. Skips when this environment has no usable `MTLDevice`.
    @Test func gpuMeanStackMatchesCPUBilinearShiftAndAverageForRGB() throws {
        let width = 20, height = 20, channels = 3
        func rgbGrid(seed: Int) -> [Float] {
            var values = [Float](repeating: 0, count: width * height * channels)
            for y in 0..<height {
                for x in 0..<width {
                    let base = (y * width + x) * channels
                    let inBlob = x >= 8 + seed && x <= 10 + seed && y >= 8 && y <= 10
                    values[base] = inBlob ? 0.8 : 0.05 // R
                    values[base + 1] = inBlob ? 0.6 : 0.1 // G
                    values[base + 2] = inBlob ? 0.4 : 0.15 // B
                }
            }
            return values
        }
        let frames: [[Float]] = (0..<4).map { rgbGrid(seed: $0) }
        let shifts: [SIMD2<Float>] = (0..<4).map { SIMD2<Float>(Float($0) * -0.5, Float($0) * 0.2) }

        guard let gpu = PlanetaryGPUStacker() else { return }
        let gpuResult = try #require(
            gpu.meanStack(frames, shifts: shifts, width: width, height: height, channels: channels, isCancelled: { false })
        )

        let cpuShifted = zip(frames, shifts).map {
            PlanetaryPostProcessor.bilinearShift($0, width: width, height: height, channels: channels, dx: $1.x, dy: $1.y)
        }
        var cpuAverage = [Float](repeating: 0, count: width * height * channels)
        for shifted in cpuShifted {
            for i in cpuAverage.indices { cpuAverage[i] += shifted[i] }
        }
        for i in cpuAverage.indices { cpuAverage[i] /= Float(cpuShifted.count) }

        #expect(gpuResult.count == cpuAverage.count)
        for i in gpuResult.indices {
            #expect(abs(gpuResult[i] - cpuAverage[i]) < 0.01)
        }
    }

    // MARK: - GPU debayer/luma

    /// Cross-checks `PlanetaryGPULuminanceConverter`'s Metal `debayerToLuma` kernel against
    /// `Debayer.swift`'s existing CPU bilinear demosaic + a manual RGB→luma combination,
    /// independent of `PlanetaryPostProcessor.luminance`'s own GPU/CPU routing — a real
    /// pixel-for-pixel parity check, not just "doesn't crash." Skips (returns early) when this
    /// environment has no usable `MTLDevice` (e.g. a sandboxed CI runner) — nothing to compare.
    @Test func gpuDebayerLumaMatchesCPUDebayerForAColorFrame() throws {
        let width = 16, height = 16
        var bytes = [UInt8](repeating: 20, count: width * height)
        for y in 6..<10 {
            for x in 6..<10 {
                bytes[y * width + x] = 200
            }
        }
        let frame = CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(bytes))
        guard let gpu = PlanetaryGPULuminanceConverter() else { return }
        let gpuValues = try #require(gpu.luminance(of: frame, bayerPattern: ASI_BAYER_RG))

        let cpuRGB = try #require(Debayer.debayerRAW8(frame, pattern: ASI_BAYER_RG))
        var cpuLuma = [Float](repeating: 0, count: width * height)
        cpuRGB.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<(width * height) {
                let o = i * 3
                cpuLuma[i] = (Float(base[o]) * 0.299 + Float(base[o + 1]) * 0.587 + Float(base[o + 2]) * 0.114) / 255
            }
        }
        #expect(gpuValues.count == cpuLuma.count)
        for i in gpuValues.indices {
            #expect(abs(gpuValues[i] - cpuLuma[i]) < 0.02)
        }
    }

    /// Same cross-check as `gpuDebayerLumaMatchesCPUDebayerForAColorFrame`, for the full-RGB
    /// `debayerToRGB` kernel `PlanetaryPostProcessor.stack` now relies on.
    @Test func gpuDebayerRGBMatchesCPUDebayerForAColorFrame() throws {
        let width = 16, height = 16
        var bytes = [UInt8](repeating: 20, count: width * height)
        for y in 6..<10 {
            for x in 6..<10 {
                bytes[y * width + x] = 200
            }
        }
        let frame = CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(bytes))
        guard let gpu = PlanetaryGPULuminanceConverter() else { return }
        let gpuRGB = try #require(gpu.rgb(of: frame, bayerPattern: ASI_BAYER_RG))

        let cpuRGB = try #require(Debayer.debayerRAW8(frame, pattern: ASI_BAYER_RG))
        #expect(gpuRGB.count == width * height * 3)
        cpuRGB.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            for i in 0..<gpuRGB.count {
                #expect(abs(gpuRGB[i] - Float(base[i]) / 255) < 0.02)
            }
        }
    }

    @Test func gpuLuminanceConverterReturnsNilForAnUnsupportedImageType() {
        guard let gpu = PlanetaryGPULuminanceConverter() else { return }
        let frame = CapturedFrame(width: 4, height: 4, imageType: ASI_IMG_RGB24, data: Data(repeating: 100, count: 48))
        #expect(gpu.luminance(of: frame, bayerPattern: ASI_BAYER_RG) == nil)
    }

    // MARK: - rendering / histogram

    @Test func histogramOfAFlatImageIsAllInOneBucket() {
        let image = PlanetaryPostProcessor.StackedImage(width: 4, height: 4, channels: 1, values: [Float](repeating: 0.5, count: 16))
        let histogram = PlanetaryPostProcessor.histogram(of: image)
        #expect(histogram[Int(0.5 * 255)] == 16)
        #expect(histogram.reduce(0, +) == 16)
    }

    @Test func renderImageProducesACGImageWithMatchingDimensions() throws {
        let image = PlanetaryPostProcessor.StackedImage(width: 8, height: 6, channels: 3, values: [Float](repeating: 0.5, count: 8 * 6 * 3))
        let cgImage = try #require(PlanetaryPostProcessor.renderImage(image, blackPoint: 0, whitePoint: 1, logStretchIntensity: nil))
        #expect(cgImage.width == 8)
        #expect(cgImage.height == 6)
    }

    // MARK: - combining multiple captures (loadSequence(from: [URL]))

    /// `SERWriter.write`'s own blank-frame guard rejects an all-identical-byte frame — a simple
    /// per-frame gradient (rather than a uniform fill) keeps every written frame accepted.
    private func writeTestSER(
        frameCount: Int, width: Int = 4, height: Int = 4, isColorCamera: Bool = false, to url: URL
    ) throws {
        let firstFrame = monoFrame(width: width, height: height) { x, y in UInt8((x + y) % 255) }
        let writer = try SERWriter(firstFrame: firstFrame, isColorCamera: isColorCamera, bayerPattern: ASI_BAYER_RG, instrumentName: "test", url: url)
        try writer.write(firstFrame)
        for i in 1..<frameCount {
            try writer.write(monoFrame(width: width, height: height) { x, y in UInt8((x + y + i) % 255) })
        }
        try writer.close()
    }

    @Test func loadSequenceFromMultipleURLsPoolsEveryFilesFrames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let urlA = dir.appendingPathComponent("a.ser")
        let urlB = dir.appendingPathComponent("b.ser")
        try writeTestSER(frameCount: 3, to: urlA)
        try writeTestSER(frameCount: 2, to: urlB)

        let sequence = try PlanetaryPostProcessor.loadSequence(from: [urlA, urlB])
        #expect(sequence.frames.count == 5)
    }

    @Test func loadSequenceFromASingleURLMatchesTheSingleURLOverload() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("a.ser")
        try writeTestSER(frameCount: 3, to: url)

        let viaSingle = try PlanetaryPostProcessor.loadSequence(from: url)
        let viaArray = try PlanetaryPostProcessor.loadSequence(from: [url])
        #expect(viaSingle.frames.count == viaArray.frames.count)
        #expect(viaArray.frames.count == 3)
    }

    @Test func loadSequenceRejectsCombiningDifferentlySizedCaptures() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let urlA = dir.appendingPathComponent("a.ser")
        let urlB = dir.appendingPathComponent("b.ser")
        try writeTestSER(frameCount: 2, width: 4, height: 4, to: urlA)
        try writeTestSER(frameCount: 2, width: 8, height: 8, to: urlB)

        #expect(throws: PlanetaryPostProcessor.LoadSequenceError.self) {
            try PlanetaryPostProcessor.loadSequence(from: [urlA, urlB])
        }
    }

    @Test func loadSequenceRejectsCombiningDifferentColorModes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let urlA = dir.appendingPathComponent("a.ser")
        let urlB = dir.appendingPathComponent("b.ser")
        try writeTestSER(frameCount: 2, isColorCamera: false, to: urlA)
        try writeTestSER(frameCount: 2, isColorCamera: true, to: urlB)

        #expect(throws: PlanetaryPostProcessor.LoadSequenceError.self) {
            try PlanetaryPostProcessor.loadSequence(from: [urlA, urlB])
        }
    }
}
