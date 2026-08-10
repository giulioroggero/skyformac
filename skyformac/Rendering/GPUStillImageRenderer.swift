import CoreGraphics
import Metal

/// GPU-accelerated equivalent of `CGImageRenderer.makeDisplayImage(...)` — the same plain
/// debayer+stretch (no denoise, wavelet-sharpen, live-stacking, or temporal accumulation), just
/// executed with the same Metal compute kernels `MetalFrameRenderer` uses for the live preview
/// (`stretchMono`/`stretchRGB24`/`debayerAndStretch` in `Shaders.metal`), instead of `Debayer`'s
/// CPU bilinear demosaic plus a per-pixel Swift LUT loop.
///
/// Exists specifically to feed Vision (`CameraManager.scheduleFocusAssistIfNeeded`/
/// `scheduleStreakDetectionIfNeeded`) a `CGImage` without spending CPU on producing it — see
/// `docs/design-notes.md` for why that CPU render, even off `@MainActor`, was still worth
/// replacing. A separate, independent Metal pipeline from the one `MetalPreviewView` uses for
/// live display: processing a frame here can never interfere with that pipeline's own state
/// (live-stack accumulation, temporal denoise), none of which this needs anyway.
///
/// An `actor` rather than a plain class specifically because `CameraManager` shares one instance
/// between two independent background tasks (focus assist, streak detection) that can run
/// concurrently — without serialized access, two calls racing on the same mutable
/// `sourceTexture`/`outputTexture`/`rgbSourceBuffer` would be a real data race, not just a
/// resource-contention slowdown.
actor GPUStillImageRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let stretchPipeline: MTLComputePipelineState
    private let stretchRGB24Pipeline: MTLComputePipelineState
    private let debayerPipeline: MTLComputePipelineState

    private var sourceTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var sourcePixelFormat: MTLPixelFormat = .r8Unorm
    private var rgbSourceBuffer: MTLBuffer?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let stretchFn = library.makeFunction(name: "stretchMono"),
              let stretchRGB24Fn = library.makeFunction(name: "stretchRGB24"),
              let debayerFn = library.makeFunction(name: "debayerAndStretch")
        else { return nil }

        self.device = device
        self.commandQueue = queue
        do {
            self.stretchPipeline = try device.makeComputePipelineState(function: stretchFn)
            self.stretchRGB24Pipeline = try device.makeComputePipelineState(function: stretchRGB24Fn)
            self.debayerPipeline = try device.makeComputePipelineState(function: debayerFn)
        } catch {
            return nil
        }
    }

    /// `nil` for `ASI_IMG_Y8` — that straight-to-Metal path isn't wired up here either, the same
    /// gap `MetalFrameRenderer.process`'s own doc comment already documents for the live path.
    /// Callers should fall back to `CGImageRenderer.makeDisplayImage` in that case.
    func makeDisplayImage(
        from frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN, stretch: DisplayStretch
    ) -> CGImage? {
        switch frame.imageType {
        case ASI_IMG_RGB24:
            return renderRGB24(frame: frame, stretch: stretch)
        case ASI_IMG_RAW8, ASI_IMG_RAW16:
            return renderMono(frame: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: stretch)
        default:
            return nil
        }
    }

    private func ensureMonoTextures(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        guard width != sourceWidth || height != sourceHeight || pixelFormat != sourcePixelFormat else { return }
        sourceWidth = width
        sourceHeight = height
        sourcePixelFormat = pixelFormat
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        sourceDescriptor.usage = [.shaderRead]
        sourceTexture = device.makeTexture(descriptor: sourceDescriptor)
        ensureOutputTexture(width: width, height: height)
    }

    private func ensureOutputTexture(width: Int, height: Int) {
        guard outputTexture == nil || outputTexture?.width != width || outputTexture?.height != height else { return }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        outputTexture = device.makeTexture(descriptor: outputDescriptor)
    }

    private func ensureRGBSourceBuffer(byteCount: Int) {
        guard rgbSourceBuffer == nil || rgbSourceBuffer!.length < byteCount else { return }
        rgbSourceBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
    }

    private func renderMono(
        frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN, stretch: DisplayStretch
    ) -> CGImage? {
        let pixelFormat: MTLPixelFormat = frame.imageType == ASI_IMG_RAW16 ? .r16Unorm : .r8Unorm
        let bytesPerPixel = frame.imageType == ASI_IMG_RAW16 ? 2 : 1
        ensureMonoTextures(width: frame.width, height: frame.height, pixelFormat: pixelFormat)
        guard let sourceTexture, let outputTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        frame.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            sourceTexture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0, withBytes: base, bytesPerRow: frame.width * bytesPerPixel
            )
        }

        var stretchParams = (Float(stretch.blackPoint), Float(stretch.whitePoint), Float(1.0))
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(width: (frame.width + 15) / 16, height: (frame.height + 15) / 16, depth: 1)

        if isColorCamera {
            var pattern = UInt32(bayerPattern.rawValue)
            encoder.setComputePipelineState(debayerPipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBytes(&stretchParams, length: MemoryLayout.size(ofValue: stretchParams), index: 0)
            encoder.setBytes(&pattern, length: MemoryLayout.size(ofValue: pattern), index: 1)
        } else {
            encoder.setComputePipelineState(stretchPipeline)
            encoder.setTexture(sourceTexture, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBytes(&stretchParams, length: MemoryLayout.size(ofValue: stretchParams), index: 0)
        }
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return cgImage(from: outputTexture, width: frame.width, height: frame.height)
    }

    private func renderRGB24(frame: CapturedFrame, stretch: DisplayStretch) -> CGImage? {
        ensureOutputTexture(width: frame.width, height: frame.height)
        let byteCount = frame.width * frame.height * 3
        ensureRGBSourceBuffer(byteCount: byteCount)
        guard let outputTexture, let rgbSourceBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        frame.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(rgbSourceBuffer.contents(), base, min(byteCount, frame.data.count))
        }

        var width = UInt32(frame.width)
        var stretchParams = (Float(stretch.blackPoint), Float(stretch.whitePoint), Float(1.0))
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(width: (frame.width + 15) / 16, height: (frame.height + 15) / 16, depth: 1)

        encoder.setComputePipelineState(stretchRGB24Pipeline)
        encoder.setBuffer(rgbSourceBuffer, offset: 0, index: 0)
        encoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&stretchParams, length: MemoryLayout.size(ofValue: stretchParams), index: 2)
        encoder.setTexture(outputTexture, index: 0)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return cgImage(from: outputTexture, width: frame.width, height: frame.height)
    }

    /// Reads `texture` (`rgba8Unorm`) back to CPU and wraps it in a `CGImage` — alpha is always
    /// 1.0 from every kernel that writes it, so `.noneSkipLast` (a channel present in memory but
    /// deliberately ignored) is the correct bitmap info, not premultiplied/straight alpha.
    private func cgImage(from texture: MTLTexture, width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
