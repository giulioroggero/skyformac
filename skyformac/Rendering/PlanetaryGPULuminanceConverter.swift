import Accelerate
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
/// `@unchecked Sendable`: this is one `static let` instance shared across every call site (see
/// `PlanetaryPostProcessor.gpuLuminanceConverter`), and while any *one* burst's own
/// registration/stacking loop only ever calls it from a single thread at a time, nothing stops
/// two different bursts — or, as actually observed, two Swift Testing tests running in
/// parallel — from calling it concurrently from two different threads. `lock` serializes those:
/// each `luminance(of:)`/`rgb(of:)` call holds it for its whole texture-upload → dispatch →
/// readback sequence, so a second concurrent call blocks instead of corrupting the first's
/// cached `sourceTexture`/`lumaDestinationTexture`/`rgbDestinationTexture` state — the actual bug
/// (traced to this same shared-instance pattern in the sibling `PlanetaryGPUStacker`) that
/// intermittently made `PlanetaryPostProcessorTests` fail only when run as part of the full
/// suite, never in isolation.
final class PlanetaryGPULuminanceConverter: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let lumaPipelineState: MTLComputePipelineState
    private let rgbPipelineState: MTLComputePipelineState
    private let rgbToLumaPipelineState: MTLComputePipelineState
    private let lock = NSLock()

    private var sourceTexture: MTLTexture?
    private var lumaDestinationTexture: MTLTexture?
    private var rgbDestinationTexture: MTLTexture?
    private var textureWidth = 0
    private var textureHeight = 0
    private var texturePixelFormat: MTLPixelFormat = .r8Unorm

    /// Separate from `sourceTexture` above (deliberately not sharing its cache/pixel-format
    /// bookkeeping) — an already-RGB video frame uploads as `.rgba8Unorm`, a genuinely different
    /// shape from the single-channel Bayer-mosaic source `luminance(of:)`/`rgb(of:)` upload, and
    /// the two paths are never interleaved within one burst (a burst is either all-Bayer or
    /// all-already-RGB), so there's no real cost to keeping their caches independent instead of
    /// generalizing `ensureSourceTexture` to cover both.
    private var rgbaSourceTexture: MTLTexture?
    private var rgbaTextureWidth = 0
    private var rgbaTextureHeight = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let lumaFunction = library.makeFunction(name: "debayerToLuma"),
              let rgbFunction = library.makeFunction(name: "debayerToRGB"),
              let rgbToLumaFunction = library.makeFunction(name: "rgbToLuma"),
              let lumaPipelineState = try? device.makeComputePipelineState(function: lumaFunction),
              let rgbPipelineState = try? device.makeComputePipelineState(function: rgbFunction),
              let rgbToLumaPipelineState = try? device.makeComputePipelineState(function: rgbToLumaFunction)
        else { return nil }
        self.device = device
        self.commandQueue = queue
        self.lumaPipelineState = lumaPipelineState
        self.rgbPipelineState = rgbPipelineState
        self.rgbToLumaPipelineState = rgbToLumaPipelineState
    }

    /// Debayers `frame` (must be a color camera's RAW8/RAW16 Bayer mosaic — `nil` for anything
    /// else) and returns its full-resolution luma, normalized `[0, 1]`, row-major — the exact
    /// same shape `PlanetaryPostProcessor.luminance(of:...)`'s CPU path returns.
    func luminance(of frame: CapturedFrame, bayerPattern: ASI_BAYER_PATTERN) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
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

    /// Same idea as `luminance(of:bayerPattern:)`, for an already-RGB (not Bayer-mosaic) frame —
    /// an imported ordinary video's own decoded frame (`ASI_IMG_RGB24`), no demosaic needed at
    /// all. Metal has no plain 3-byte-per-pixel texture format, so the RGB24 source is padded to
    /// RGBA8 first via `vImage` (vectorized, the same technique `VideoFrameReader`'s own
    /// BGRA→RGB24 conversion already uses) before upload — still meaningfully cheaper overall than
    /// leaving the whole R/G/B→luma combine on the CPU, since this replaces that step for every
    /// frame across the whole registration/stacking pipeline, not just once.
    func luminanceOfRGB24(_ frame: CapturedFrame) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        guard frame.imageType == ASI_IMG_RGB24, frame.width > 0, frame.height > 0,
              frame.data.count >= frame.width * frame.height * 3
        else { return nil }

        var rgba = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        let conversionError = frame.data.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> vImage_Error in
            rgba.withUnsafeMutableBytes { destRaw in
                var srcBuffer = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcRaw.baseAddress),
                    height: vImagePixelCount(frame.height), width: vImagePixelCount(frame.width),
                    rowBytes: frame.width * 3
                )
                var destBuffer = vImage_Buffer(
                    data: destRaw.baseAddress, height: vImagePixelCount(frame.height),
                    width: vImagePixelCount(frame.width), rowBytes: frame.width * 4
                )
                return vImageConvert_RGB888toRGBA8888(&srcBuffer, nil, 255, &destBuffer, false, vImage_Flags(kvImageNoFlags))
            }
        }
        guard conversionError == kvImageNoError else { return nil }

        ensureRGBASourceTexture(width: frame.width, height: frame.height)
        guard let rgbaSourceTexture else { return nil }
        rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            rgbaSourceTexture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height), mipmapLevel: 0,
                withBytes: base, bytesPerRow: frame.width * 4
            )
        }

        ensureLumaDestinationTexture(width: frame.width, height: frame.height)
        guard let lumaDestinationTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(rgbToLumaPipelineState)
        encoder.setTexture(rgbaSourceTexture, index: 0)
        encoder.setTexture(lumaDestinationTexture, index: 1)
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (frame.width + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: (frame.height + threadsPerGroup.height - 1) / threadsPerGroup.height, depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
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

    private func ensureRGBASourceTexture(width: Int, height: Int) {
        guard width != rgbaTextureWidth || height != rgbaTextureHeight else { return }
        rgbaTextureWidth = width
        rgbaTextureHeight = height
        // Same invalidation `ensureSourceTexture` does on its own size change below — the shared
        // `lumaDestinationTexture` this path also writes to must be recreated at the new
        // dimensions too, not silently reused at whatever size a previous call (Bayer or RGB24)
        // happened to leave it at.
        lumaDestinationTexture = nil
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        rgbaSourceTexture = device.makeTexture(descriptor: descriptor)
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
