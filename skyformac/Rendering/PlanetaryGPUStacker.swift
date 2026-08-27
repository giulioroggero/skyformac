import Metal
import simd

/// GPU-accelerated replacement for `PlanetaryPostProcessor.stack`'s CPU shift+combine passes —
/// but only for `.mean`. Mirrors `MetalFrameRenderer`'s own live-stack accumulation
/// (`accumulateMonoAligned`/its RGBA twin `accumulateRGBAAligned` here) rather than reinventing
/// it: each selected frame's bilinear-shifted samples stream straight into a running-sum
/// texture, one frame at a time, so — unlike the existing CPU mean path, which allocates every
/// shifted frame's full buffer before `combine` sums them — this never holds more than one
/// input frame resident in GPU memory. The final divide-by-count that turns the sum into a true
/// average happens on the CPU right after reading the accumulator back, exactly like
/// `MetalFrameRenderer`'s own `divisor` handling.
///
/// Deliberately `.mean`-only: a true per-pixel median needs every sample resident at once to
/// select from, which is the exact memory-blowup this streaming approach exists to avoid, and
/// Metal has no reduction primitive for "N-way per-pixel sort" the way it does for a running
/// sum. `PlanetaryPostProcessor.stack` keeps its existing (already multi-core, already
/// reasonably fast) CPU `combine` for `.median` — this class is never asked for one.
///
/// `init?` fails — callers fall back to the CPU path — when there's no usable `MTLDevice`/Metal
/// library/pipeline, e.g. a sandboxed CI or headless test runner, same as
/// `PlanetaryGPULuminanceConverter`/`PlanetaryGPURegistrar`.
/// `@unchecked Sendable`: the mutable texture cache is only ever touched from whichever single
/// background thread `PlanetaryPostProcessor.stack` runs its (already strictly serial, one frame
/// at a time) GPU mean path on. Deliberately synchronous per frame (`waitUntilCompleted()`, not
/// a completion handler/async pipeline) for the same reason every other GPU wrapper in this
/// pipeline is: this codebase already hit a real thread-pool-exhaustion deadlock once from
/// pipelining GPU work against a blocking CPU wait elsewhere in this exact stage (see git
/// history around `PlanetaryPostProcessor.combine`).
final class PlanetaryGPUStacker: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let accumulatePipelineState: MTLComputePipelineState
    private let clearPipelineState: MTLComputePipelineState
    /// `PlanetaryPostProcessor.gpuStacker` is one `static let` shared across every burst/call
    /// site — nothing stops two different bursts, or two Swift Testing tests, from calling
    /// `meanStack` concurrently on two different threads. Without this, that's a real race on
    /// `sourceTexture`/`accumulatorTexture` (traced, via an intermittent full-suite-only test
    /// failure, to exactly this): one call's `ensureTextures`/`clearAccumulator`/upload/dispatch
    /// sequence interleaving with another's mid-flight, corrupting both results. `meanStack`
    /// holds this for its entire body, so a second concurrent call simply blocks until the first
    /// finishes instead.
    private let lock = NSLock()

    private var sourceTexture: MTLTexture?
    private var accumulatorTexture: MTLTexture?
    private var textureWidth = 0
    private var textureHeight = 0

    private static let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let accumulateFunction = library.makeFunction(name: "accumulateRGBAAligned"),
              let clearFunction = library.makeFunction(name: "clearMono"),
              let accumulatePipelineState = try? device.makeComputePipelineState(function: accumulateFunction),
              let clearPipelineState = try? device.makeComputePipelineState(function: clearFunction)
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.accumulatePipelineState = accumulatePipelineState
        self.clearPipelineState = clearPipelineState
    }

    /// Streams `buffers` (each interleaved, `channels`-per-pixel, already debayered/normalized —
    /// `PlanetaryPostProcessor.normalizedRGB`'s own output shape) through shift+accumulate one at
    /// a time, then divides by `buffers.count` and returns the result in that same interleaved
    /// shape. `shifts[i]` is `buffers[i]`'s own `(dx, dy)`, matching `bilinearShift`'s sign
    /// convention (`output[x, y] = source[x + dx, y + dy]`). `nil` on any GPU failure or if
    /// `buffers`/`shifts` mismatch — callers fall back to the existing CPU path.
    func meanStack(
        _ buffers: [[Float]], shifts: [SIMD2<Float>], width: Int, height: Int, channels: Int,
        isCancelled: () -> Bool, progress: ((Float) -> Void)? = nil
    ) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffers.isEmpty, buffers.count == shifts.count, channels == 1 || channels == 3,
              width > 0, height > 0
        else { return nil }
        ensureTextures(width: width, height: height)
        guard let sourceTexture, let accumulatorTexture else { return nil }
        guard clearAccumulator(accumulatorTexture, width: width, height: height) else { return nil }

        for i in buffers.indices {
            if isCancelled() { return nil }
            guard uploadRGBA(buffers[i], channels: channels, into: sourceTexture, width: width, height: height)
            else { return nil }
            var shift = shifts[i]
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder()
            else { return nil }
            encoder.setComputePipelineState(accumulatePipelineState)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(accumulatorTexture, index: 1)
            encoder.setBytes(&shift, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            let threadgroups = Self.threadgroups(width: width, height: height)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: Self.threadsPerGroup)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.error == nil else { return nil }
            progress?(Float(i + 1) / Float(buffers.count))
        }

        return readBackAveraged(accumulatorTexture, channels: channels, width: width, height: height, divisor: Float(buffers.count))
    }

    private func ensureTextures(width: Int, height: Int) {
        guard width != textureWidth || height != textureHeight
            || sourceTexture == nil || accumulatorTexture == nil
        else { return }
        textureWidth = width
        textureHeight = height
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        sourceDescriptor.usage = [.shaderRead]
        sourceTexture = device.makeTexture(descriptor: sourceDescriptor)

        let accumulatorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        accumulatorDescriptor.usage = [.shaderRead, .shaderWrite]
        accumulatorTexture = device.makeTexture(descriptor: accumulatorDescriptor)
    }

    private func clearAccumulator(_ texture: MTLTexture, width: Int, height: Int) -> Bool {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return false }
        encoder.setComputePipelineState(clearPipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.dispatchThreadgroups(Self.threadgroups(width: width, height: height), threadsPerThreadgroup: Self.threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.error == nil
    }

    /// Pads `values` (interleaved, `channels`-per-pixel) out to RGBA (mono: `.r` only, unused
    /// channels 0; RGB: `.rgb`, `.a` unused) and uploads it into `texture`.
    private func uploadRGBA(_ values: [Float], channels: Int, into texture: MTLTexture, width: Int, height: Int) -> Bool {
        guard values.count == width * height * channels else { return false }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeBufferPointer { src in
            rgba.withUnsafeMutableBufferPointer { dst in
                for pixel in 0..<(width * height) {
                    for c in 0..<channels {
                        dst[pixel * 4 + c] = src[pixel * channels + c]
                    }
                }
            }
        }
        rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: base, bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }
        return true
    }

    private func readBackAveraged(_ texture: MTLTexture, channels: Int, width: Int, height: Int, divisor: Float) -> [Float]? {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(
                base, bytesPerRow: width * 4 * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }
        var output = [Float](repeating: 0, count: width * height * channels)
        rgba.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                for pixel in 0..<(width * height) {
                    for c in 0..<channels {
                        dst[pixel * channels + c] = src[pixel * 4 + c] / divisor
                    }
                }
            }
        }
        return output
    }

    private static func threadgroups(width: Int, height: Int) -> MTLSize {
        MTLSize(
            width: (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )
    }
}
