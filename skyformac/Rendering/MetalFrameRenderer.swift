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
    private let temporalAccumulatorPipeline: MTLComputePipelineState
    private let arcsinhStretchPipeline: MTLComputePipelineState
    private let findBrightestPipeline: MTLComputePipelineState
    private let roiStatsPipeline: MTLComputePipelineState
    private let centroidPipeline: MTLComputePipelineState
    private let accumulateAlignedPipeline: MTLComputePipelineState
    /// RGB24 (webcam/iPhone) color analogs of `denoisePipeline`/`waveletBlurPipeline`/
    /// `waveletCombinePipeline` — those mono kernels can't run on already-color RGB24 frames.
    private let denoiseRGBAPipeline: MTLComputePipelineState
    private let waveletBlurRGBAPipeline: MTLComputePipelineState
    private let waveletCombineRGBAPipeline: MTLComputePipelineState
    /// GPU counterpart of `LiveStacker`'s masked accumulation — see `normalizeMaskedAccumulator`'s
    /// doc comment in `Shaders.metal`.
    private let accumulateMaskedPipeline: MTLComputePipelineState
    private let normalizeMaskedAccumulatorPipeline: MTLComputePipelineState
    private let histogramBuffer: MTLBuffer

    private var sourceTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    // Scratch textures for the optional denoise/wavelet-sharpen stages, same dimensions/format
    // as `sourceTexture` — allocated lazily only when those features are actually enabled.
    private var denoiseTexture: MTLTexture?
    private var waveletLayer0Texture: MTLTexture?
    private var waveletLayer1Texture: MTLTexture?
    private var waveletOutputTexture: MTLTexture?
    /// Scratch destination for the Live GPU Controls' spatial-denoise stage — deliberately
    /// separate from `denoiseTexture` (the pre-existing "Image Enhancement" denoise scratch) so
    /// the two independent bilateral-denoise stages don't alias the same texture if both happen
    /// to be enabled at once.
    private var liveGPUSpatialTexture: MTLTexture?
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var sourcePixelFormat: MTLPixelFormat = .r8Unorm
    /// Raw packed-RGB24 upload buffer for `processRGB24` — a buffer rather than a texture, since
    /// RGB24 (3 bytes/pixel) isn't a valid Metal texture pixel format.
    private var rgbSourceBuffer: MTLBuffer?
    /// RGBA scratch textures for `processRGB24`'s optional denoise/wavelet-sharpen stages —
    /// `rgbaStretchTexture` holds the just-stretched frame when either stage is enabled (so
    /// `outputTexture` itself stays free to be each pipeline's *final* write target rather than
    /// something those stages have to read from and write back into); `rgbaDenoiseTexture`/
    /// `rgbaWaveletLayer0/1Texture` are each stage's own scratch space, mirroring the mono
    /// path's `denoiseTexture`/`waveletLayer0/1Texture`.
    private var rgbaStretchTexture: MTLTexture?
    private var rgbaDenoiseTexture: MTLTexture?
    private var rgbaWaveletLayer0Texture: MTLTexture?
    private var rgbaWaveletLayer1Texture: MTLTexture?

    /// GPU-side live-stack running-sum texture (`r32Float`) and its frame count. Independent of
    /// `LiveStacker` (the CPU accumulator used by the `CGImage` render path) — when the Metal
    /// preview is active, stacking math itself runs on the GPU end to end, not just the display.
    private var accumulationTexture: MTLTexture?
    private var accumulatedWidth = 0
    private var accumulatedHeight = 0
    private var accumulatedFrameCount = 0
    /// Masked live-stack accumulation state (satellite/aircraft trail masking's GPU path — see
    /// `normalizeMaskedAccumulator`'s doc comment for the overall design). `maskedSumTexture`/
    /// `maskedCountTexture` hold the running per-pixel `(sum, count)` pair while masking is
    /// active; each frame, `normalizeMaskedAccumulator` collapses them into `accumulationTexture`
    /// itself as a true per-pixel average, so everything downstream of `accumulationTexture`
    /// (the debayer/stretch/histogram passes, `divisor` handling) needs zero awareness that
    /// masking happened at all.
    private var maskedSumTexture: MTLTexture?
    private var maskedCountTexture: MTLTexture?
    private var streakMaskBuffer: MTLBuffer?
    private var streakMaskBufferCapacity = 0
    /// Whether the *previous* processed frame used the masked-accumulation path — compared
    /// against this frame's own state so a mode switch (mask turning on/off, or a dimension
    /// change) can force a `resetLiveStack()` instead of corrupting `accumulationTexture`'s
    /// meaning (see the masked-accumulation block in `process` for why mixing modes is unsafe).
    private var wasAccumulatingMasked = false

    /// Live-stack drift reduction — see the "Drift reduction" section below `process` for the
    /// full explanation. `driftReferenceCentroid` is the tracked star's position on the first
    /// frame of the current stacking session (fixed until the next reset); `driftTrackedCentroid`
    /// is where it was found *last* frame, which the next frame's search centers on so the lock
    /// can follow slow drift instead of only ever looking in one fixed spot.
    private var driftReferenceCentroid: SIMD2<Float>?
    private var driftTrackedCentroid: SIMD2<Float>?
    private var driftReductionWasEnabled = false
    private var driftPartialsBuffer: MTLBuffer?
    private var driftPartialsCapacity = 0
    /// Side length (px) of the square search window `computeCentroid` re-locates the tracked star
    /// within each frame — small on purpose (cheap every-frame dispatch), but comfortably larger
    /// than a real star's PSF plus a frame's worth of realistic drift at typical exposure lengths.
    private static let driftROISize = 64

    /// Live GPU Controls' persistent temporal (EMA) accumulator — unlike `accumulationTexture`
    /// above (a running *sum*, divided back down at display time), this holds the blended value
    /// directly, in the source's own mono format, since it's meant to look like "the current
    /// frame, smoothed" rather than a multi-frame stack.
    private var temporalTexture: MTLTexture?
    private var temporalWidth = 0
    private var temporalHeight = 0
    private var temporalPixelFormat: MTLPixelFormat = .r8Unorm
    /// Tracks the rising edge of `GPULiveControlsSnapshot.isEnabled` so the first frame after
    /// (re)enabling seeds the accumulator with `alpha: 1.0` (i.e. just copies the current frame)
    /// instead of blending against stale content from before it was last turned off.
    private var liveGPUWasEnabled = false

    /// Set by the owning view whenever a new frame should be (re)processed.
    var pendingUpdate: (
        frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN,
        stretch: DisplayStretch, isLiveStacking: Bool, isLiveStackPaused: Bool, isDriftReductionEnabled: Bool, streakMask: StreakMask?,
        isDenoisingEnabled: Bool, isWaveletSharpeningEnabled: Bool, sharpenAmount: Float,
        liveGPUControls: GPULiveControlsSnapshot
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
              let temporalAccumulatorFn = library.makeFunction(name: "temporalAccumulator"),
              let arcsinhStretchFn = library.makeFunction(name: "arcsinhStretch"),
              let findBrightestFn = library.makeFunction(name: "findBrightestPartial"),
              let roiStatsFn = library.makeFunction(name: "roiStatsPartial"),
              let centroidFn = library.makeFunction(name: "centroidPartial"),
              let accumulateAlignedFn = library.makeFunction(name: "accumulateMonoAligned"),
              let denoiseRGBAFn = library.makeFunction(name: "bilateralDenoiseRGBA"),
              let waveletBlurRGBAFn = library.makeFunction(name: "waveletBlurRGBA"),
              let waveletCombineRGBAFn = library.makeFunction(name: "waveletCombineRGBA"),
              let accumulateMaskedFn = library.makeFunction(name: "accumulateMonoMasked"),
              let normalizeMaskedAccumulatorFn = library.makeFunction(name: "normalizeMaskedAccumulator"),
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
            self.temporalAccumulatorPipeline = try device.makeComputePipelineState(function: temporalAccumulatorFn)
            self.arcsinhStretchPipeline = try device.makeComputePipelineState(function: arcsinhStretchFn)
            self.findBrightestPipeline = try device.makeComputePipelineState(function: findBrightestFn)
            self.roiStatsPipeline = try device.makeComputePipelineState(function: roiStatsFn)
            self.centroidPipeline = try device.makeComputePipelineState(function: centroidFn)
            self.accumulateAlignedPipeline = try device.makeComputePipelineState(function: accumulateAlignedFn)
            self.denoiseRGBAPipeline = try device.makeComputePipelineState(function: denoiseRGBAFn)
            self.waveletBlurRGBAPipeline = try device.makeComputePipelineState(function: waveletBlurRGBAFn)
            self.waveletCombineRGBAPipeline = try device.makeComputePipelineState(function: waveletCombineRGBAFn)
            self.accumulateMaskedPipeline = try device.makeComputePipelineState(function: accumulateMaskedFn)
            self.normalizeMaskedAccumulatorPipeline = try device.makeComputePipelineState(function: normalizeMaskedAccumulatorFn)

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
        liveGPUSpatialTexture = makeScratch()
    }

    /// The display-sized `outputTexture` plus its RGBA denoise/wavelet-sharpen scratch textures,
    /// for `processRGB24` — RGB24 has no mono `sourceTexture` to keep in sync (see
    /// `ensureTextures`), so this is deliberately narrower than that, just sized/formatted the
    /// same as every RGBA texture this path needs.
    private func ensureOutputTexture(width: Int, height: Int) {
        guard outputTexture == nil || outputTexture?.width != width || outputTexture?.height != height else { return }
        func makeRGBA() -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderWrite, .shaderRead]
            return device.makeTexture(descriptor: descriptor)
        }
        outputTexture = makeRGBA()
        rgbaStretchTexture = makeRGBA()
        rgbaDenoiseTexture = makeRGBA()
        rgbaWaveletLayer0Texture = makeRGBA()
        rgbaWaveletLayer1Texture = makeRGBA()
    }

    private func ensureRGBSourceBuffer(byteCount: Int) {
        guard rgbSourceBuffer == nil || rgbSourceBuffer!.length < byteCount else { return }
        rgbSourceBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
    }

    /// Stretch + display (no debayer) for webcam/iPhone RGB24 frames, entirely on the GPU —
    /// see `stretchRGB24`'s doc comment for why this reads from a buffer, not a texture.
    ///
    /// Denoise/wavelet-sharpen (RGBA color analogs of the mono kernels the ZWO RAW8/RAW16/Y8
    /// path uses) route the stretch's output through however many of those two stages are
    /// enabled before it reaches `outputTexture` — the *last* enabled stage always writes
    /// directly into `outputTexture` (rather than a scratch texture the caller would then need
    /// an extra copy pass to land in the right place), so the common "neither enabled" case pays
    /// no extra texture writes at all: `stretchRGB24Pipeline` still targets `outputTexture`
    /// directly then, exactly as before this pair of stages existed.
    private func processRGB24(
        frame: CapturedFrame, stretch: DisplayStretch,
        isDenoisingEnabled: Bool, isWaveletSharpeningEnabled: Bool, sharpenAmount: Float,
        liveGPUControls: GPULiveControlsSnapshot
    ) {
        ensureOutputTexture(width: frame.width, height: frame.height)
        let byteCount = frame.width * frame.height * 3
        ensureRGBSourceBuffer(byteCount: byteCount)
        let needsRGBAProcessing = isDenoisingEnabled || isWaveletSharpeningEnabled
        guard let outputTexture, let rgbSourceBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder(),
              !needsRGBAProcessing || rgbaStretchTexture != nil
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

        // Stretches straight into `outputTexture` when nothing else needs to run afterward;
        // otherwise into `rgbaStretchTexture`, since denoise/wavelet-sharpen need to read from a
        // texture distinct from wherever they'll ultimately write.
        let stretchDestination = needsRGBAProcessing ? rgbaStretchTexture! : outputTexture
        encoder.setComputePipelineState(stretchRGB24Pipeline)
        encoder.setBuffer(rgbSourceBuffer, offset: 0, index: 0)
        encoder.setBytes(&width, length: MemoryLayout<UInt32>.size, index: 1)
        encoder.setBytes(&stretchParams, length: MemoryLayout.size(ofValue: stretchParams), index: 2)
        encoder.setTexture(stretchDestination, index: 0)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)

        var workingTexture = stretchDestination

        if isDenoisingEnabled, let rgbaDenoiseTexture {
            // If wavelet-sharpening will also run, this can't be the final stage, so it targets
            // its own scratch texture; otherwise it's the last stage and writes straight into
            // `outputTexture`.
            let destination = isWaveletSharpeningEnabled ? rgbaDenoiseTexture : outputTexture
            var spatialSigma: Float = 1.5
            var rangeSigma: Float = 0.08
            encoder.setComputePipelineState(denoiseRGBAPipeline)
            encoder.setTexture(workingTexture, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.setBytes(&spatialSigma, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&rangeSigma, length: MemoryLayout<Float>.size, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            workingTexture = destination
        }

        if isWaveletSharpeningEnabled,
           let layer0 = rgbaWaveletLayer0Texture, let layer1 = rgbaWaveletLayer1Texture {
            var spacing0: Int32 = 1
            encoder.setComputePipelineState(waveletBlurRGBAPipeline)
            encoder.setTexture(workingTexture, index: 0)
            encoder.setTexture(layer0, index: 1)
            encoder.setBytes(&spacing0, length: MemoryLayout<Int32>.size, index: 0)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)

            var spacing1: Int32 = 2
            encoder.setComputePipelineState(waveletBlurRGBAPipeline)
            encoder.setTexture(layer0, index: 0)
            encoder.setTexture(layer1, index: 1)
            encoder.setBytes(&spacing1, length: MemoryLayout<Int32>.size, index: 0)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)

            // Always the final stage when enabled — writes straight into `outputTexture`.
            var fineGain = sharpenAmount
            var midGain = sharpenAmount * 0.6
            encoder.setComputePipelineState(waveletCombineRGBAPipeline)
            encoder.setTexture(workingTexture, index: 0)
            encoder.setTexture(layer0, index: 1)
            encoder.setTexture(layer1, index: 2)
            encoder.setTexture(outputTexture, index: 3)
            encoder.setBytes(&fineGain, length: MemoryLayout<Float>.size, index: 0)
            encoder.setBytes(&midGain, length: MemoryLayout<Float>.size, index: 1)
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        }

        applyArcsinhStretchIfNeeded(liveGPUControls, encoder: encoder, threadgroups: threadgroups, threadsPerGroup: threadsPerGroup)
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

    /// Resets the GPU live-stack accumulator (new session, format change, or user-requested reset)
    /// and, with it, drift reduction's star lock — a lock from a previous session/target must
    /// never carry over into a new one.
    func resetLiveStack() {
        accumulatedFrameCount = 0
        driftReferenceCentroid = nil
        driftTrackedCentroid = nil
        wasAccumulatingMasked = false
        guard let accumulationTexture, let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        dispatch(clearPipeline, encoder: encoder, texture0: accumulationTexture, width: accumulatedWidth, height: accumulatedHeight)
        if let maskedSumTexture {
            dispatch(clearPipeline, encoder: encoder, texture0: maskedSumTexture, width: accumulatedWidth, height: accumulatedHeight)
        }
        if let maskedCountTexture {
            dispatch(clearPipeline, encoder: encoder, texture0: maskedCountTexture, width: accumulatedWidth, height: accumulatedHeight)
        }
        encoder.endEncoding()
        commandBuffer.commit()
    }

    /// Reads back the GPU live-stack accumulator's current average as a full-bit-depth
    /// `CapturedFrame` — `nil` if there's no active accumulation session yet (`accumulatedFrameCount
    /// == 0`) or the accumulator texture doesn't exist.
    ///
    /// This exists specifically so exporting "the current frame" while Live Stack is running on
    /// the GPU render path actually exports *the stack*, not whatever the latest raw single frame
    /// happened to be — which is what every export path silently did before this existed, since
    /// `CameraManager.currentFrame` is only ever the raw per-frame data on the GPU path (the
    /// accumulation happens entirely inside this class, display-only, with nothing handing the
    /// running average back out). `CameraManager.gpuAccumulatedFrameProvider` (set by
    /// `MetalPreviewView`) is what calls this on demand.
    ///
    /// `accumulationTexture` holds a sum of *normalized* `0...1` texture reads (Metal's
    /// `r8Unorm`/`r16Unorm` texture reads are always normalized floats, never the raw integer
    /// value), so recovering real pixel values needs multiplying back up by `maxValue` (255 for
    /// 8-bit, 65535 for 16-bit) after dividing by the right count — `1.0` if the masked-
    /// accumulation path already normalized it (see `normalizeMaskedAccumulator`), or
    /// `accumulatedFrameCount` otherwise, mirroring exactly what `stretchMono`/`debayerAndStretch`
    /// already do for display.
    func currentAccumulatedFrame(imageType: ASI_IMG_TYPE) -> CapturedFrame? {
        guard let accumulationTexture, accumulatedFrameCount > 0 else { return nil }
        let width = accumulatedWidth
        let height = accumulatedHeight
        guard width > 0, height > 0 else { return nil }

        var sums = [Float](repeating: 0, count: width * height)
        sums.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            accumulationTexture.getBytes(
                base, bytesPerRow: width * MemoryLayout<Float>.size,
                from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0
            )
        }

        let divisor: Float = wasAccumulatingMasked ? 1.0 : Float(accumulatedFrameCount)
        let maxValue: Float = imageType == ASI_IMG_RAW16 ? 65535 : 255
        let pixelCount = width * height

        if imageType == ASI_IMG_RAW16 {
            var output = Data(count: pixelCount * 2)
            output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let out = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<pixelCount {
                    out[i] = UInt16(clamping: Self.rawPixelValue(fromAccumulatedSum: sums[i], divisor: divisor, maxValue: maxValue))
                }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: output)
        } else {
            // RAW8/Y8 — the only other mono formats the GPU live-stack accumulator ever runs on
            // (RGB24 webcam/iPhone frames don't have GPU live-stacking at all yet, a separate,
            // already-documented gap).
            var output = Data(count: pixelCount)
            output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let out = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<pixelCount {
                    out[i] = UInt8(clamping: Self.rawPixelValue(fromAccumulatedSum: sums[i], divisor: divisor, maxValue: maxValue))
                }
            }
            return CapturedFrame(width: width, height: height, imageType: imageType, data: output)
        }
    }

    /// The actual "GPU accumulator sum -> real sensor pixel value" conversion, factored out of
    /// `currentAccumulatedFrame` specifically so this arithmetic — easy to get subtly wrong (e.g.
    /// forgetting the normalized-texture-read scaling by `maxValue`, or using the wrong divisor
    /// for the masked-vs-unmasked accumulation path) — has direct unit test coverage
    /// (`MetalFrameRendererTests`) without needing a full Metal render pipeline to drive it.
    static func rawPixelValue(fromAccumulatedSum sum: Float, divisor: Float, maxValue: Float) -> Int {
        let normalized = sum / divisor
        return Int((normalized * maxValue).rounded())
    }

    // MARK: - Drift reduction (live-stack alignment)

    /// Estimates how far a locked-on bright star has drifted since the first frame of this
    /// live-stack session, for `process` to shift this frame by before folding it into the
    /// running sum. Returns `nil` when alignment isn't usable for this frame — no signal at all,
    /// or the tracked star was lost (moved out of its search window, e.g. behind a cloud) — in
    /// which case the caller should fall back to plain unaligned accumulation rather than apply a
    /// stale or wrong shift.
    ///
    /// Synchronous: commits a small command buffer of its own and blocks (`waitUntilCompleted`)
    /// on it before returning, so the shift is ready to feed into the very same frame's
    /// accumulate dispatch. That's a real, deliberate GPU round-trip on the calling thread once
    /// per frame while drift reduction is on — acceptable because the dispatches themselves are
    /// tiny (a `driftROISize`×`driftROISize` window every frame; a full-frame scan only on the
    /// first frame of a session, and again whenever the local search below loses the lock) — see
    /// `docs/design-notes.md` for the actual tradeoff.
    private func computeDriftShift(source: MTLTexture, width: Int, height: Int) -> SIMD2<Float>? {
        guard let referenceCentroid = driftReferenceCentroid else {
            guard let reacquired = reacquireLock(source: source, width: width, height: height) else { return nil }
            driftReferenceCentroid = reacquired
            driftTrackedCentroid = reacquired
            return SIMD2<Float>(repeating: 0)
        }
        if let lastTracked = driftTrackedCentroid,
           let centroid = computeCentroid(source: source, center: lastTracked, width: width, height: height) {
            driftTrackedCentroid = centroid
            return DriftAligner.shift(current: centroid, reference: referenceCentroid)
        }
        // The local `driftROISize`×`driftROISize` search around the last known position found
        // nothing above background — not just a rare single-frame miss (a passing cloud), but
        // drift larger than that window can follow at all (a poorly-tracking mount over a longer
        // gap, or this frame's motion simply being bigger than the window). Falling back to
        // unaligned accumulation forever after the first such jump would make drift reduction
        // silently stop correcting for the rest of the session — instead, re-scan the whole frame
        // (the same search the very first frame uses) to re-acquire, still measured against the
        // session's original `referenceCentroid` so previously-aligned frames stay consistent.
        guard let reacquired = reacquireLock(source: source, width: width, height: height) else { return nil }
        driftTrackedCentroid = reacquired
        return DriftAligner.shift(current: reacquired, reference: referenceCentroid)
    }

    /// Full-frame brightest-point search followed by a background-subtracted centroid at that
    /// point — used both to establish the very first lock of a session and to re-acquire one that
    /// `computeDriftShift`'s local search has lost.
    private func reacquireLock(source: MTLTexture, width: Int, height: Int) -> SIMD2<Float>? {
        guard let brightest = findBrightestPoint(source: source, width: width, height: height),
              let centroid = computeCentroid(source: source, center: brightest, width: width, height: height)
        else { return nil }
        return centroid
    }

    /// One-time (per stacking session) full-frame brightest-pixel search — the initial guess for
    /// where the star drift reduction locks onto actually is, before any reference centroid
    /// exists yet to search a small window around instead.
    private func findBrightestPoint(source: MTLTexture, width: Int, height: Int) -> SIMD2<Float>? {
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let groupsX = (width + 15) / 16
        let groupsY = (height + 15) / 16
        let groupCount = groupsX * groupsY
        ensureDriftPartialsBuffer(minimumCount: groupCount)
        guard let driftPartialsBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }

        encoder.setComputePipelineState(findBrightestPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(driftPartialsBuffer, offset: 0, index: 0)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 0)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 1)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: groupsX, height: groupsY, depth: 1), threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let partials = driftPartialsBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: groupCount)
        return DriftAligner.brightestPoint(partials: Array(UnsafeBufferPointer(start: partials, count: groupCount)))
    }

    /// Re-locates the tracked star within a `driftROISize`×`driftROISize` window centered on
    /// `center` (its last known position) — run every live-stack frame once a lock exists.
    ///
    /// Two GPU round trips, not one: `roiStatsPartial` first measures the ROI's own local
    /// background level (mean + stddev), then `centroidPartial` weights only pixels a few sigma
    /// above that background. A single-pass plain-intensity centroid over the *whole* ROI is
    /// dominated by sky background (vastly more pixels than the star occupies) rather than the
    /// star itself — seeded by `DriftAligner.backgroundThreshold`'s doc comment, this is the
    /// actual fix for drift reduction computing a near-zero shift regardless of real star motion.
    /// Both passes are on the same tiny ROI (`driftROISize`×`driftROISize`), so the extra round
    /// trip is the same order of cost the single-pass version already was.
    private func computeCentroid(source: MTLTexture, center: SIMD2<Float>, width: Int, height: Int) -> SIMD2<Float>? {
        let roiSize = Self.driftROISize
        let originX = Int32(center.x) - Int32(roiSize / 2)
        let originY = Int32(center.y) - Int32(roiSize / 2)
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let groupsPerAxis = (roiSize + 15) / 16
        let groupCount = groupsPerAxis * groupsPerAxis
        ensureDriftPartialsBuffer(minimumCount: groupCount)
        guard let driftPartialsBuffer else { return nil }
        var roi = (originX, originY, Int32(roiSize))

        guard let statsCommandBuffer = commandQueue.makeCommandBuffer(),
              let statsEncoder = statsCommandBuffer.makeComputeCommandEncoder()
        else { return nil }
        statsEncoder.setComputePipelineState(roiStatsPipeline)
        statsEncoder.setTexture(source, index: 0)
        statsEncoder.setBytes(&roi, length: MemoryLayout.size(ofValue: roi), index: 0)
        statsEncoder.setBuffer(driftPartialsBuffer, offset: 0, index: 1)
        statsEncoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 0)
        statsEncoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 1)
        statsEncoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 2)
        statsEncoder.dispatchThreadgroups(MTLSize(width: groupsPerAxis, height: groupsPerAxis, depth: 1), threadsPerThreadgroup: threadsPerGroup)
        statsEncoder.endEncoding()
        statsCommandBuffer.commit()
        statsCommandBuffer.waitUntilCompleted()

        let statsPartials = driftPartialsBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: groupCount)
        var sum: Float = 0
        var sumSq: Float = 0
        var count: Float = 0
        for i in 0..<groupCount {
            sum += statsPartials[i].x
            sumSq += statsPartials[i].y
            count += statsPartials[i].z
        }
        guard let (background, threshold) = DriftAligner.backgroundThreshold(sum: sum, sumOfSquares: sumSq, count: count)
        else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        var backgroundAndThreshold = SIMD2<Float>(background, threshold)
        encoder.setComputePipelineState(centroidPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBytes(&roi, length: MemoryLayout.size(ofValue: roi), index: 0)
        encoder.setBytes(&backgroundAndThreshold, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setBuffer(driftPartialsBuffer, offset: 0, index: 2)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 0)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 1)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 2)
        encoder.setThreadgroupMemoryLength(256 * MemoryLayout<Float>.size, index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: groupsPerAxis, height: groupsPerAxis, depth: 1), threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let partials = driftPartialsBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: groupCount)
        var sumI: Float = 0
        var sumIx: Float = 0
        var sumIy: Float = 0
        var survivingPixelCount: Float = 0
        for i in 0..<groupCount {
            sumI += partials[i].x
            sumIx += partials[i].y
            sumIy += partials[i].z
            survivingPixelCount += partials[i].w
        }
        // Reject a "lock" that's really a huge overexposed area (a window, a light fixture) —
        // see `DriftAligner.isLikelyPointSource`'s doc comment. `roiSize * roiSize`, not the
        // group-clipped pixel count actually sampled, since that's the same fixed denominator the
        // 15%-of-window heuristic was calibrated against.
        guard DriftAligner.isLikelyPointSource(survivingPixelCount: survivingPixelCount, roiArea: Float(roiSize * roiSize))
        else { return nil }
        return DriftAligner.centroid(sumI: sumI, sumIx: sumIx, sumIy: sumIy)
    }

    private func ensureDriftPartialsBuffer(minimumCount: Int) {
        guard driftPartialsBuffer == nil || driftPartialsCapacity < minimumCount else { return }
        driftPartialsBuffer = device.makeBuffer(length: minimumCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
        driftPartialsCapacity = minimumCount
    }

    private func dispatchAlignedAccumulate(
        encoder: MTLComputeCommandEncoder, source: MTLTexture, accumulator: MTLTexture,
        shift: SIMD2<Float>, width: Int, height: Int
    ) {
        var shiftValue = shift
        encoder.setComputePipelineState(accumulateAlignedPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(accumulator, index: 1)
        encoder.setBytes(&shiftValue, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
    }

    /// Uploads `mask.keepBytes` (0 = keep, 1 = masked out) and dispatches `accumulateMonoMasked`
    /// — the GPU half of satellite/aircraft trail masking (see `Shaders.metal`'s
    /// `accumulateMonoMasked`/`normalizeMaskedAccumulator` for the full design).
    private func dispatchMaskedAccumulate(
        encoder: MTLComputeCommandEncoder, source: MTLTexture, sum: MTLTexture, counts: MTLTexture,
        mask: StreakMask, width: Int, height: Int
    ) {
        ensureStreakMaskBuffer(minimumByteCount: mask.width * mask.height)
        guard let streakMaskBuffer else { return }
        mask.keepBytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            streakMaskBuffer.contents().copyMemory(from: base, byteCount: raw.count)
        }

        var maskWidth = UInt32(mask.width)
        encoder.setComputePipelineState(accumulateMaskedPipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(sum, index: 1)
        encoder.setTexture(counts, index: 2)
        encoder.setBuffer(streakMaskBuffer, offset: 0, index: 0)
        encoder.setBytes(&maskWidth, length: MemoryLayout<UInt32>.size, index: 1)
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
    }

    private func ensureAccumulationTexture(width: Int, height: Int) {
        guard width != accumulatedWidth || height != accumulatedHeight || accumulationTexture == nil else { return }
        accumulatedWidth = width
        accumulatedHeight = height
        func makeR32Float() -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            return device.makeTexture(descriptor: descriptor)
        }
        accumulationTexture = makeR32Float()
        maskedSumTexture = makeR32Float()
        maskedCountTexture = makeR32Float()
        resetLiveStack()
    }

    private func ensureStreakMaskBuffer(minimumByteCount: Int) {
        guard streakMaskBuffer == nil || streakMaskBufferCapacity < minimumByteCount else { return }
        streakMaskBuffer = device.makeBuffer(length: minimumByteCount, options: .storageModeShared)
        streakMaskBufferCapacity = minimumByteCount
    }

    /// Resets the Live GPU Controls temporal accumulator (new camera session, or the next
    /// enabled frame reseeds it anyway via `liveGPUWasEnabled`) — called alongside
    /// `resetLiveStack()` by `MetalPreviewView` whenever `CameraManager.liveStackGeneration`
    /// changes, so a stale frame from a previous session/camera never blends into a new one.
    func resetTemporalAccumulator() {
        liveGPUWasEnabled = false
        guard let temporalTexture, let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        dispatch(clearPipeline, encoder: encoder, texture0: temporalTexture, width: temporalWidth, height: temporalHeight)
        encoder.endEncoding()
        commandBuffer.commit()
    }

    /// Lazily (re)allocates the temporal accumulator at the current frame's dimensions/format —
    /// only actually touched when Live GPU Controls is enabled, unlike the always-allocated
    /// denoise/wavelet scratch textures in `ensureTextures`, since it's a newer, opt-in feature.
    private func ensureTemporalTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> MTLTexture? {
        if temporalTexture == nil || width != temporalWidth || height != temporalHeight || pixelFormat != temporalPixelFormat {
            temporalWidth = width
            temporalHeight = height
            temporalPixelFormat = pixelFormat
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat, width: width, height: height, mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            temporalTexture = device.makeTexture(descriptor: descriptor)
            resetTemporalAccumulator()
        }
        return temporalTexture
    }

    /// Live GPU Controls stage 3 — shared by `process` (RAW8/RAW16) and `processRGB24`, since
    /// arcsinh stretch operates on the final RGBA `outputTexture` regardless of source format.
    private func applyArcsinhStretchIfNeeded(
        _ liveGPUControls: GPULiveControlsSnapshot,
        encoder: MTLComputeCommandEncoder,
        threadgroups: MTLSize,
        threadsPerGroup: MTLSize
    ) {
        guard liveGPUControls.isEnabled, let outputTexture else { return }
        var blackPoint = liveGPUControls.blackPoint
        var whitePoint = liveGPUControls.whitePoint
        var intensity = liveGPUControls.stretchIntensity
        encoder.setComputePipelineState(arcsinhStretchPipeline)
        encoder.setTexture(outputTexture, index: 0)
        encoder.setBytes(&blackPoint, length: MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&whitePoint, length: MemoryLayout<Float>.size, index: 1)
        encoder.setBytes(&intensity, length: MemoryLayout<Float>.size, index: 2)
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
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
        isLiveStackPaused: Bool,
        isDriftReductionEnabled: Bool,
        streakMask: StreakMask?,
        isDenoisingEnabled: Bool,
        isWaveletSharpeningEnabled: Bool,
        sharpenAmount: Float,
        liveGPUControls: GPULiveControlsSnapshot
    ) {
        if frame.imageType == ASI_IMG_RGB24 {
            // Webcam/iPhone frames: already color-processed by the device's own ISP, so no
            // debayering — just stretch, denoise/wavelet-sharpen (color analogs of the mono
            // kernels — see `bilateralDenoiseRGBA`/`waveletBlurRGBA`/`waveletCombineRGBA`), and
            // display. GPU live-stacking is still mono-only (`accumulateMono` reads a single
            // channel) — that gap remains, and the panel warns if it's on for a webcam source.
            // Only affects webcam sources — ZWO cameras never produce RGB24. Arcsinh stretch
            // (stage 3) is source-agnostic, so it's still applied regardless.
            processRGB24(
                frame: frame, stretch: stretch,
                isDenoisingEnabled: isDenoisingEnabled, isWaveletSharpeningEnabled: isWaveletSharpeningEnabled,
                sharpenAmount: sharpenAmount, liveGPUControls: liveGPUControls
            )
            return
        }

        let pixelFormat: MTLPixelFormat = frame.imageType == ASI_IMG_RAW16 ? .r16Unorm : .r8Unorm
        let bytesPerPixel = frame.imageType == ASI_IMG_RAW16 ? 2 : 1
        // Y8 is mono 1-byte/pixel, identical in layout to RAW8 — every other Y8-aware path
        // (`LiveStacker`, `CalibrationLibrary`, `FrameArithmetic`, `GPUFrameCalibrator`, etc.)
        // already treats it exactly like RAW8; this GPU display path just hadn't been updated to
        // match, so it silently fell through to no-op (blank preview) instead of the CPU fallback
        // actually kicking in.
        guard frame.imageType == ASI_IMG_RAW8 || frame.imageType == ASI_IMG_RAW16 || frame.imageType == ASI_IMG_Y8 else {
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

        // Live GPU Controls stages 1+2 (temporal EMA denoise, then spatial bilateral denoise) —
        // run first, ahead of the pre-existing "Image Enhancement" denoise/wavelet stages below,
        // per the spec's pipeline order. Independent controls/textures from those, so both can
        // be on at once without interfering (if unusually heavy-handed together).
        if liveGPUControls.isEnabled {
            let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroups = MTLSize(width: (frame.width + 15) / 16, height: (frame.height + 15) / 16, depth: 1)

            if let temporalTexture = ensureTemporalTexture(width: frame.width, height: frame.height, pixelFormat: pixelFormat) {
                // Rising edge (just enabled, or a fresh session via `resetTemporalAccumulator`):
                // alpha 1.0 makes `mix(previous, current, 1.0) == current`, so the accumulator's
                // possibly-stale/cleared-to-zero previous content is discarded outright instead
                // of being blended in as if it were a real prior frame.
                var alpha = liveGPUWasEnabled ? liveGPUControls.temporalAlpha : 1.0
                encoder.setComputePipelineState(temporalAccumulatorPipeline)
                encoder.setTexture(workingTexture, index: 0)
                encoder.setTexture(temporalTexture, index: 1)
                encoder.setBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
                encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                workingTexture = temporalTexture
            }

            if let liveGPUSpatialTexture {
                var spatialSigma = liveGPUControls.spatialSigma
                var rangeSigma = liveGPUControls.rangeSigma
                encoder.setComputePipelineState(denoisePipeline)
                encoder.setTexture(workingTexture, index: 0)
                encoder.setTexture(liveGPUSpatialTexture, index: 1)
                encoder.setBytes(&spatialSigma, length: MemoryLayout<Float>.size, index: 0)
                encoder.setBytes(&rangeSigma, length: MemoryLayout<Float>.size, index: 1)
                encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                workingTexture = liveGPUSpatialTexture
            }
        }
        liveGPUWasEnabled = liveGPUControls.isEnabled

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
                let usableMask = streakMask.flatMap { mask in
                    mask.width == frame.width && mask.height == frame.height ? mask : nil
                }
                // `accumulationTexture` means two different things depending on whether masking
                // is active this frame — a running *sum* (unmasked `accumulatePipeline`/
                // `accumulateAlignedPipeline`) vs. an already-`normalizeMaskedAccumulator`-ed true
                // per-pixel *average*. Mixing the two within one session would silently corrupt
                // it (a raw-sum add landing on top of a previous frame's already-divided
                // average), so switching modes — the mask turning on/off, or a dimension change —
                // forces a full reset instead, the same way enabling/disabling Live Stack itself
                // already does via `CameraManager.isLiveStackingEnabled`'s `didSet`.
                if (usableMask != nil) != wasAccumulatingMasked {
                    resetLiveStack()
                }
                wasAccumulatingMasked = usableMask != nil

                // Rising edge (just turned on) discards whatever lock a *previous* enable might
                // have left behind — `resetLiveStack` already clears it on a genuinely new
                // session, but toggling drift reduction on mid-session, without also resetting
                // the stack, should still start a fresh lock rather than reuse a stale one from
                // last time it was on.
                if isDriftReductionEnabled, !driftReductionWasEnabled {
                    driftReferenceCentroid = nil
                    driftTrackedCentroid = nil
                }
                driftReductionWasEnabled = isDriftReductionEnabled

                // Paused: freeze the stack exactly as it is — skip adding this frame (and the
                // frame-count/drift-lock bookkeeping that comes with it) but still display
                // whatever `accumulationTexture` already holds, at its existing divisor, so a
                // paused stack reads as "holding still to look at," not as if it reset.
                if !isLiveStackPaused {
                    if let usableMask, let maskedSumTexture, let maskedCountTexture {
                        // Streak masking takes priority over drift-reduction alignment when both are
                        // enabled at once — combining per-pixel masking with sub-pixel shift-sampling
                        // would need a third kernel variant, for a combination that's rare in
                        // practice (satellite trails vs. mount-tracking precision are largely
                        // orthogonal concerns); masking a deep-sky stack against passing satellites
                        // is the more common ask of the two.
                        dispatchMaskedAccumulate(
                            encoder: encoder, source: workingTexture, sum: maskedSumTexture, counts: maskedCountTexture,
                            mask: usableMask, width: frame.width, height: frame.height
                        )
                        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
                        let threadgroups = MTLSize(width: (frame.width + 15) / 16, height: (frame.height + 15) / 16, depth: 1)
                        encoder.setComputePipelineState(normalizeMaskedAccumulatorPipeline)
                        encoder.setTexture(maskedSumTexture, index: 0)
                        encoder.setTexture(maskedCountTexture, index: 1)
                        encoder.setTexture(accumulationTexture, index: 2)
                        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
                        divisor = 1.0 // already a true per-pixel average after normalization
                    } else {
                        let shift = isDriftReductionEnabled
                            ? computeDriftShift(source: workingTexture, width: frame.width, height: frame.height)
                            : nil
                        if let shift {
                            dispatchAlignedAccumulate(
                                encoder: encoder, source: workingTexture, accumulator: accumulationTexture,
                                shift: shift, width: frame.width, height: frame.height
                            )
                        } else {
                            dispatch(accumulatePipeline, encoder: encoder, texture0: workingTexture, texture1: accumulationTexture,
                                     width: frame.width, height: frame.height)
                        }
                        divisor = Float(accumulatedFrameCount + 1)
                    }
                    accumulatedFrameCount += 1
                    onLiveStackFrameCountUpdate?(accumulatedFrameCount)
                } else {
                    divisor = wasAccumulatingMasked ? 1.0 : Float(max(accumulatedFrameCount, 1))
                }
                readSource = accumulationTexture
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

        applyArcsinhStretchIfNeeded(liveGPUControls, encoder: encoder, threadgroups: threadgroups, threadsPerGroup: threadsPerGroup)
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
                isLiveStackPaused: update.isLiveStackPaused,
                isDriftReductionEnabled: update.isDriftReductionEnabled,
                streakMask: update.streakMask,
                isDenoisingEnabled: update.isDenoisingEnabled,
                isWaveletSharpeningEnabled: update.isWaveletSharpeningEnabled,
                sharpenAmount: update.sharpenAmount,
                liveGPUControls: update.liveGPUControls
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
        // Without an explicit viewport, this full-screen-triangle draw covers the *entire*
        // drawable — `outputTexture` (in its own real width:height ratio) gets stretched to
        // whatever shape the view happens to be, unconditionally. `PreviewView`'s SwiftUI-side
        // `.aspectRatio` shapes its *container* using the actual camera/frame ratio, but this GPU
        // path draws into whatever it's given with no matching correction of its own — the only
        // reason this wasn't obviously broken for most ZWO cameras is that many of their sensors
        // are close enough to 4:3 (this view's old hardcoded fallback shape) to hide it. A
        // webcam/iPhone frame (typically 16:9) made the stretch obvious. `letterboxViewport`
        // computes the same "fit, preserve aspect ratio, pillarbox/letterbox the rest" the CPU
        // path already gets for free from `Image(...).aspectRatio(contentMode: .fit)`.
        encoder.setViewport(Self.letterboxViewport(
            textureWidth: outputTexture.width, textureHeight: outputTexture.height, drawableSize: view.drawableSize
        ))
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// The largest `textureWidth:textureHeight`-ratio rectangle that fits inside `drawableSize`,
    /// centered — i.e. exactly what `contentMode: .fit` means, expressed as a GPU viewport
    /// instead of a SwiftUI layout. Bars (drawn as the `MTKView`'s own black `clearColor`, never
    /// touched by this viewport) fill whatever space is left on the short axis.
    static func letterboxViewport(textureWidth: Int, textureHeight: Int, drawableSize: CGSize) -> MTLViewport {
        guard textureWidth > 0, textureHeight > 0, drawableSize.width > 0, drawableSize.height > 0 else {
            return MTLViewport(
                originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1
            )
        }
        let textureAspect = Double(textureWidth) / Double(textureHeight)
        let drawableAspect = drawableSize.width / drawableSize.height

        if drawableAspect > textureAspect {
            // Drawable is relatively wider than the image -> pillarbox (bars on left/right).
            let width = drawableSize.height * textureAspect
            return MTLViewport(
                originX: (drawableSize.width - width) / 2, originY: 0,
                width: width, height: drawableSize.height, znear: 0, zfar: 1
            )
        } else {
            // Drawable is relatively taller than the image -> letterbox (bars on top/bottom).
            let height = drawableSize.width / textureAspect
            return MTLViewport(
                originX: 0, originY: (drawableSize.height - height) / 2,
                width: drawableSize.width, height: height, znear: 0, zfar: 1
            )
        }
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
            cameraManager.gpuAccumulatedFrameProvider = { [weak renderer] imageType in
                renderer?.currentAccumulatedFrame(imageType: imageType)
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
            renderer.resetTemporalAccumulator()
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
            isLiveStackPaused: cameraManager.effectiveLiveStackPaused,
            isDriftReductionEnabled: cameraManager.isLiveStackDriftReductionEnabled,
            streakMask: cameraManager.isStreakMaskingEnabled ? cameraManager.currentStreakMask : nil,
            isDenoisingEnabled: cameraManager.isDenoisingEnabled,
            isWaveletSharpeningEnabled: cameraManager.isWaveletSharpeningEnabled,
            sharpenAmount: Float(cameraManager.waveletSharpenAmount),
            liveGPUControls: cameraManager.gpuControls.snapshot
        )
        nsView.setNeedsDisplay(nsView.bounds)
    }

    final class Coordinator {
        var renderer: MetalFrameRenderer?
        var lastRenderedFrameID: UInt64?
        var lastSeenStackGeneration = 0
    }
}
