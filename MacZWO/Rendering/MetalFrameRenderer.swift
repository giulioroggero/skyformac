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
    private let debayerPipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState

    private var sourceTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var sourceWidth = 0
    private var sourceHeight = 0
    private var sourcePixelFormat: MTLPixelFormat = .r8Unorm

    /// Set by the owning view whenever a new frame should be (re)processed.
    var pendingUpdate: (frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN, stretch: DisplayStretch)?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let stretchFn = library.makeFunction(name: "stretchMono"),
              let debayerFn = library.makeFunction(name: "debayerAndStretch"),
              let vertexFn = library.makeFunction(name: "fullscreenTriangleVertex"),
              let fragmentFn = library.makeFunction(name: "blitFragment")
        else { return nil }

        self.device = device
        self.commandQueue = queue

        do {
            self.stretchPipeline = try device.makeComputePipelineState(function: stretchFn)
            self.debayerPipeline = try device.makeComputePipelineState(function: debayerFn)

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
    }

    private func process(
        frame: CapturedFrame,
        isColorCamera: Bool,
        bayerPattern: ASI_BAYER_PATTERN,
        stretch: DisplayStretch
    ) {
        let pixelFormat: MTLPixelFormat = frame.imageType == ASI_IMG_RAW16 ? .r16Unorm : .r8Unorm
        let bytesPerPixel = frame.imageType == ASI_IMG_RAW16 ? 2 : 1
        guard frame.imageType == ASI_IMG_RAW8 || frame.imageType == ASI_IMG_RAW16 else {
            // RGB24/Y8 straight-to-Metal path isn't wired up yet; CGImageRenderer covers it.
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

        var stretchParams = (Float(stretch.blackPoint), Float(stretch.whitePoint))
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroups = MTLSize(
            width: (frame.width + 15) / 16,
            height: (frame.height + 15) / 16,
            depth: 1
        )

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
                stretch: update.stretch
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
            context.coordinator.renderer = MetalFrameRenderer(device: device)
            view.delegate = context.coordinator.renderer
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        guard let renderer = context.coordinator.renderer,
              let camera = cameraManager.connectedCamera,
              let frame = cameraManager.currentFrame,
              context.coordinator.lastRenderedFrameID != cameraManager.frameID
        else { return }

        context.coordinator.lastRenderedFrameID = cameraManager.frameID
        renderer.pendingUpdate = (
            frame: frame,
            isColorCamera: camera.isColorCamera,
            bayerPattern: camera.bayerPattern,
            stretch: cameraManager.stretch
        )
        nsView.setNeedsDisplay(nsView.bounds)
    }

    final class Coordinator {
        var renderer: MetalFrameRenderer?
        var lastRenderedFrameID: UInt64?
    }
}
