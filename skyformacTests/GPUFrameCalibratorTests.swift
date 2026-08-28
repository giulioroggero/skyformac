import Foundation
import Metal
import Testing
@testable import skyformac

/// Cross-checks `GPUFrameCalibrator`'s Metal kernels against the CPU `FrameArithmetic`/
/// `FlatFieldCorrector` reference implementations they're meant to match pixel-for-pixel — see
/// `FrameArithmeticTests`/`FlatFieldCorrectorTests` for the CPU-side cases this mirrors.
/// `.serialized` — Swift Testing runs a suite's tests concurrently by default, and each test here
/// stands up its own `GPUFrameCalibrator` against the same physical/virtualized GPU; on a
/// resource-constrained CI runner, several of these submitting Metal command buffers at once was
/// the actual source of this suite's intermittent failures (confirmed: reruns in isolation always
/// passed), not a bug in the kernels themselves. Running them one at a time removes that
/// contention instead of just tolerating it via retries alone.
@Suite(.serialized)
struct GPUFrameCalibratorTests {
    private func makeCalibrator() throws -> GPUFrameCalibrator {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // Not `try #require(GPUFrameCalibrator(device: device))` directly — wrapping an actor's
        // initializer call inline inside `#require`'s macro-generated autoclosure triggers
        // "sending '$1' risks causing data races" under Xcode 16.4's Swift 6 checking (not
        // reproduced on a newer local Xcode). Binding the result to a plain optional first, then
        // `#require`-ing *that*, avoids the macro ever needing to embed the constructor call
        // itself in its expansion.
        let calibrator = GPUFrameCalibrator(device: device)
        return try #require(calibrator)
    }

    @Test func darkSubtractionMatchesCPUForRAW8() async throws {
        let calibrator = try makeCalibrator()
        let light = CapturedFrame(width: 4, height: 1, imageType: ASI_IMG_RAW8, data: Data([50, 100, 10, 255]))
        let dark = CapturedFrame(width: 4, height: 1, imageType: ASI_IMG_RAW8, data: Data([10, 10, 20, 0]))

        let gpuResult = try #require(await calibrator.calibrate(light: light, dark: dark, flat: nil, flatMean: nil))
        let cpuResult = try #require(FrameArithmetic.subtract(light: light, dark: dark))
        #expect(Array(gpuResult.data) == Array(cpuResult.data))
        #expect(Array(gpuResult.data) == [40, 90, 0, 255]) // 10-20 clamps to 0, not underflow
    }

    @Test func flatCorrectionMatchesCPUForRAW8() async throws {
        let calibrator = try makeCalibrator()
        // Same vignetting scenario as `FlatFieldCorrectorTests.correctsVignettingViaDivision`.
        let light = CapturedFrame(width: 4, height: 1, imageType: ASI_IMG_RAW8, data: Data([100, 100, 100, 100]))
        let flat = CapturedFrame(width: 4, height: 1, imageType: ASI_IMG_RAW8, data: Data([200, 200, 100, 100]))
        let flatMean = 150.0

        let gpuResult = try #require(
            await calibrator.calibrate(light: light, dark: nil, flat: flat, flatMean: flatMean)
        )
        let cpuResult = try #require(
            FlatFieldCorrector.correct(light: light, flat: flat, precomputedFlatMean: flatMean)
        )
        #expect(Array(gpuResult.data) == Array(cpuResult.data))
        #expect(Array(gpuResult.data) == [75, 75, 150, 150])
    }

    @Test func combinedDarkAndFlatMatchesCPUForRAW16() async throws {
        let calibrator = try makeCalibrator()
        var lightData = Data(count: 4)
        lightData.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 1200; p[1] = 1200
        }
        var darkData = Data(count: 4)
        darkData.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 200; p[1] = 200
        }
        var flatData = Data(count: 4)
        flatData.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            p[0] = 40000; p[1] = 20000
        }
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW16, data: lightData)
        let dark = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW16, data: darkData)
        let flat = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW16, data: flatData)
        let flatMean = 30000.0

        let gpuResult = try #require(
            await calibrator.calibrate(light: light, dark: dark, flat: flat, flatMean: flatMean)
        )
        let cpuSubtracted = try #require(FrameArithmetic.subtract(light: light, dark: dark))
        let cpuResult = try #require(
            FlatFieldCorrector.correct(light: cpuSubtracted, flat: flat, precomputedFlatMean: flatMean)
        )
        #expect(Array(gpuResult.data) == Array(cpuResult.data))
    }

    @Test func mismatchedDimensionsReturnsNil() async throws {
        let calibrator = try makeCalibrator()
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([1, 2]))
        let dark = CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RAW8, data: Data([1]))
        let result = await calibrator.calibrate(light: light, dark: dark, flat: nil, flatMean: nil)
        #expect(result == nil)
    }

    @Test func neitherDarkNorFlatReturnsNil() async throws {
        let calibrator = try makeCalibrator()
        let light = CapturedFrame(width: 2, height: 1, imageType: ASI_IMG_RAW8, data: Data([1, 2]))
        let result = await calibrator.calibrate(light: light, dark: nil, flat: nil, flatMean: nil)
        #expect(result == nil)
    }
}
