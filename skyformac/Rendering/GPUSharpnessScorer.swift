import Metal

/// GPU-accelerated per-frame sharpness scoring, self-contained from `MetalFrameRenderer` so it
/// can gate a continuous recording-to-disk pipeline independent of whichever renderer (CPU or
/// Metal) is driving the live preview. Unlike the live-preview GPU passes (best-effort, a stale
/// read is an acceptable trade-off), this blocks until the GPU finishes (`waitUntilCompleted`)
/// because a real per-frame keep/discard decision needs that exact frame's score, not a
/// slightly-stale one.
final class GPUSharpnessScorer {
    /// Caps the effective resolution this scorer's dispatch/reduction cost scales with, regardless
    /// of the actual sensor/ROI size — matching `SharpnessScorer` (the CPU sibling used for Lucky
    /// Imaging's own ranking), which already downsamples to this same limit before scoring. See
    /// the `sharpnessPartialSums` kernel's doc comment for the real bug this fixes: without a cap,
    /// a full-sensor ROI (deliberately used by, e.g., the Moon's Planetary Preset) at a fast
    /// planetary frame rate meant this dispatch ran at full native resolution every incoming
    /// frame, synchronously, on whichever thread called `score` — in practice `@MainActor`.
    private static let maxDimension = 512

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

        // Sample on a strided grid, not every raw pixel — see `Self.maxDimension`'s doc comment.
        // A small frame (any real planetary ROI) gets `stride == 1`, i.e. exactly today's
        // behavior; only a full-sensor-sized frame actually gets downsampled.
        let stride = max(1, max(frame.width, frame.height) / Self.maxDimension)
        var sampleStride = UInt32(stride)
        let sampledWidth = frame.width / stride
        let sampledHeight = frame.height / stride

        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let groupsX = (sampledWidth + 15) / 16
        let groupsY = (sampledHeight + 15) / 16
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
        encoder.setBytes(&sampleStride, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setThreadgroupMemoryLength(MemoryLayout<UInt32>.size, index: 0)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let partials = partialSumsBuffer.contents().bindMemory(to: Float.self, capacity: groupCount)
        var total = 0.0
        for i in 0..<groupCount { total += Double(partials[i]) }

        // Normalized by the *sampled* grid's size, not the original frame's — this is a mean
        // over however many Laplacian samples were actually taken, so the metric stays a
        // comparable "average sharpness energy per sample" regardless of `stride`.
        let validSampleCount = max((sampledWidth - 2) * (sampledHeight - 2), 1)
        return total / Double(validSampleCount)
    }
}
