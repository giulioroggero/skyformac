import Metal
import MetalKit
import SwiftUI

/// GPU upgrade pass: uploads a `CapturedFrame` straight into an `MTLTexture` and does the
/// debayer + black/white stretch on the GPU (`Shaders.metal`), instead of the CPU path in
/// `CGImageRenderer`/`Debayer`. Avoids the CPU `CGImage` round-trip on the live-preview path
/// per spec 3.4's "leverage GPUs" direction.
final class MetalFrameRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let stretchPipeline: MTLComputePipelineState
    private let stretchRGB24Pipeline: MTLComputePipelineState
    private let histogramReduceRGB24Pipeline: MTLComputePipelineState
    private let debayerPipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    private let histogramPipeline: MTLComputePipelineState
    private let accumulatePipeline: MTLComputePipelineState
    private let clearPipeline: MTLComputePipelineState
    private let denoisePipeline: MTLComputePipelineState
    private let waveletBlurPipeline: MTLComputePipelineState
    private let waveletCombinePipeline: MTLComputePipelineState
    private let histogramBuffer: MTLBuffer

    private var sourceTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    // Scratch textures for the optional denoise/wavelet-sharpen stages, same dimensions/format
    // as `sourceTexture` — allocated lazily only when those features are actually enabled.
    private var denoiseTexture: MTLTexture?
    private var waveletLayer0Texture: MTLTexture?
    private var waveletLayer1Texture: MTLTexture?
    private var waveletOutputTexture: MTLTexture?
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var sourcePixelFormat: MTLPixelFormat = .r8Unorm
    /// Raw packed-RGB24 upload buffer for `processRGB24` — a buffer rather than a texture, since
    /// RGB24 (3 bytes/pixel) isn't a valid Metal texture pixel format.
    private var rgbSourceBuffer: MTLBuffer?

    /// GPU-side live-stack running-sum texture (`r32Float`) and its frame count. Independent of
    /// `LiveStacker` (the CPU accumulator used by the `CGImage` render path) — when the Metal
    /// preview is active, stacking math itself runs on the GPU end to end, not just the display.
    private var accumulationTexture: MTLTexture?
    private var accumulatedWidth = 0
    private var accumulatedHeight = 0
    private var accumulatedFrameCount = 0

    /// Set by the owning view whenever a new frame should be (re)processed.
    var pendingUpdate: (
        frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN,
        stretch: DisplayStretch, isLiveStacking: Bool,
        isDenoisingEnabled: Bool, isWaveletSharpeningEnabled: Bool, sharpenAmount: Float
    )?

    /// Fired (off the main thread — hop back before touching UI state) with a fresh 256-bucket
    /// histogram every time a frame finishes GPU processing. Best-effort: if frames arrive
    /// faster than the GPU completes a pass, a rare stale/overwritten read is possible, which is
    /// an acceptable trade-off for a non-critical live display feature.
    var onHistogramUpdate: (@Sendable ([Int]) -> Void)?

    /// Fired with the GPU accumulator's running frame count whenever live stacking processes a
    /// frame, so `CameraManager` can surface it in the UI the same way `LiveStacker.frameCount` does.
    var onLiveStackFrameCountUpdate: (@Sendable (Int) -> Void)?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let stretchFn = library.makeFunction(name: "stretchMono"),
              let stretchRGB24Fn = library.makeFunction(name: "stretchRGB24"),
              let histogramRGB24Fn = library.makeFunction(name: "histogramReduceRGB24"),
              let debayerFn = library.makeFunction(name: "debayerAndStretch"),
              let histogramFn = library.makeFunction(name: "histogramReduce"),
              let accumulateFn = library.makeFunction(name: "accumulateMono"),
              let clearFn = library.makeFunction(name: "clearMono"),
              let denoiseFn = library.makeFunction(name: "bilateralDenoise"),
              let waveletBlurFn = library.makeFunction(name: "waveletBlur"),
              let waveletCombineFn = library.makeFunction(name: "waveletCombine"),
              let vertexFn = library.makeFunction(name: "fullscreenTriangleVertex"),
              let fragmentFn = library.makeFunction(name: "blitFragment"),
              let histogramBuffer = device.makeBuffer(
                length: 256 * MemoryLayout<UInt32>.size, options: .storageModeShared
              )
        else { return nil }

        self.device = device
        self.commandQueue = queue
        self.histogramBuffer = histogramBuffer

        do {
            self.stretchPipeline = try device.makeComputePipelineState(function: stretchFn)
            self.stretchRGB24Pipeline = try device.makeComputePipelineState(function: stretchRGB24Fn)
            self.histogramReduceRGB24Pipeline = try device.makeComputePipelineState(function: histogramRGB24Fn)
            self.debayerPipeline = try device.makeComputePipelineState(function: debayerFn)
            self.histogramPipeline = try device.makeComputePipelineState(function: histogramFn)
            self.accumulatePipeline = try device.makeComputePipelineState(function: accumulateFn)
            self.clearPipeline = try device.makeComputePipelineState(function: clearFn)
            self.denoisePipeline = try device.makeComputePipelineState(function: denoiseFn)
            self.waveletBlurPipeline = try device.makeComputePipelineState(function: waveletBlurFn)
            self.waveletCombinePipeline = try device.makeComputePipelineState(function: waveletCombineFn)

            let renderDescriptor = MTLRenderPipelineDescriptor()
            renderDescriptor.vertexFunction = vertexFn
            renderDescriptor.fragmentFunction = fragmentFn
            renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.renderPipeline = try device.makeRenderPipelineState(descriptor: renderDescriptor)
        } catch {
            return nil
        }
        super.init()
    }

    // MARK: - Frame upload + GPU processing

    private func ensureTextures(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
        guard width != sourceWidth || height != sourceHeight || pixelFormat != sourcePixelFormat else { return }
        sourceWidth = width
        sourceHeight = height
        sourcePixelFormat = pixelFormat

        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
        )
        sourceDescriptor.usage = [.shaderRead]
        sourceTexture = device.makeTexture(descriptor: sourceDescriptor)

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        outputDescriptor.usage = [.shaderWrite, .shaderRead]
        outputTexture = device.makeTexture(descriptor: outputDescriptor)

        // Denoise/wavelet scratch textures share the source's mono format/dimensions.
        func makeScratch() -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: descriptor)
        }
        denoiseTexture = makeScratch()
        waveletLayer0Texture = makeScratch()
        waveletLayer1Texture = makeScratch()
        waveletOutputTexture = makeScratch()
    }

    /// Just the display-sized `outputTexture`, for `processRGB24` — RGB24 has no mono
    /// `sourceTexture`/scratch textures to keep in sync (see `ensureTextures`), so this is
    /// deliberately narrower than that.
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

    /// Stretch + display (no debayer) for webcam/iPhone RGB24 frames, entirely on the GPU —
    /// see `stretchRGB24`'s doc comment for why this reads from a buffer, not a texture.
    private func processRGB24(frame: CapturedFrame, stretch: DisplayStretch) {
        ensureOutputTexture(width: frame.width, height: frame.height)
        let byteCount = frame.width * frame.height * 3
        ensureRGBSourceBuffer(byteCount: byteCount)
        guard let outputTexture, let rgbSourceBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        frame.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(rgbSourceBuffer.contents(), base, min(byteCount, frame.data.count))
        }

        var width = UInt32(frame.width)
        var height = UInt32(frame.height)
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

        if onHistogramUpdate != nil, let histogramEncoder = commandBuffer.makeComputeCommandEncoder() {
            memset(histogramBuffer.contents(), 0, histogramBuffer.length)
            histogramEncoder.setComputePipelineState(histogramReduceRGB24Pipeline)
            histogramEncoder.setBuffer(rgbSourceBuffer, offset: 0, index: 0)
            histogramEncoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)
            histogramEncoder.setBytes(&height, length: MemoryLayout<UInt32>.size, index: 2)
            histogramEncoder.setBuffer(histogramBuffer, offset: 0, index: 3)
            histogramEncoder.setThreadgroupMemoryLength(256 * MemoryLayout<UInt32>.size, index: 0)
            histogramEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            histogramEncoder.endEncoding()

            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                let counts = self.histogramBuffer.contents().bindMemory(to: UInt32.self, capacity: 256)
                let snapshot = (0..<256).map { Int(counts[$0]) }
                self.onHistogramUpdate?(snapshot)
            }
        }

        commandBuffer.commit()
    }

    /// Resets the GPU live-stack accumulator (new session, format change, or user-requested reset).
    func resetLiveStack() {
        accumulatedFrameCount = 0
        guard let accumulationTexture, let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        dispatch(clearPipeline, encoder: encoder, texture0: accumulationTexture, width: accumulatedWidth, height: accumulatedHeight)
        encoder.endEncoding()
        commandBuffer.commit()
    }

    private func ensureAccumulationTexture(width: Int, height: Int) {
        guard width != accumulatedWidth || height != accumulatedHeight || accumulationTexture == nil else { return }
        accumulatedWidth = width
        accumulatedHeight = height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        accumulationTexture = device.makeTexture(descriptor: descriptor)
        resetLiveStack()
    }

    private func dispatch(
        _ pipeline: MTLComputePipelineState,
        encoder: MTLComputeCommandEncoder,
        texture0: MTLTexture,
        texture1: MTLTexture? = nil,
        width: Int,
        height: Int
    ) {
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture0, index: 0)
        if let texture1 { encoder.setTexture(texture1, index: 1) }
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
    }

    private func process(
        frame: CapturedFrame,
        isColorCamera: Bool,
        bayerPattern: ASI_BAYER_PATTERN,
        stretch: DisplayStretch,
        isLiveStacking: Bool,
        isDenoisingEnabled: Bool,
        isWaveletSharpeningEnabled: Bool,
        sharpenAmount: Float
    ) {
        if frame.imageType == ASI_IMG_RGB24 {
            // Webcam/iPhone frames: already color-processed by the device's own ISP, so no
            // debayering — just stretch and display. Denoise/wavelet-sharpen/live-stacking are
            // mono-only kernels today (see their textures' `r8Unorm`/`r16Unorm`/`r32Float`
            // formats) and aren't wired up for this path; the CPU (`CGImageRenderer`) path has
            // the same gap. Only affects webcam sources — ZWO cameras never produce RGB24.
            processRGB24(frame: frame, stretch: stretch)
            return
        }

        let pixelFormat: MTLPixelFormat = frame.imageType == ASI_IMG_RAW16 ? .r16Unorm : .r8Unorm
        let bytesPerPixel = frame.imageType == ASI_IMG_RAW16 ? 2 : 1
        guard frame.imageType == ASI_IMG_RAW8 || frame.imageType == ASI_IMG_RAW16 else {
            // Y8 straight-to-Metal path isn't wired up yet; CGImageRenderer covers it.
            return
        }

        ensureTextures(width: frame.width, height: frame.height, pixelFormat: pixelFormat)
        guard let sourceTexture, let outputTexture,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        frame.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            sourceTexture.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: frame.width * bytesPerPixel
            )
        }

        // Denoise and wavelet-sharpen operate on the single incoming (normalized 0...1) frame,
        // strictly *before* it's optionally folded into the live-stack running sum — applying
        // them to the un-normalized accumulator instead would need every kernel to know about
        // `divisor`, and `waveletCombine`'s `saturate()` would silently clip a multi-frame sum
        // to a single frame's range. Pre-processing each frame before stacking sidesteps that
        // entirely, and is arguably the more useful order anyway (stack already-denoised frames).
        var workingTexture = sourceTexture

        if isDenoisingEnabled, let denoiseTexture {
            var spatialSigma: Float = 1.5
            var rangeSigma: Float = 0.08
            encoder.setComputePipelineState(denoisePipeline)
            encoder.setTexture(workingTexture, index: 0)
            encoder.setTexture(denoiseTexture, index: 1)
            encoder.setBytes(&spatialSigma, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&rangeSigma, length: MemoryLayout<Float>.size, index: 1)
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(width: (frame.width + 15) / 16, height: (frame.height + 15) / 16, depth: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            workingTexture = denoiseTexture
        }

        if isWaveletSharpeningEnabled,
           let layer0 = waveletLayer0Texture, let layer1 = waveletLayer1Texture, let waveletOutput = waveletOutputTexture {
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(width: (frame.width + 15) / 16, height: (frame.height + 15) / 16, depth: 1)

            var spacing0: Int32 = 1
            encoder.setComputePipelineState(waveletBlurPipeline)
            encoder.setTexture(workingTexture, index: 0)
            encoder.setTexture(layer0, index: 1)
            encoder.setBytes(&spacing0, length: MemoryLayout<Int32>.size, index: 0)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)

            var spacing1: Int32 = 2
            encoder.setComputePipelineState(waveletBlurPipeline)
            encoder.setTexture(layer0, index: 0)
            encoder.setTexture(layer1, index: 1)
            encoder.setBytes(&spacing1, length: MemoryLayout<Int32>.size, index: 0)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)

            var fineGain = sharpenAmount
            var midGain = sharpenAmount * 0.6
            encoder.setComputePipelineState(waveletCombinePipeline)
            encoder.setTexture(workingTexture, index: 0)
            encoder.setTexture(layer0, index: 1)
            encoder.setTexture(layer1, index: 2)
            encoder.setTexture(waveletOutput, index: 3)
            encoder.setBytes(&fineGain, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&midGain, length: MemoryLayout<Float>.size, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            workingTexture = waveletOutput
        }

        // The texture that the stretch/debayer/histogram passes actually read: the (optionally
        // pre-processed) frame, or (when live stacking) the running-sum accumulator, paired with
        // the divisor that turns a sum back into an average.
        var readSource = workingTexture
        var divisor: Float = 1.0

        if isLiveStacking {
            ensureAccumulationTexture(width: frame.width, height: frame.height)
            if let accumulationTexture {
                dispatch(accumulatePipeline, encoder: encoder, texture0: workingTexture, texture1: accumulationTexture,
                         width: frame.width, height: frame.height)
                accumulatedFrameCount += 1
                readSource = accumulationTexture
                divisor = Float(accumulatedFrameCount)
                onLiveStackFrameCountUpdate?(accumulatedFrameCount)
            }
        }

        var stretchParams = (Float(stretch.blackPoint), Float(stretch.whitePoint), divisor)
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (frame.width + 15) / 16,
            height: (frame.height + 15) / 16,
            depth: 1
        )

        if isColorCamera {
            var pattern = UInt32(bayerPattern.rawValue)
            encoder.setComputePipelineState(debayerPipeline)
            encoder.setTexture(readSource, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBytes(&stretchParams, length: MemoryLayout.size(ofValue: stretchParams), index: 0)
            encoder.setBytes(&pattern, length: MemoryLayout.size(ofValue: pattern), index: 1)
        } else {
            encoder.setComputePipelineState(stretchPipeline)
            encoder.setTexture(readSource, index: 0)
            encoder.setTexture(outputTexture, index: 1)
            encoder.setBytes(&stretchParams, length: MemoryLayout.size(ofValue: stretchParams), index: 0)
        }

        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        // Histogram is computed from the same (possibly-stacked) source, matching
        // `HistogramComputer`'s CPU semantics — the black/white sliders should move relative to
        // the same underlying distribution regardless of which renderer is active.
        if onHistogramUpdate != nil, let histogramEncoder = commandBuffer.makeComputeCommandEncoder() {
            memset(histogramBuffer.contents(), 0, histogramBuffer.length)
            var histogramDivisor = divisor
            histogramEncoder.setComputePipelineState(histogramPipeline)
            histogramEncoder.setTexture(readSource, index: 0)
            histogramEncoder.setBuffer(histogramBuffer, offset: 0, index: 0)
            histogramEncoder.setBytes(&histogramDivisor, length: MemoryLayout<Float>.size, index: 1)
            histogramEncoder.setThreadgroupMemoryLength(256 * MemoryLayout<UInt32>.size, index: 0)
            histogramEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            histogramEncoder.endEncoding()

            commandBuffer.addCompletedHandler { [weak self] _ in
                guard let self else { return }
                let counts = self.histogramBuffer.contents()
                    .bindMemory(to: UInt32.self, capacity: 256)
                let snapshot = (0..<256).map { Int(counts[$0]) }
                self.onHistogramUpdate?(snapshot)
            }
        }

        commandBuffer.commit()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if let update = pendingUpdate {
            pendingUpdate = nil
            process(
                frame: update.frame,
                isColorCamera: update.isColorCamera,
                bayerPattern: update.bayerPattern,
                stretch: update.stretch,
                isLiveStacking: update.isLiveStacking,
                isDenoisingEnabled: update.isDenoisingEnabled,
                isWaveletSharpeningEnabled: update.isWaveletSharpeningEnabled,
                sharpenAmount: update.sharpenAmount
            )
        }

        guard let outputTexture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(outputTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// SwiftUI host for `MetalFrameRenderer`. Feeds each new `CameraManager.currentFrame` straight
/// to the GPU pipeline, bypassing `CGImageRenderer`'s CPU debayer/stretch entirely.
struct MetalPreviewView: NSViewRepresentable {
    var cameraManager: CameraManager

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.colorPixelFormat = .bgra8Unorm
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        if let device = MTLCreateSystemDefaultDevice() {
            view.device = device
            let renderer = MetalFrameRenderer(device: device)
            renderer?.onHistogramUpdate = { [weak cameraManager] counts in
                Task { @MainActor in cameraManager?.gpuHistogramCounts = counts }
            }
            renderer?.onLiveStackFrameCountUpdate = { [weak cameraManager] count in
                Task { @MainActor in cameraManager?.gpuLiveStackFrameCount = count }
            }
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer else { return }

        if context.coordinator.lastSeenStackGeneration != cameraManager.liveStackGeneration {
            context.coordinator.lastSeenStackGeneration = cameraManager.liveStackGeneration
            renderer.resetLiveStack()
        }

        guard let camera = cameraManager.connectedCamera,
              let frame = cameraManager.currentFrame,
              context.coordinator.lastRenderedFrameID != cameraManager.frameID
        else { return }

        context.coordinator.lastRenderedFrameID = cameraManager.frameID
        renderer.pendingUpdate = (
            frame: frame,
            isColorCamera: camera.isColorCamera,
            bayerPattern: camera.bayerPattern,
            stretch: cameraManager.stretch,
            isLiveStacking: cameraManager.isLiveStackingEnabled,
            isDenoisingEnabled: cameraManager.isDenoisingEnabled,
            isWaveletSharpeningEnabled: cameraManager.isWaveletSharpeningEnabled,
            sharpenAmount: Float(cameraManager.waveletSharpenAmount)
        )
        nsView.setNeedsDisplay(nsView.bounds)
    }

    final class Coordinator {
        var renderer: MetalFrameRenderer?
        var lastRenderedFrameID: UInt64?
        var lastSeenStackGeneration = 0
    }
}
