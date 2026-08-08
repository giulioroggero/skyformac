import Metal

/// GPU-accelerated per-frame sharpness scoring, self-contained from `MetalFrameRenderer` so it
/// can gate a continuous recording-to-disk pipeline independent of whichever renderer (CPU or
/// Metal) is driving the live preview. Unlike the live-preview GPU passes (best-effort, a stale
/// read is an acceptable trade-off), this blocks until the GPU finishes (`waitUntilCompleted`)
/// because a real per-frame keep/discard decision needs that exact frame's score, not a
/// slightly-stale one.
final class GPUSharpnessScorer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState

    private var sourceTexture: MTLTexture?
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var partialSumsBuffer: MTLBuffer?
    private var partialSumsCapacity = 0

    convenience init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.init(device: device)
    }

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "sharpnessPartialSums")
        else { return nil }
        self.device = device
        self.commandQueue = queue
        do {
            self.pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            return nil
        }
    }

    /// Mean squared-Laplacian ("sharpness energy") for `frame`, or `nil` if the frame isn't a
    /// mono RAW8/RAW16 buffer or GPU resources couldn't be allocated. Higher = sharper.
    func score(frame: CapturedFrame) -> Double? {
        guard frame.imageType == ASI_IMG_RAW8 || frame.imageType == ASI_IMG_RAW16 else { return nil }
        let pixelFormat: MTLPixelFormat = frame.imageType == ASI_IMG_RAW16 ? .r16Unorm : .r8Unorm
        let bytesPerPixel = frame.imageType == ASI_IMG_RAW16 ? 2 : 1

        if frame.width != sourceWidth || frame.height != sourceHeight || sourceTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: frame.width, height: frame.height, mipmapped: false
            )
            descriptor.usage = [.shaderRead]
            sourceTexture = device.makeTexture(descriptor: descriptor)
            sourceWidth = frame.width
            sourceHeight = frame.height
        }
        guard let sourceTexture else { return nil }

        frame.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            sourceTexture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0, withBytes: base, bytesPerRow: frame.width * bytesPerPixel
            )
        }

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let groupsX = (frame.width + 15) / 16
        let groupsY = (frame.height + 15) / 16
        let threadgroups = MTLSize(width: groupsX, height: groupsY, depth: 1)
        let groupCount = groupsX * groupsY

        if groupCount != partialSumsCapacity || partialSumsBuffer == nil {
            partialSumsBuffer = device.makeBuffer(length: groupCount * MemoryLayout<Float>.size, options: .storageModeShared)
            partialSumsCapacity = groupCount
        }
        guard let partialSumsBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setBuffer(partialSumsBuffer, offset: 0, index: 0)
        encoder.setThreadgroupMemoryLength(MemoryLayout<UInt32>.size, index: 0)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let partials = partialSumsBuffer.contents().bindMemory(to: Float.self, capacity: groupCount)
        var total = 0.0
        for i in 0..<groupCount { total += Double(partials[i]) }

        let validPixelCount = max((frame.width - 2) * (frame.height - 2), 1)
        return total / Double(validPixelCount)
    }
}
