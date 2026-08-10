import Foundation
import Metal

/// GPU equivalent of `FrameArithmetic.subtract` + `FlatFieldCorrector.correct`, combined into one
/// dispatch (dark subtract, then flat divide) instead of two scalar CPU passes over the frame —
/// `FlatFieldCorrector`'s per-pixel `Double` divide in particular is real work at multi-megapixel
/// sensor sizes. Used by `CameraManager.applyDarkSubtraction` when the Metal renderer is enabled.
///
/// The calibrated result still has to come back as CPU-resident `Data` afterward — planetary
/// tracking, lucky imaging, and FITS recording all consume the calibrated frame on the CPU side,
/// not just the live preview — so this isn't a "stay on GPU forever" pipeline stage the way
/// debayer/stretch is; it's a GPU dispatch replacing a CPU loop, with one readback at the end. The
/// win is real regardless: one GPU pass over the sensor data instead of two scalar Swift loops.
///
/// An `actor`, matching `GPUStillImageRenderer`'s reasoning: mutable buffers must not be read from
/// or written to by two overlapping calls at once.
actor GPUFrameCalibrator {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let calibrate8Pipeline: MTLComputePipelineState
    private let calibrate16Pipeline: MTLComputePipelineState
    private let placeholderBuffer: MTLBuffer

    private var lightBuffer: MTLBuffer?
    private var darkBuffer: MTLBuffer?
    private var flatBuffer: MTLBuffer?
    private var outputBuffer: MTLBuffer?
    private var bufferPixelCount = 0
    private var bufferBytesPerPixel = 0

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let calibrate8Fn = library.makeFunction(name: "calibrateRaw8"),
              let calibrate16Fn = library.makeFunction(name: "calibrateRaw16"),
              let placeholder = device.makeBuffer(length: 1, options: .storageModeShared)
        else { return nil }

        self.device = device
        self.commandQueue = queue
        self.placeholderBuffer = placeholder
        do {
            self.calibrate8Pipeline = try device.makeComputePipelineState(function: calibrate8Fn)
            self.calibrate16Pipeline = try device.makeComputePipelineState(function: calibrate16Fn)
        } catch {
            return nil
        }
    }

    /// `nil` if neither `dark` nor `flat` is supplied, dimensions/image types don't line up, or
    /// `light` isn't RAW8/Y8/RAW16 (RGB24 webcam/iPhone frames never go through dark/flat
    /// calibration in this app). Callers should fall back to the CPU
    /// `FrameArithmetic`/`FlatFieldCorrector` path in any of those cases.
    func calibrate(light: CapturedFrame, dark: CapturedFrame?, flat: CapturedFrame?, flatMean: Double?) -> CapturedFrame? {
        guard dark != nil || flat != nil else { return nil }
        let bytesPerPixel: Int
        switch light.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8: bytesPerPixel = 1
        case ASI_IMG_RAW16: bytesPerPixel = 2
        default: return nil
        }
        if let dark, dark.imageType.rawValue != light.imageType.rawValue
            || dark.width != light.width || dark.height != light.height {
            return nil
        }
        if let flat, flat.imageType.rawValue != light.imageType.rawValue
            || flat.width != light.width || flat.height != light.height {
            return nil
        }

        let pixelCount = light.width * light.height
        let byteCount = pixelCount * bytesPerPixel
        guard light.data.count >= byteCount else { return nil }
        ensureBuffers(pixelCount: pixelCount, bytesPerPixel: bytesPerPixel)
        guard let lightBuffer, let darkBuffer, let flatBuffer, let outputBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        light.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(lightBuffer.contents(), base, byteCount)
        }
        if let dark {
            dark.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(darkBuffer.contents(), base, min(dark.data.count, byteCount))
            }
        }
        if let flat {
            flat.data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(flatBuffer.contents(), base, min(flat.data.count, byteCount))
            }
        }

        var params = CalibrationParams(
            flatMean: Float(flatMean ?? 0),
            hasDark: dark != nil ? 1 : 0,
            hasFlat: flat != nil ? 1 : 0,
            maxValue: bytesPerPixel == 1 ? 255.0 : 65535.0
        )
        let pipeline = bytesPerPixel == 1 ? calibrate8Pipeline : calibrate16Pipeline
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(lightBuffer, offset: 0, index: 0)
        encoder.setBuffer(dark != nil ? darkBuffer : placeholderBuffer, offset: 0, index: 1)
        encoder.setBuffer(flat != nil ? flatBuffer : placeholderBuffer, offset: 0, index: 2)
        encoder.setBuffer(outputBuffer, offset: 0, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<CalibrationParams>.stride, index: 4)

        let threadsPerGroup = MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        let threadgroups = MTLSize(width: (pixelCount + threadsPerGroup.width - 1) / threadsPerGroup.width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var output = Data(count: byteCount)
        output.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(base, outputBuffer.contents(), byteCount)
        }
        return CapturedFrame(width: light.width, height: light.height, imageType: light.imageType, data: output)
    }

    private func ensureBuffers(pixelCount: Int, bytesPerPixel: Int) {
        guard pixelCount != bufferPixelCount || bytesPerPixel != bufferBytesPerPixel else { return }
        bufferPixelCount = pixelCount
        bufferBytesPerPixel = bytesPerPixel
        let byteCount = pixelCount * bytesPerPixel
        lightBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
        darkBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
        flatBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
        outputBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
    }
}

/// Mirrors `Shaders.metal`'s `CalibrationParams` struct layout exactly (same field order/types,
/// all 4-byte-aligned, no padding surprises).
private struct CalibrationParams {
    var flatMean: Float
    var hasDark: UInt32
    var hasFlat: UInt32
    var maxValue: Float
}
