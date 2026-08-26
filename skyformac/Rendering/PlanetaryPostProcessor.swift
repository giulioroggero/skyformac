import Accelerate
import Foundation
import CoreGraphics
import simd

/// Native planetary/lunar lucky-imaging post-processing pipeline, implementing
/// `specs/skyformac_Post_Processing_Planets.md` (Frame Ingestion → Debayer → Quality Analysis &
/// Registration → Stacking → Wavelet Sharpening → Color Alignment → Auto-stretch) as an in-app
/// alternative to handing a `.ser` capture off to Siril. The spec allows either an OpenCV/C++
/// core or a pure Apple Accelerate/Metal-native one — this is the latter: every function below is
/// a pure, `nonisolated`, unit-testable value transform (no `MTLDevice`, no camera, no actor
/// isolation), reusing this codebase's existing primitives (`SERReader`, `Debayer`,
/// `SharpnessScorer`, `DriftAligner`'s centroid/shift math, the same à trous wavelet technique
/// `ImageEnhancer.waveletSharpen` already uses, generalized here to an arbitrary layer count)
/// rather than adding a new C++ dependency.
/// A plain, lock-protected cancellation flag — `Task.isCancelled` only reflects the cancellation
/// state of whichever Swift `Task` is *currently executing*, which breaks down inside
/// `DispatchQueue.concurrentPerform` (see `PlanetaryPostProcessor.combine`'s own doc comment):
/// its worker closures run on raw GCD threads with no ambient `Task` context at all, so
/// `Task.isCancelled` checked from inside one of them silently and permanently reads `false` —
/// cancelling the outer `Task` never reaches them. This gets set explicitly by the UI layer
/// instead (`PlanetaryPostProcessingView.runDetached`'s `cancelCurrentWork`) and threaded through
/// every stage's `isCancelled` parameter, so cancellation is visible from any thread it runs on.
final class PlanetaryCancellationFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

enum PlanetaryPostProcessor {
    /// Shared, lazily-created GPU debayer — see `PlanetaryGPULuminanceConverter`'s own doc
    /// comment for why the debayer step specifically gets a Metal path while the rest of the
    /// pipeline stays pure CPU/Accelerate. `nil` (falls back to the CPU `Debayer` path below)
    /// when there's no usable `MTLDevice`, e.g. a sandboxed CI or headless test runner.
    private static let gpuLuminanceConverter = PlanetaryGPULuminanceConverter()
    /// Same "GPU when available, CPU fallback otherwise" shape for `scoreAndRegister`'s own
    /// quality-scoring/centroid math — see `PlanetaryGPURegistrar`'s own doc comment.
    private static let gpuRegistrar = PlanetaryGPURegistrar()
    /// Same shape again for `stack`'s `.mean` shift+combine — see `PlanetaryGPUStacker`'s own
    /// doc comment for why `.median` doesn't use this and stays on the CPU `combine` path.
    private static let gpuStacker = PlanetaryGPUStacker()

    // MARK: - Stage 1: Ingestion

    struct LoadedSequence {
        let frames: [CapturedFrame]
        let isColorCamera: Bool
        let bayerPattern: ASI_BAYER_PATTERN
    }

    static func loadSequence(from url: URL) throws -> LoadedSequence {
        let parsed = try SERReader.read(from: url)
        return LoadedSequence(frames: parsed.frames, isColorCamera: parsed.isColorCamera, bayerPattern: parsed.bayerPattern)
    }

    /// Human-readable name for the log/UI — `bayerPattern.rawValue` alone ("Bayer pattern 0")
    /// means nothing to a user who isn't holding the ZWO SDK header; matches the same
    /// RG/BG/GR/GB → RGGB/BGGR/GRBG/GBRG mapping `FITSWriter` already uses for its own FITS
    /// header card.
    static func bayerPatternName(_ pattern: ASI_BAYER_PATTERN) -> String {
        switch pattern {
        case ASI_BAYER_RG: return "RGGB"
        case ASI_BAYER_BG: return "BGGR"
        case ASI_BAYER_GR: return "GRBG"
        case ASI_BAYER_GB: return "GBRG"
        default: return "RGGB"
        }
    }

    // MARK: - Stage 2: Quality analysis & registration

    struct RegisteredFrame {
        let index: Int
        /// Higher is sharper (`SharpnessScorer`'s Laplacian-variance metric).
        let quality: Double
        /// This frame's translation offset, in full-resolution pixels, from the registration
        /// reference (the sharpest frame) — `.zero` if no usable signal was found (an
        /// all-dark/lost-target frame), which just leaves that frame unshifted rather than
        /// failing the whole batch.
        let shift: SIMD2<Float>
    }

    /// Scores every frame's sharpness and computes its sub-pixel offset from the sharpest frame
    /// via an intensity-weighted centroid within `roi` (the whole frame if `nil`) — the spec's
    /// own "1-Point/Anchor Box" registration, appropriate for a single bright, compact target
    /// (a planet or the Moon) against a dark background, unlike a star-field multi-point
    /// registration. `progress` fires from `0` to `1` as frames are processed — always on the
    /// calling context, not hopped to `@MainActor`, since this whole type has no actor affinity.
    /// Both the quality score and the centroid run on `gpuRegistrar` when one's available (see
    /// its own doc comment) — debayering was the first per-frame bottleneck GPU-accelerated here;
    /// these two full-resolution scalar passes were the two CPU loops left in this stage
    /// afterward.
    static func scoreAndRegister(
        frames: [CapturedFrame], isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN, roi: CGRect? = nil,
        progress: ((Float) -> Void)? = nil, isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [RegisteredFrame] {
        guard !frames.isEmpty else { return [] }
        var qualities = [Double](repeating: 0, count: frames.count)
        var centroids = [SIMD2<Float>?](repeating: nil, count: frames.count)
        // One debayer + luminance conversion per frame, shared by both the quality score and the
        // centroid — `SharpnessScorer.score(for:...)` would otherwise redo its own independent
        // debayer/luminance pass on the exact same frame, doubling the (expensive, full-resolution)
        // per-frame cost for no benefit. `isCancelled` bails out promptly if the surrounding
        // `.task { }`/UI cancels this work — this loop has no other yield point of its own.
        for i in frames.indices {
            if isCancelled() { break }
            defer { progress?(Float(i + 1) / Float(frames.count)) }
            guard let luminance = luminance(of: frames[i], isColorCamera: isColorCamera, bayerPattern: bayerPattern) else { continue }
            if let scored = gpuRegistrar?.scoreAndCentroid(
                ofLuminance: luminance.values, width: luminance.width, height: luminance.height, roi: roi
            ) {
                qualities[i] = scored.quality
                centroids[i] = scored.centroid
            } else {
                qualities[i] = quality(ofLuminance: luminance.values, width: luminance.width, height: luminance.height)
                centroids[i] = centroid(ofLuminance: luminance.values, width: luminance.width, height: luminance.height, roi: roi)
            }
        }
        let referenceIndex = qualities.indices.max { qualities[$0] < qualities[$1] } ?? 0
        let referenceCentroid = centroids[referenceIndex] ?? SIMD2<Float>(repeating: 0)
        return frames.indices.map { i in
            let shift = centroids[i].map { DriftAligner.shift(current: $0, reference: referenceCentroid) } ?? SIMD2<Float>(repeating: 0)
            return RegisteredFrame(index: i, quality: qualities[i], shift: shift)
        }
    }

    /// Full-resolution (not `SharpnessScorer.luminanceGrid`'s downsampled) intensity-weighted
    /// centroid, restricted to `roi` if given — deliberately NOT reusing the scorer's downsampled
    /// grid here, since a shift computed in downsampled-pixel space would need rescaling back up
    /// before it could be applied to full-resolution stacking, an easy place to introduce a
    /// units bug. `nil` for an essentially-empty region (lost target).
    static func centroid(
        of frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN, roi: CGRect?
    ) -> SIMD2<Float>? {
        guard let luminance = luminance(of: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern) else { return nil }
        return centroid(ofLuminance: luminance.values, width: luminance.width, height: luminance.height, roi: roi)
    }

    static func centroid(ofLuminance values: [Float], width: Int, height: Int, roi: CGRect?) -> SIMD2<Float>? {
        let xRange: Range<Int>
        let yRange: Range<Int>
        if let roi {
            xRange = max(0, Int(roi.minX))..<min(width, Int(roi.maxX))
            yRange = max(0, Int(roi.minY))..<min(height, Int(roi.maxY))
        } else {
            xRange = 0..<width
            yRange = 0..<height
        }
        guard !xRange.isEmpty, !yRange.isEmpty else { return nil }

        var sumI: Float = 0, sumIx: Float = 0, sumIy: Float = 0
        for y in yRange {
            let rowBase = y * width
            for x in xRange {
                let value = values[rowBase + x]
                sumI += value
                sumIx += value * Float(x)
                sumIy += value * Float(y)
            }
        }
        return DriftAligner.centroid(sumI: sumI, sumIx: sumIx, sumIy: sumIy)
    }

    /// Debayers (for a color camera) and converts to full-resolution luma, normalized `[0, 1]` —
    /// the shared first step both registration and stacking need, kept as one function so both
    /// stages agree on exactly what "the frame's intensity" means. Tries the GPU debayer path
    /// first for an actual Bayer-mosaic color frame (`gpuLuminanceConverter`'s own doc comment
    /// explains why that step specifically is worth a Metal kernel); falls back to the CPU path
    /// below — `normalizedRGB` + a vDSP-vectorized RGB→luma combination — when there's no GPU
    /// available or the frame isn't a RAW8/16 Bayer mosaic (already-interleaved RGB24, or mono).
    static func luminance(
        of frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN
    ) -> (values: [Float], width: Int, height: Int)? {
        if isColorCamera, let gpuValues = gpuLuminanceConverter?.luminance(of: frame, bayerPattern: bayerPattern) {
            return (gpuValues, frame.width, frame.height)
        }
        guard let rgb = normalizedRGB(of: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern) else { return nil }
        let count = frame.width * frame.height
        guard rgb.channels != 1 else { return (rgb.values, frame.width, frame.height) }

        var luma = [Float](repeating: 0, count: count)
        var tmp = [Float](repeating: 0, count: count)
        var rWeight: Float = 0.299, gWeight: Float = 0.587, bWeight: Float = 0.114
        rgb.values.withUnsafeBufferPointer { rgbBuf in
            let base = rgbBuf.baseAddress!
            luma.withUnsafeMutableBufferPointer { lumaBuf in
                let lbase = lumaBuf.baseAddress!
                vDSP_vsmul(base, 3, &rWeight, lbase, 1, vDSP_Length(count))
                tmp.withUnsafeMutableBufferPointer { tmpBuf in
                    let tbase = tmpBuf.baseAddress!
                    vDSP_vsmul(base + 1, 3, &gWeight, tbase, 1, vDSP_Length(count))
                    vDSP_vadd(lbase, 1, tbase, 1, lbase, 1, vDSP_Length(count))
                    vDSP_vsmul(base + 2, 3, &bWeight, tbase, 1, vDSP_Length(count))
                    vDSP_vadd(lbase, 1, tbase, 1, lbase, 1, vDSP_Length(count))
                }
            }
        }
        return (luma, frame.width, frame.height)
    }

    /// Laplacian-variance sharpness score computed directly from an already-debayered/converted
    /// luminance array — see `scoreAndRegister`'s doc comment for why this avoids calling
    /// `SharpnessScorer.score(for:...)`, which would redo its own independent debayer pass.
    private static func quality(ofLuminance values: [Float], width: Int, height: Int) -> Double {
        guard let grid = SharpnessScorer.downsample(values.map(Double.init), width: width, height: height, maxDimension: 512)
        else { return 0 }
        return SharpnessScorer.laplacianVariance(grid)
    }

    /// Debayers `frame` (if it's a color camera's Bayer mosaic) into normalized `[0, 1]` float
    /// samples — 3 channels (RGB) for a color camera, 1 (mono) otherwise. This is the pipeline's
    /// "32-bit floating-point per-channel tensor" per spec Stage 1, using `Float` (32-bit)
    /// throughout rather than a literal custom tensor type.
    static func normalizedRGB(
        of frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN
    ) -> (values: [Float], channels: Int)? {
        let count = frame.width * frame.height
        if isColorCamera, frame.imageType == ASI_IMG_RAW8 || frame.imageType == ASI_IMG_RAW16,
           let gpuValues = gpuLuminanceConverter?.rgb(of: frame, bayerPattern: bayerPattern) {
            return (gpuValues, 3)
        }
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            if isColorCamera, let rgb = Debayer.debayerRAW8(frame, pattern: bayerPattern) {
                return (normalized(rgb, count: count * 3, maxValue: 255), 3)
            }
            guard frame.data.count >= count else { return nil }
            return (normalized(frame.data, count: count, maxValue: 255), 1)
        case ASI_IMG_RAW16:
            if isColorCamera, let rgb16 = Debayer.debayerRAW16(frame, pattern: bayerPattern) {
                return (normalized16(rgb16, count: count * 3, maxValue: 65535), 3)
            }
            guard frame.data.count >= count * 2 else { return nil }
            return (normalized16(frame.data, count: count, maxValue: 65535), 1)
        case ASI_IMG_RGB24:
            guard frame.data.count >= count * 3 else { return nil }
            return (normalized(frame.data, count: count * 3, maxValue: 255), 3)
        default:
            return nil
        }
    }

    /// vDSP integer-to-float conversion + scalar divide instead of a scalar `.map` over every
    /// sample — called once per frame for every debayered channel, so this is the single
    /// hottest loop in the whole registration/stacking pipeline; vectorizing it is what turns a
    /// multi-minute burst of a few hundred multi-megapixel frames into a few seconds.
    private static func normalized(_ data: Data, count: Int, maxValue: Float) -> [Float] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count >= count else {
                return [Float](repeating: 0, count: count)
            }
            var floats = [Float](repeating: 0, count: count)
            vDSP_vfltu8(base, 1, &floats, 1, vDSP_Length(count))
            var divisor = maxValue
            vDSP_vsdiv(floats, 1, &divisor, &floats, 1, vDSP_Length(count))
            return floats
        }
    }

    private static func normalized16(_ data: Data, count: Int, maxValue: Float) -> [Float] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
            guard let base = raw.bindMemory(to: UInt16.self).baseAddress, raw.count >= count * 2 else {
                return [Float](repeating: 0, count: count)
            }
            var floats = [Float](repeating: 0, count: count)
            vDSP_vfltu16(base, 1, &floats, 1, vDSP_Length(count))
            var divisor = maxValue
            vDSP_vsdiv(floats, 1, &divisor, &floats, 1, vDSP_Length(count))
            return floats
        }
    }

    // MARK: - Stage 3: Frame stacking

    enum StackMethod: String, CaseIterable, Identifiable, Sendable {
        case mean = "Mean"
        case median = "Median"
        var id: String { rawValue }
    }

    /// A stacked (or intermediate wavelet/color-aligned) image — normalized `[0, 1]` float
    /// samples, interleaved if `channels == 3`. The pipeline's "master frame."
    struct StackedImage: Sendable {
        let width: Int
        let height: Int
        let channels: Int
        var values: [Float]
    }

    /// Keeps the sharpest `keepBestPercent`% of `registered` (per spec Stage 3's `cutoffPercentage`),
    /// shifts each selected frame into sub-pixel alignment with the registration reference
    /// (bilinear resampling — `DriftAligner`'s shift convention: sampling the source at
    /// `(x + shift, y + shift)` brings a drifted frame back to where the reference had it), then
    /// combines them pixel-by-pixel with `method` — a true per-pixel median (sorts every
    /// selected frame's value at that pixel) or a plain mean. No median-stacking primitive
    /// existed anywhere in this codebase before this — every existing accumulator
    /// (`LiveStacker`, the GPU `accumulateMono*` kernels) is a streaming running-sum/mean, which
    /// can't compute a median without every sample already resident, unlike this batch pipeline.
    static func stack(
        frames: [CapturedFrame], registered: [RegisteredFrame], isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN,
        keepBestPercent: Double, method: StackMethod, progress: ((Float) -> Void)? = nil,
        isCancelled: @escaping () -> Bool = { Task.isCancelled }
    ) -> StackedImage? {
        guard let first = frames.first else { return nil }
        let sortedByQuality = registered.sorted { $0.quality > $1.quality }
        let keepCount = max(1, Int((Double(sortedByQuality.count) * keepBestPercent / 100).rounded()))
        let selected = Array(sortedByQuality.prefix(keepCount))
        guard !selected.isEmpty else { return nil }

        let width = first.width
        let height = first.height
        var channels = 1

        // Pass 1 (serial — debayer): `gpuLuminanceConverter`'s texture cache is only safe for one
        // frame at a time (see its own doc comment), so this stays a plain loop; it's also the
        // pass the GPU debayer path above already speeds up, so it's rarely the bottleneck anymore.
        var normalizedFrames: [[Float]?] = Array(repeating: nil, count: selected.count)
        for (i, reg) in selected.enumerated() {
            if isCancelled() { break }
            defer { progress?(Float(i + 1) / Float(selected.count) * 0.3) }
            guard let normalized = normalizedRGB(of: frames[reg.index], isColorCamera: isColorCamera, bayerPattern: bayerPattern)
            else { continue }
            channels = normalized.channels
            normalizedFrames[i] = normalized.values
        }
        guard !isCancelled() else { return nil }
        let fixedChannels = channels

        // GPU mean-stack path: streams shift+accumulate straight through `gpuStacker` instead of
        // running Pass 2 (CPU bilinearShift) + `combine` below — see `PlanetaryGPUStacker`'s own
        // doc comment for why this only covers `.mean` (a true `.median` needs every sample
        // resident to select from, defeating this path's whole streaming-memory advantage, so
        // `.median` always falls through to the existing CPU passes further down).
        if method == .mean, let gpuStacker {
            let framesAndShifts = selected.indices.compactMap { i -> ([Float], SIMD2<Float>)? in
                normalizedFrames[i].map { ($0, selected[i].shift) }
            }
            if !framesAndShifts.isEmpty, !isCancelled(),
               let combined = gpuStacker.meanStack(
                   framesAndShifts.map(\.0), shifts: framesAndShifts.map(\.1),
                   width: width, height: height, channels: fixedChannels, isCancelled: isCancelled,
                   progress: { fraction in progress?(0.3 + fraction * 0.7) }
               ) {
                return StackedImage(width: width, height: height, channels: fixedChannels, values: combined)
            }
            // GPU unavailable/failed for this burst — fall through to the CPU passes below.
        }
        guard !isCancelled() else { return nil }

        // Pass 2 (parallel — bilinear resample): unlike the debayer step above, each selected
        // frame's shift is completely independent of every other's, so this full-resolution
        // interpolation — real per-core work, previously the single-threaded chunk of this stage
        // that burned one core while the rest sat idle — spreads across every performance core via
        // `DispatchQueue.concurrentPerform`, same reasoning as `combine`'s own doc comment. Written
        // through `withUnsafeMutableBufferPointer` so each worker's disjoint-index write doesn't
        // trigger a copy-on-write race on the shared array storage.
        var alignedBuffers: [[Float]?] = Array(repeating: nil, count: selected.count)
        let shiftProgressLock = NSLock()
        var shiftedCount = 0
        alignedBuffers.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: selected.count) { i in
                guard !isCancelled(), let values = normalizedFrames[i] else { return }
                let reg = selected[i]
                buffer[i] = bilinearShift(values, width: width, height: height, channels: fixedChannels, dx: reg.shift.x, dy: reg.shift.y)
                shiftProgressLock.lock()
                shiftedCount += 1
                let fraction = 0.3 + Float(shiftedCount) / Float(selected.count) * 0.2
                shiftProgressLock.unlock()
                progress?(fraction)
            }
        }
        let compactedBuffers = alignedBuffers.compactMap { $0 }
        guard !compactedBuffers.isEmpty, !isCancelled() else { return nil }

        let combined = combine(compactedBuffers, method: method, isCancelled: isCancelled) { fraction in progress?(0.5 + fraction * 0.5) }
        guard !isCancelled() else { return nil }
        return StackedImage(width: width, height: height, channels: fixedChannels, values: combined)
    }

    /// Resamples `source` (interleaved, `channels` per pixel) so that `output[x, y] = source[x +
    /// dx, y + dy]` via bilinear interpolation, edge-clamped — undoes a measured `(dx, dy)` drift
    /// by sampling the drifted frame back at the reference's own pixel positions.
    static func bilinearShift(_ source: [Float], width: Int, height: Int, channels: Int, dx: Float, dy: Float) -> [Float] {
        guard dx != 0 || dy != 0 else { return source }
        var output = [Float](repeating: 0, count: source.count)
        for y in 0..<height {
            let srcY = Float(y) + dy
            let y0 = Int(floor(srcY))
            let fy = srcY - Float(y0)
            let y0c = min(max(y0, 0), height - 1)
            let y1c = min(max(y0 + 1, 0), height - 1)
            for x in 0..<width {
                let srcX = Float(x) + dx
                let x0 = Int(floor(srcX))
                let fx = srcX - Float(x0)
                let x0c = min(max(x0, 0), width - 1)
                let x1c = min(max(x0 + 1, 0), width - 1)

                let outBase = (y * width + x) * channels
                for c in 0..<channels {
                    let v00 = source[(y0c * width + x0c) * channels + c]
                    let v10 = source[(y0c * width + x1c) * channels + c]
                    let v01 = source[(y1c * width + x0c) * channels + c]
                    let v11 = source[(y1c * width + x1c) * channels + c]
                    let top = v00 + (v10 - v00) * fx
                    let bottom = v01 + (v11 - v01) * fx
                    output[outBase + c] = top + (bottom - top) * fy
                }
            }
        }
        return output
    }

    /// The dominant cost of the whole stacking stage for a real burst — a full sort of every
    /// selected frame's value at *each* pixel for `.median` (no shortcut: a true median needs
    /// every sample resident and ordered), over however many megapixels the sequence has. Used
    /// to run as one single-threaded scalar loop with zero progress reporting at all — from the
    /// UI's perspective that looked exactly like a hang once the (much cheaper) debayer/shift
    /// loop above finished. Splits the image into row-chunks and runs them concurrently via
    /// `DispatchQueue.concurrentPerform` (each chunk gets its own scratch buffer, so there's no
    /// shared mutable state to race on beyond each chunk's own disjoint slice of `result`) — this
    /// is also the fix for "100% CPU on one core, 0% GPU": there's no GPU primitive for a
    /// per-pixel N-way sort, but the sort itself is embarrassingly parallel across pixels, so
    /// spreading it across every performance core is the next best thing.
    ///
    /// `isCancelled` — not the default `Task.isCancelled` — is required here, not optional: each
    /// `concurrentPerform` iteration runs on a plain GCD worker thread with no ambient Swift
    /// `Task` context, so `Task.isCancelled` checked from inside one would silently always read
    /// `false` no matter what the *actual* calling task's cancellation state is. Cancelling the
    /// surrounding work would then never reach these closures, leaving them to run to completion
    /// regardless — exactly the "CPU stays pegged after Cancel" bug this fixes.
    /// `chunkSize` is derived from a *requested* chunk count (`combine`'s caller scales this by
    /// `activeProcessorCount`, capped at `count`), then `chunkCount` itself is recomputed as
    /// however many chunks of that size `count` actually needs. Using the *requested* count
    /// directly as `combine`'s `DispatchQueue.concurrentPerform` iteration count instead (as an
    /// earlier version of this function did) could leave trailing chunks with nothing left to
    /// cover once `chunkSize` — a ceiling division — didn't divide `count` evenly: e.g. count=16
    /// with a requested 12 chunks gives chunkSize=2, but 12×2=24 overshoots 16, so chunks 9-11
    /// would start past `count` entirely, at which point clamping their `end` to `count` put it
    /// *before* their own `start` and crashed with "Range requires lowerBound <= upperBound"
    /// (only ever observed on a CI runner whose core count produced exactly this mismatch — never
    /// reproduced on a dev machine with enough cores that `count` itself capped the requested
    /// chunk count below any risk of overshoot). Recomputing `chunkCount` this way guarantees the
    /// last chunk always starts before `count`, so no trailing chunk is ever empty — pulled out
    /// as its own `nonisolated` pure function (rather than inlined in `combine`) specifically so
    /// this invariant is directly unit-testable across arbitrary `count`/`requestedChunkCount`
    /// pairs, decoupled from whatever `ProcessInfo.processInfo.activeProcessorCount` actually is
    /// on the machine running the test.
    nonisolated static func chunkPlan(count: Int, requestedChunkCount: Int) -> (chunkSize: Int, chunkCount: Int) {
        guard count > 0 else { return (0, 0) }
        let requested = min(count, max(1, requestedChunkCount))
        let chunkSize = (count + requested - 1) / requested
        let chunkCount = (count + chunkSize - 1) / chunkSize
        return (chunkSize, chunkCount)
    }

    private static func combine(
        _ buffers: [[Float]], method: StackMethod, isCancelled: @escaping () -> Bool, progress: ((Float) -> Void)? = nil
    ) -> [Float] {
        let count = buffers[0].count
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        let frameCount = buffers.count
        let (chunkSize, chunkCount) = chunkPlan(count: count, requestedChunkCount: ProcessInfo.processInfo.activeProcessorCount * 4)
        let progressLock = NSLock()
        var completedChunks = 0

        result.withUnsafeMutableBufferPointer { resultPtr in
            let resultBase = resultPtr.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                guard !isCancelled() else { return }
                var samples = [Float](repeating: 0, count: frameCount)
                let start = chunkIndex * chunkSize
                let end = min(start + chunkSize, count)
                for pixel in start..<end {
                    for f in 0..<frameCount {
                        samples[f] = buffers[f][pixel]
                    }
                    switch method {
                    case .mean:
                        resultBase[pixel] = samples.reduce(0, +) / Float(frameCount)
                    case .median:
                        samples.sort()
                        let mid = frameCount / 2
                        resultBase[pixel] = frameCount % 2 == 0 ? (samples[mid - 1] + samples[mid]) / 2 : samples[mid]
                    }
                }
                progressLock.lock()
                completedChunks += 1
                let fraction = Float(completedChunks) / Float(chunkCount)
                progressLock.unlock()
                progress?(fraction)
            }
        }
        return result
    }

    // MARK: - Stage 4: Planetary wavelet sharpening (multi-scale à trous)

    /// One resolution scale's own contribution — the spec's "4 to 5 resolution scales," each with
    /// its own `gain`. Generalizes `ImageEnhancer.waveletSharpen`'s fixed 2-layer (fine/mid)
    /// shape to an arbitrary layer count via the same repeated-doubling-spacing à trous technique
    /// (5-tap B3-spline `[1, 4, 6, 4, 1]/16`, separable, edge-clamped) that function already uses
    /// — just not hardcoded to stop at 2.
    struct WaveletLayer: Identifiable, Sendable, Equatable {
        var id: Int
        var gain: Double
    }

    /// `denoise` (0...1) softens only the finest layer's own gain (`layers[0]`) — the
    /// highest-frequency scale is where sensor/seeing noise actually lives, so attenuating it
    /// specifically (rather than a separate blur pass) suppresses noise without also softening
    /// the coarser layers real detail (crater rims, cloud bands) lives in.
    static func waveletSharpen(_ image: StackedImage, layers: [WaveletLayer], denoise: Double) -> StackedImage {
        guard !layers.isEmpty else { return image }
        var current = image.values
        var details: [[Float]] = []
        details.reserveCapacity(layers.count)
        var spacing = 1
        for _ in layers {
            let blurred = boxSplineBlur(current, width: image.width, height: image.height, channels: image.channels, spacing: spacing)
            details.append(zipSubtract(current, blurred))
            current = blurred
            spacing *= 2
        }
        // `current` now holds the coarsest low-frequency residual — the pipeline's base layer.
        var output = current
        for (i, layer) in layers.enumerated() {
            let gain = i == 0 ? layer.gain * (1 - min(max(denoise, 0), 1)) : layer.gain
            let detail = details[i]
            for idx in output.indices {
                output[idx] += Float(gain) * detail[idx]
            }
        }
        for idx in output.indices {
            output[idx] = min(max(output[idx], 0), 1)
        }
        return StackedImage(width: image.width, height: image.height, channels: image.channels, values: output)
    }

    private static func zipSubtract(_ a: [Float], _ b: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count { result[i] = a[i] - b[i] }
        return result
    }

    /// One separable pass of the 5-tap B3-spline "à trous" (with holes) blur kernel
    /// `[1, 4, 6, 4, 1]/16`, sampling `spacing` pixels apart (doubling per wavelet layer) instead
    /// of adjacent ones — the defining trick of the stationary wavelet transform: each layer sees
    /// coarser detail without ever actually downsampling the image.
    static func boxSplineBlur(_ source: [Float], width: Int, height: Int, channels: Int, spacing: Int) -> [Float] {
        let weights: [Float] = [1.0 / 16, 4.0 / 16, 6.0 / 16, 4.0 / 16, 1.0 / 16]
        var horizontal = [Float](repeating: 0, count: source.count)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    var sum: Float = 0
                    for (tap, weight) in weights.enumerated() {
                        let offset = (tap - 2) * spacing
                        let sx = min(max(x + offset, 0), width - 1)
                        sum += weight * source[(y * width + sx) * channels + c]
                    }
                    horizontal[(y * width + x) * channels + c] = sum
                }
            }
        }
        var output = [Float](repeating: 0, count: source.count)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<channels {
                    var sum: Float = 0
                    for (tap, weight) in weights.enumerated() {
                        let offset = (tap - 2) * spacing
                        let sy = min(max(y + offset, 0), height - 1)
                        sum += weight * horizontal[(sy * width + x) * channels + c]
                    }
                    output[(y * width + x) * channels + c] = sum
                }
            }
        }
        return output
    }

    // MARK: - Stage 5: RGB channel alignment & auto-stretch

    /// Cross-correlates each of R/B against G (the reference channel) by comparing their own
    /// intensity centroids and shifting to match — fixes the "atmospheric dispersion fringing"
    /// spec Stage 5 describes (a planet's red/blue channels visibly offset from green after
    /// passing through more atmosphere off-zenith). No cross-correlation/dispersion-alignment
    /// code existed anywhere in this codebase before this.
    ///
    /// - Parameter roi: Same pixel region `scoreAndRegister`'s own `roi` restricts registration
    ///   to (the "Object to Track" selector, in the stacked image's coordinate space — valid
    ///   since stacking registers every frame to the same reference position, so the object stays
    ///   roughly where it was in the original frames). `nil` weighs the whole image, same as
    ///   before this parameter existed.
    /// - Important: **Real atmospheric dispersion is always a small effect** — a few pixels, even
    ///   under bad seeing, never a large fraction of the frame. A whole-frame (no `roi`)
    ///   intensity centroid on a small, faint target against a mostly-black frame is dominated by
    ///   whatever noise/background/vignetting happens to sit off to one side, not the target
    ///   itself — reported as R/G/B stacking into three entirely separate, non-overlapping blobs
    ///   instead of subtle edge fringing. `maxShiftFraction` bounds the correction to a sane
    ///   fraction of the search region's own size and simply skips a channel whose computed shift
    ///   exceeds it, on the theory that a huge "correction" is a noise-dominated centroid
    ///   miscomputing itself, not a real optical effect — leaving that channel unaligned (visible
    ///   fringing, at worst) is far less destructive than applying it anyway.
    static func alignRGBChannels(_ image: StackedImage, roi: CGRect? = nil, maxShiftFraction: Float = 0.05) -> StackedImage {
        guard image.channels == 3 else { return image }
        let count = image.width * image.height
        var red = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue = [Float](repeating: 0, count: count)
        for i in 0..<count {
            red[i] = image.values[i * 3]
            green[i] = image.values[i * 3 + 1]
            blue[i] = image.values[i * 3 + 2]
        }
        // Reuses `gpuRegistrar` (registration's own GPU centroid, same doc comment/formula) when
        // one's available rather than a third centroid implementation — this is the same
        // intensity-weighted-sum math `centroid(ofLuminance:...)` computes on CPU, just run once
        // per channel here instead of once per frame.
        func channelCentroid(_ channel: [Float]) -> SIMD2<Float>? {
            if let gpuRegistrar {
                return gpuRegistrar.scoreAndCentroid(ofLuminance: channel, width: image.width, height: image.height, roi: roi)?.centroid
            }
            return centroid(ofLuminance: channel, width: image.width, height: image.height, roi: roi)
        }

        guard let greenCentroid = channelCentroid(green) else { return image }

        let searchDimension = roi.map { Float(min($0.width, $0.height)) } ?? Float(min(image.width, image.height))
        let maxShiftMagnitude = max(2, searchDimension * maxShiftFraction)

        func aligned(_ channel: [Float]) -> [Float] {
            guard let channelCentroid = channelCentroid(channel) else { return channel }
            let shift = DriftAligner.shift(current: channelCentroid, reference: greenCentroid)
            guard (shift * shift).sum().squareRoot() <= maxShiftMagnitude else { return channel }
            return bilinearShift(channel, width: image.width, height: image.height, channels: 1, dx: shift.x, dy: shift.y)
        }
        let alignedRed = aligned(red)
        let alignedBlue = aligned(blue)

        var output = image.values
        for i in 0..<count {
            output[i * 3] = alignedRed[i]
            output[i * 3 + 2] = alignedBlue[i]
        }
        return StackedImage(width: image.width, height: image.height, channels: image.channels, values: output)
    }

    /// Renders `image` to an 8-bit `CGImage` for display/export — a linear black/white-point
    /// stretch by default (matching `DisplayStretch`'s own convention elsewhere in this app), or
    /// the spec's own non-linear stretch formula (`ln(1 + a·x) / ln(1 + a)`) when
    /// `logStretchIntensity` is given, applied per-channel on top of the linear black/white
    /// points (so both controls compose rather than being mutually exclusive).
    static func renderImage(
        _ image: StackedImage, blackPoint: Double, whitePoint: Double, logStretchIntensity: Double?
    ) -> CGImage? {
        guard image.width > 0, image.height > 0 else { return nil }
        let range = Float(max(whitePoint - blackPoint, 0.001))
        let black = Float(blackPoint)
        let logDenominator = logStretchIntensity.map { Float(log(1 + $0)) }
        let intensity = logStretchIntensity.map { Float($0) }

        var pixels = [UInt8](repeating: 255, count: image.width * image.height * 4)
        let count = image.width * image.height
        for i in 0..<count {
            let o = image.channels == 3 ? i * 3 : i
            let step = image.channels == 3 ? 1 : 0
            var r = max(0, (image.values[o] - black) / range)
            var g = image.channels == 3 ? max(0, (image.values[o + step] - black) / range) : r
            var b = image.channels == 3 ? max(0, (image.values[o + step * 2] - black) / range) : r
            if let intensity, let logDenominator, logDenominator > 0 {
                r = log(1 + intensity * r) / logDenominator
                g = log(1 + intensity * g) / logDenominator
                b = log(1 + intensity * b) / logDenominator
            }
            let po = i * 4
            pixels[po] = UInt8(min(max(r, 0), 1) * 255)
            pixels[po + 1] = UInt8(min(max(g, 0), 1) * 255)
            pixels[po + 2] = UInt8(min(max(b, 0), 1) * 255)
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData)
        else { return nil }
        return CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// A 256-bucket histogram of `image`'s own luma — what `DisplayStretch.autoStretch(histogram:)`
    /// needs to derive a default black/white point, the same "look at the actual data" auto-
    /// stretch every other render path in this app already uses, rather than a fixed guess.
    static func histogram(of image: StackedImage) -> [Int] {
        var buckets = [Int](repeating: 0, count: 256)
        let count = image.width * image.height
        for i in 0..<count {
            let o = image.channels == 3 ? i * 3 : i
            let value = image.channels == 3
                ? image.values[o] * 0.299 + image.values[o + 1] * 0.587 + image.values[o + 2] * 0.114
                : image.values[o]
            let bucket = min(max(Int(value * 255), 0), 255)
            buckets[bucket] += 1
        }
        return buckets
    }
}
