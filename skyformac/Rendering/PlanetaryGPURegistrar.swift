import CoreGraphics
import Metal

/// GPU-accelerated replacement for `PlanetaryPostProcessor.scoreAndRegister`'s own per-frame
/// quality scoring (`quality(ofLuminance:...)`, a Laplacian-variance sharpness estimate) and
/// registration centroid (`centroid(ofLuminance:...)`) — the two CPU scalar loops left in the
/// registration stage after `PlanetaryGPULuminanceConverter` moved debayering itself to the GPU.
/// Same "one dispatch per frame on a single command queue, synchronous, read the result straight
/// back" shape that converter already uses, and the same reasoning for why: profiling a
/// multi-hundred-frame planetary burst, these two full-resolution scalar passes are the next
/// biggest per-frame cost after debayering, and both reduce naturally to the same "per-threadgroup
/// partial sums, summed on the CPU" pattern `MetalFrameRenderer`'s own live-stack drift-reduction
/// kernels (`roiStatsPartial`/`centroidPartial`) already use — `laplacianVariancePartial`/
/// `planetaryCentroidPartial` in `Shaders.metal` are that same shape, adapted for this stage's own
/// math (no background/threshold gate; an arbitrary, not fixed-square, `roi`).
///
/// `init?` fails — callers fall back to the CPU path — when there's no usable `MTLDevice`/Metal
/// library/pipeline, e.g. a sandboxed CI or headless test runner.
/// `@unchecked Sendable`: the mutable texture/buffer cache is only ever touched from whichever
/// single background thread `PlanetaryPostProcessor.scoreAndRegister`'s loop runs on *within one
/// burst* — that loop processes frames strictly one at a time, never concurrently (see
/// `scoreAndRegister`'s own doc comment). But `PlanetaryPostProcessor.gpuRegistrar` is one
/// `static let` shared across every burst/call site, and nothing stops two different bursts — or
/// two Swift Testing tests — from calling in concurrently on two different threads; `lock`
/// serializes those so a second concurrent call blocks instead of corrupting the first's cached
/// `luminanceTexture`/partials-buffer state (the same class of bug this fixes in
/// `PlanetaryGPUStacker`/`PlanetaryGPULuminanceConverter` — see their own doc comments).
/// Deliberately synchronous (`waitUntilCompleted()`, not a completion handler/async pipeline) for
/// the same reason `PlanetaryGPULuminanceConverter` is: this codebase already hit a real
/// thread-pool-exhaustion deadlock once from trying to pipeline GPU work with a blocking CPU wait
/// elsewhere in this exact pipeline (see git history around `PlanetaryPostProcessor.combine`) —
/// a plain synchronous round trip per frame (now serialized with a plain mutex, not a blocking
/// wait across a shared thread pool) has no such failure mode.
final class PlanetaryGPURegistrar: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let laplacianPipelineState: MTLComputePipelineState
    private let centroidPipelineState: MTLComputePipelineState
    private let lock = NSLock()

    private var luminanceTexture: MTLTexture?
    private var textureWidth = 0
    private var textureHeight = 0

    private var laplacianPartialsBuffer: MTLBuffer?
    private var centroidPartialsBuffer: MTLBuffer?
    private var partialsCapacity = 0

    private static let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let laplacianFunction = library.makeFunction(name: "laplacianVariancePartial"),
              let centroidFunction = library.makeFunction(name: "planetaryCentroidPartial"),
              let laplacianPipelineState = try? device.makeComputePipelineState(function: laplacianFunction),
              let centroidPipelineState = try? device.makeComputePipelineState(function: centroidFunction)
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.laplacianPipelineState = laplacianPipelineState
        self.centroidPipelineState = centroidPipelineState
    }

    /// Uploads `values` once, then runs both kernels against it — the quality score and
    /// centroid `scoreAndRegister` needs for every registered frame, in one GPU round trip
    /// instead of two. `roi` restricts the centroid (not the quality score, which always looks
    /// at the whole frame — sharpness isn't scoped to "the object," the frame as a whole is)
    /// exactly the way `centroid(ofLuminance:width:height:roi:)`'s CPU counterpart does; `nil`
    /// centroid in the result means "no usable signal," same as that function's own `nil`.
    func scoreAndCentroid(
        ofLuminance values: [Float], width: Int, height: Int, roi: CGRect?
    ) -> (quality: Double, centroid: SIMD2<Float>?)? {
        lock.lock()
        defer { lock.unlock() }
        guard width > 0, height > 0, values.count == width * height else { return nil }
        ensureLuminanceTexture(width: width, height: height)
        guard let luminanceTexture else { return nil }
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            luminanceTexture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: base, bytesPerRow: width * MemoryLayout<Float>.size
            )
        }

        let groupsX = (width + Self.threadsPerGroup.width - 1) / Self.threadsPerGroup.width
        let groupsY = (height + Self.threadsPerGroup.height - 1) / Self.threadsPerGroup.height
        let groupCount = groupsX * groupsY
        ensurePartialsBuffers(minimumCount: groupCount)
        guard let laplacianPartialsBuffer, let centroidPartialsBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        let threadgroups = MTLSize(width: groupsX, height: groupsY, depth: 1)

        encoder.setComputePipelineState(laplacianPipelineState)
        encoder.setTexture(luminanceTexture, index: 0)
        encoder.setBuffer(laplacianPartialsBuffer, offset: 0, index: 0)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 0)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 1)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 2)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: Self.threadsPerGroup)

        var rect = roi.map {
            (Int32($0.minX), Int32($0.minY), Int32($0.width), Int32($0.height))
        } ?? (Int32(0), Int32(0), Int32(width), Int32(height))
        encoder.setComputePipelineState(centroidPipelineState)
        encoder.setTexture(luminanceTexture, index: 0)
        encoder.setBytes(&rect, length: MemoryLayout.size(ofValue: rect), index: 0)
        encoder.setBuffer(centroidPartialsBuffer, offset: 0, index: 1)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 0)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 1)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 2)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 3)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: Self.threadsPerGroup)

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.error == nil else { return nil }

        let laplacianPartials = laplacianPartialsBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: groupCount)
        var sum: Double = 0, sumSq: Double = 0, count: Double = 0
        for i in 0..<groupCount {
            sum += Double(laplacianPartials[i].x)
            sumSq += Double(laplacianPartials[i].y)
            count += Double(laplacianPartials[i].z)
        }
        // Population variance via E[X²] - E[X]² — algebraically the same result
        // `SharpnessScorer.laplacianVariance`'s CPU two-pass (mean, then Σ(x-mean)²) computes,
        // just reachable from a single-pass GPU reduction.
        let mean = count > 0 ? sum / count : 0
        let meanSq = count > 0 ? sumSq / count : 0
        let quality = max(0, meanSq - mean * mean)

        let centroidPartials = centroidPartialsBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: groupCount)
        var sumI: Float = 0, sumIx: Float = 0, sumIy: Float = 0
        for i in 0..<groupCount {
            sumI += centroidPartials[i].x
            sumIx += centroidPartials[i].y
            sumIy += centroidPartials[i].z
        }
        let centroid = DriftAligner.centroid(sumI: sumI, sumIx: sumIx, sumIy: sumIy)
        return (quality, centroid)
    }

    private func ensureLuminanceTexture(width: Int, height: Int) {
        guard width != textureWidth || height != textureHeight || luminanceTexture == nil else { return }
        textureWidth = width
        textureHeight = height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        luminanceTexture = device.makeTexture(descriptor: descriptor)
    }

    private func ensurePartialsBuffers(minimumCount: Int) {
        guard minimumCount > partialsCapacity || laplacianPartialsBuffer == nil || centroidPartialsBuffer == nil else { return }
        partialsCapacity = minimumCount
        laplacianPartialsBuffer = device.makeBuffer(length: minimumCount * MemoryLayout<SIMD3<Float>>.stride)
        centroidPartialsBuffer = device.makeBuffer(length: minimumCount * MemoryLayout<SIMD4<Float>>.stride)
    }
}
