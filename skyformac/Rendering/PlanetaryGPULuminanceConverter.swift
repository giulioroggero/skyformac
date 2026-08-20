import Metal

/// GPU-accelerated replacement for the debayer step inside `PlanetaryPostProcessor.luminance
/// (of:isColorCamera:bayerPattern:)` — `Debayer.swift`'s CPU bilinear demosaic is a branch-heavy
/// scalar loop over every pixel, run once per frame for a planetary burst that can be hundreds
/// of multi-megapixel frames; profiling that pipeline showed it as the single biggest per-frame
/// cost by far, well beyond the (already Accelerate-vectorized) normalize/luma-combine steps.
/// This runs the exact same bilinear demosaic + RGB→luma combination as a Metal compute kernel
/// (`debayerToLuma` in `Shaders.metal`) instead, one dispatch per frame on a single command
/// queue, and reads the result straight back as the plain `[Float]` luma array
/// `PlanetaryPostProcessor` already works with everywhere else in the pipeline — a drop-in swap
/// at that one call site, nothing downstream needs to know the difference.
///
/// `init?` fails — callers fall back to the CPU path — when there's no usable `MTLDevice`/Metal
/// library/pipeline, e.g. a sandboxed CI or headless test runner.
/// `@unchecked Sendable`: the mutable texture cache is only ever touched from whichever single
/// background thread `PlanetaryPostProcessor`'s registration loop runs on for a given burst — that
/// loop processes frames strictly one at a time, never concurrently, so there's no actual shared
/// mutable access to race on despite the compiler having no way to see that.
final class PlanetaryGPULuminanceConverter: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let lumaPipelineState: MTLComputePipelineState
    private let rgbPipelineState: MTLComputePipelineState

    private var sourceTexture: MTLTexture?
    private var lumaDestinationTexture: MTLTexture?
    private var rgbDestinationTexture: MTLTexture?
    private var textureWidth = 0
    private var textureHeight = 0
    private var texturePixelFormat: MTLPixelFormat = .r8Unorm

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let lumaFunction = library.makeFunction(name: "debayerToLuma"),
              let rgbFunction = library.makeFunction(name: "debayerToRGB"),
              let lumaPipelineState = try? device.makeComputePipelineState(function: lumaFunction),
              let rgbPipelineState = try? device.makeComputePipelineState(function: rgbFunction)
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.lumaPipelineState = lumaPipelineState
        self.rgbPipelineState = rgbPipelineState
    }

    /// Debayers `frame` (must be a color camera's RAW8/RAW16 Bayer mosaic — `nil` for anything
    /// else) and returns its full-resolution luma, normalized `[0, 1]`, row-major — the exact
    /// same shape `PlanetaryPostProcessor.luminance(of:...)`'s CPU path returns.
    func luminance(of frame: CapturedFrame, bayerPattern: ASI_BAYER_PATTERN) -> [Float]? {
        guard let (sourceTexture, _) = uploadedSourceTexture(for: frame) else { return nil }
        ensureLumaDestinationTexture(width: frame.width, height: frame.height)
        guard let lumaDestinationTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        dispatch(
            encoder: encoder, commandBuffer: commandBuffer, pipelineState: lumaPipelineState,
            source: sourceTexture, destination: lumaDestinationTexture, bayerPattern: bayerPattern,
            width: frame.width, height: frame.height
        )
        guard commandBuffer.error == nil else { return nil }

        var output = [Float](repeating: 0, count: frame.width * frame.height)
        output.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            lumaDestinationTexture.getBytes(
                base, bytesPerRow: frame.width * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0
            )
        }
        return output
    }

    /// Debayers `frame` into full-resolution, normalized `[0, 1]` interleaved RGB (3 floats per
    /// pixel) — the GPU counterpart to `Debayer.debayerRAW8/16` + `normalized`/`normalized16`'s
    /// combined CPU path, feeding `PlanetaryPostProcessor.stack`'s per-selected-frame debayer
    /// (previously the one part of the pipeline still entirely CPU-bound after `luminance(of:)`
    /// above sped up registration — the reason that stage burned CPU with the GPU idle).
    func rgb(of frame: CapturedFrame, bayerPattern: ASI_BAYER_PATTERN) -> [Float]? {
        guard let (sourceTexture, _) = uploadedSourceTexture(for: frame) else { return nil }
        ensureRGBDestinationTexture(width: frame.width, height: frame.height)
        guard let rgbDestinationTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        dispatch(
            encoder: encoder, commandBuffer: commandBuffer, pipelineState: rgbPipelineState,
            source: sourceTexture, destination: rgbDestinationTexture, bayerPattern: bayerPattern,
            width: frame.width, height: frame.height
        )
        guard commandBuffer.error == nil else { return nil }

        // The texture is RGBA (Metal has no plain RGB float format); read back interleaved RGBA
        // then drop the alpha column to match `normalizedRGB`'s 3-floats-per-pixel shape.
        let pixelCount = frame.width * frame.height
        var rgba = [Float](repeating: 0, count: pixelCount * 4)
        rgba.withUnsafeMutableBytes { dst in
            guard let base = dst.baseAddress else { return }
            rgbDestinationTexture.getBytes(
                base, bytesPerRow: frame.width * 4 * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0
            )
        }
        var rgb = [Float](repeating: 0, count: pixelCount * 3)
        for pixel in 0..<pixelCount {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return rgb
    }

    /// Uploads `frame`'s raw bytes into the (possibly-cached) source texture — shared prep for
    /// both `luminance(of:)` and `rgb(of:)`.
    private func uploadedSourceTexture(for frame: CapturedFrame) -> (texture: MTLTexture, pixelFormat: MTLPixelFormat)? {
        let pixelFormat: MTLPixelFormat
        let bytesPerPixel: Int
        switch frame.imageType {
        case ASI_IMG_RAW8: pixelFormat = .r8Unorm; bytesPerPixel = 1
        case ASI_IMG_RAW16: pixelFormat = .r16Unorm; bytesPerPixel = 2
        default: return nil
        }
        guard frame.width > 0, frame.height > 0, frame.data.count >= frame.width * frame.height * bytesPerPixel else { return nil }

        ensureSourceTexture(width: frame.width, height: frame.height, pixelFormat: pixelFormat)
        guard let sourceTexture else { return nil }

        frame.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            sourceTexture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                withBytes: base, bytesPerRow: frame.width * bytesPerPixel
            )
        }
        return (sourceTexture, pixelFormat)
    }

    private func dispatch(
        encoder: MTLComputeCommandEncoder, commandBuffer: MTLCommandBuffer, pipelineState: MTLComputePipelineState,
        source: MTLTexture, destination: MTLTexture, bayerPattern: ASI_BAYER_PATTERN, width: Int, height: Int
    ) {
        var pattern = UInt32(bayerPattern.rawValue)
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)
        encoder.setBytes(&pattern, length: MemoryLayout<UInt32>.size, index: 0)
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (height + threadsPerGroup.height - 1) / threadsPerGroup.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func ensureSourceTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        guard width != textureWidth || height != textureHeight || pixelFormat != texturePixelFormat else { return }
        textureWidth = width
        textureHeight = height
        texturePixelFormat = pixelFormat
        lumaDestinationTexture = nil
        rgbDestinationTexture = nil

        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        sourceDescriptor.usage = [.shaderRead]
        sourceTexture = device.makeTexture(descriptor: sourceDescriptor)
    }

    private func ensureLumaDestinationTexture(width: Int, height: Int) {
        guard lumaDestinationTexture == nil else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        lumaDestinationTexture = device.makeTexture(descriptor: descriptor)
    }

    private func ensureRGBDestinationTexture(width: Int, height: Int) {
        guard rgbDestinationTexture == nil else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderWrite, .shaderRead]
        rgbDestinationTexture = device.makeTexture(descriptor: descriptor)
    }
}
