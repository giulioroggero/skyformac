import CoreML
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation

/// Deep-learning cosmic-ray/hot-pixel detection and cleanup — a Core ML port of
/// [profjsb/deepCR](https://github.com/profjsb/deepCR)'s `UNet2Sigmoid` mask model
/// (BSD-3-Clause; see `LICENSE.md` and `scripts/models/convert_deepcr.py` for the exact
/// conversion, validated against the original PyTorch checkpoint to within ~4e-5 per pixel).
/// Distinct from `ImageEditor`'s existing `removesHotPixels` (`CIMedianFilter`, a purely local
/// "is this one pixel a statistical outlier among its immediate neighbors" test): deepCR's own
/// U-Net was trained specifically on real HST cosmic-ray hits, so it recognizes the elongated,
/// often multi-pixel streak shapes an isolated-outlier filter misses or over-triggers on near
/// real stars.
///
/// The model itself only ever predicts *where* the damage is (a per-pixel probability mask) —
/// `clean(_:threshold:)` below does the actual repair with a median-filtered fill inside that
/// mask, the same "replace only the flagged pixels, leave everything else untouched" idea
/// `ImageEditor`'s own star-mask-scoped erosion already uses, rather than converting deepCR's
/// separate `inpaint` network too (a real second model this app doesn't yet bundle — median-fill
/// is simpler and, for the small/sparse damage cosmic rays actually cause, visually
/// indistinguishable from it).
enum CosmicRayRemover {
    enum RemovalError: Error {
        case modelUnavailable
        case predictionFailed
        case renderFailed
    }

    /// Loaded once and reused — `MLModel` compilation/instantiation is real, non-trivial work
    /// (unlike `ImageEditor`'s own lazily-created-once `CIContext`), not something to repeat per
    /// call. `.all` compute units let Core ML itself pick GPU/ANE/CPU per-layer for the fastest
    /// actually-available path on the machine it's running on, the same "let the platform choose"
    /// philosophy the app's other GPU-accelerated paths (`PlanetaryGPUStacker` etc.) already use.
    /// `nonisolated(unsafe)` — `MLModel` isn't `Sendable`-annotated despite `prediction(from:)`
    /// being documented safe to call concurrently from multiple threads, the same "annotated-but-
    /// actually-safe" situation `ImageEditor`'s own shared `CIContext` is in.
    private nonisolated(unsafe) static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "DeepCRCosmicRayMask", withExtension: "mlmodelc")
        else { return nil }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: configuration)
    }()

    /// `true` once at launch — lets a caller (e.g. `ImageAdjustmentsControls`) hide/disable the
    /// "Remove Cosmic Rays" control entirely rather than offering a button that can only ever fail,
    /// on the off chance the bundled model somehow didn't compile into this build.
    static var isAvailable: Bool { model != nil }

    /// Runs the model and repairs whatever it flags — always call from a background context
    /// (`Task.detached`, matching `ImageEditor.computeStarMask`'s own "Vision/ML work never blocks
    /// the main actor" precedent); a modest astro frame takes well under a second on Apple
    /// Silicon's GPU/ANE, but there's no reason to risk a hitch on a large one.
    ///
    /// - Parameter threshold: The mask model's own sigmoid output (0...1) is treated as
    ///   "cosmic ray here" above this value. deepCR's own default (0.5) balances catching real
    ///   hits against flagging genuine bright point sources (stars) as damage.
    static func clean(_ image: CGImage, threshold: Double = 0.5) throws -> CGImage {
        guard let model else { throw RemovalError.modelUnavailable }
        guard let grayscale = image.copy(colorSpace: CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray())
                ?? renderGrayscale(image)
        else { throw RemovalError.renderFailed }

        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint
        else { throw RemovalError.modelUnavailable }
        let featureValue = try MLFeatureValue(cgImage: grayscale, constraint: constraint, options: nil)
        let provider = try MLDictionaryFeatureProvider(dictionary: ["image": featureValue])
        guard let output = try? model.prediction(from: provider),
              let maskArray = output.featureValue(for: "mask")?.multiArrayValue
        else { throw RemovalError.predictionFailed }

        guard let maskImage = maskImage(from: maskArray, threshold: threshold) else { throw RemovalError.renderFailed }
        return try repair(image, maskImage: maskImage)
    }

    /// `MLMultiArray`'s own `(1, 1, H, W)` layout, thresholded and rendered into a plain grayscale
    /// `CGImage` the same size as the model's output — white where the model flagged damage,
    /// black elsewhere, ready to drive `repair(_:maskImage:)`'s blend.
    ///
    /// - Important: This crashed in the field (a real `EXC_BAD_ACCESS`, `CosmicRayRemover
    ///   .maskImage`) on a Mac with an ANE, because the original version assumed a packed,
    ///   contiguous `Float32` buffer sized exactly `width * height` — but Core ML is free to hand
    ///   back a different element type and/or a padded/strided layout depending on which compute
    ///   unit (ANE, GPU, CPU) actually ran the model, which varies by hardware and is exactly what
    ///   `computeUnits = .all` invites it to do. Reading past the *real* (possibly smaller, or
    ///   differently-typed) buffer with a hardcoded `Float32` stride is what walked off the end of
    ///   allocated memory. Branching on `array.dataType` and indexing via `array.strides` (not an
    ///   assumed packed layout) is what actually keeps this correct regardless of which compute
    ///   unit produced the output.
    /// `internal`, not `private` — `CosmicRayRemoverTests` exercises this directly with
    /// hand-built `MLMultiArray`s (a non-`Float32` `dataType`, a padded/strided layout) to cover
    /// exactly the failure mode that crashed in the field, which depends on which compute unit
    /// (ANE/GPU/CPU) actually ran the real model — not something a test can reliably force Core
    /// ML into picking on any given machine.
    static func maskImage(from array: MLMultiArray, threshold: Double) -> CGImage? {
        guard array.shape.count == 4 else { return nil }
        let height = array.shape[2].intValue
        let width = array.shape[3].intValue
        guard width > 0, height > 0 else { return nil }
        let heightStride = array.strides[2].intValue
        let widthStride = array.strides[3].intValue

        // The buffer's real required size from its own shape/strides — *not* `array.count`
        // (the logical element count, `shape.reduce(1, *)`), which undercounts whenever any
        // stride introduces padding a compute unit added for its own alignment/vectorization
        // reasons. Using `array.count` here was a second, subtler bug on top of the original
        // "assumed packed `Float32`" one: it made every per-pixel bounds check below reject
        // legitimate offsets past the logical count, silently dropping real pixels instead of
        // crashing — caught by `CosmicRayRemoverTests
        // .maskImageRespectsAPaddedRowStrideRatherThanAssumingPackedLayout`, which failed against
        // this exact miscalculation before being fixed.
        let elementCount = zip(array.shape, array.strides).reduce(0) { total, dimension in
            total + (dimension.0.intValue - 1) * dimension.1.intValue
        } + 1

        var pixels = [UInt8](repeating: 0, count: width * height)
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float32.self, capacity: elementCount)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * heightStride + x * widthStride
                    guard offset >= 0, offset < elementCount else { continue }
                    pixels[y * width + x] = Double(pointer[offset]) >= threshold ? 255 : 0
                }
            }
        case .float16:
            let pointer = array.dataPointer.bindMemory(to: Float16.self, capacity: elementCount)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * heightStride + x * widthStride
                    guard offset >= 0, offset < elementCount else { continue }
                    pixels[y * width + x] = Double(pointer[offset]) >= threshold ? 255 : 0
                }
            }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: elementCount)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * heightStride + x * widthStride
                    guard offset >= 0, offset < elementCount else { continue }
                    pixels[y * width + x] = pointer[offset] >= threshold ? 255 : 0
                }
            }
        case .int32:
            let pointer = array.dataPointer.bindMemory(to: Int32.self, capacity: elementCount)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * heightStride + x * widthStride
                    guard offset >= 0, offset < elementCount else { continue }
                    pixels[y * width + x] = Double(pointer[offset]) >= threshold ? 255 : 0
                }
            }
        @unknown default:
            return nil
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let context = CGContext(
                  data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        return context.makeImage()
    }

    /// Replaces exactly the masked pixels with a heavily median-filtered version of `image` —
    /// `CIBlendWithMask` again, the same masked-composite technique
    /// `ImageEditor.render(_:with:starMask:)` already uses for scoping star-size reduction,
    /// resized/scaled here to match the mask's own (possibly slightly different, if Core ML
    /// resized internally) dimensions back to `image`'s real size.
    private static func repair(_ image: CGImage, maskImage: CGImage) throws -> CGImage {
        let context = CIContext()
        let ciImage = CIImage(cgImage: image)
        let median = CIFilter.median()
        median.inputImage = ciImage
        guard let repaired = median.outputImage else { throw RemovalError.renderFailed }

        var mask = CIImage(cgImage: maskImage)
        let scaleX = ciImage.extent.width / mask.extent.width
        let scaleY = ciImage.extent.height / mask.extent.height
        if abs(scaleX - 1) > 0.001 || abs(scaleY - 1) > 0.001 {
            mask = mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = repaired
        blend.backgroundImage = ciImage
        blend.maskImage = mask
        guard let blended = blend.outputImage, let output = context.createCGImage(blended, from: ciImage.extent)
        else { throw RemovalError.renderFailed }
        return output
    }

    /// `CGImage.copy(colorSpace:)` returning `nil` (an unusual source color space it can't just
    /// reinterpret) falls back to a real redraw into a fresh grayscale bitmap instead.
    private static func renderGrayscale(_ image: CGImage) -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
