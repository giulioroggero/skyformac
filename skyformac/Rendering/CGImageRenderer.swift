import CoreGraphics
import Foundation
import ImageIO
import simd

/// Converts a `CapturedFrame` into a displayable `CGImage`, applying the color camera's
/// Bayer debayer (via `Debayer`) and a black/white point `DisplayStretch` down to 8-bit
/// output. This is the CPU baseline per spec 3.4 / Milestone 4; the GPU upgrade pass replaces
/// it with a `MetalKit`-backed renderer that does the stretch (and debayer) on the GPU.
enum CGImageRenderer {
    enum LoadError: Error { case unreadableImage }

    /// Loads *any* capture file this app can show a preview for — `.fits`/`.fit` (parsed +
    /// auto-stretched via `FITSReader`/`HistogramComputer`/`DisplayStretch`, same as
    /// `ExportedFileViewerView`'s own FITS path) or anything `ImageIO` already understands
    /// (`.png`/`.tiff`/`.jpg`, decoded directly) — one call for either case, so callers that just
    /// want "a `CGImage` to show" (`SingleImagePostProcessingView`, `SessionStrayFilesBrowserView`
    /// 's own preview pane) don't need to duplicate the FITS-vs-everything-else branch themselves.
    /// `nonisolated` — safe to call from a background thread/`Task.detached`.
    nonisolated static func loadDisplayImage(from url: URL) throws -> CGImage {
        switch url.pathExtension.lowercased() {
        case "fits", "fit":
            let parsed = try FITSReader.read(from: url)
            let histogram = HistogramComputer.histogram(for: parsed.frame)
            let stretch = DisplayStretch.autoStretch(histogram: histogram) ?? .identity
            guard let image = makeDisplayImage(
                from: parsed.frame, isColorCamera: parsed.isColorCamera, bayerPattern: parsed.bayerPattern, stretch: stretch
            ) else { throw LoadError.unreadableImage }
            return image
        default:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { throw LoadError.unreadableImage }
            return image
        }
    }

    /// `channelStretch`/`toneCurves`/`filterGain` are `nil`/identity by default — every existing
    /// caller (exports, the Vision-analysis renders in `CameraManager`'s focus-assist/streak-
    /// detection/planet-tracking paths) keeps getting exactly the base combined `stretch`,
    /// unaffected. Only the CPU live-preview render path (`renderedCurrentImage`/
    /// `scheduleCPUEnhancementIfNeeded`) and the export path pass them, deliberately:
    /// "Independent Channels"/"Curves"/"Filters" are display-and-capture grading, not something
    /// Vision-based star/streak/planet detection should see tweaked underneath it. `filterGain`
    /// only ever applies to a color render — a mono grayscale frame has no per-channel emphasis
    /// to boost in the first place, so the grayscale path below ignores it entirely.
    static func makeDisplayImage(
        from frame: CapturedFrame,
        isColorCamera: Bool,
        bayerPattern: ASI_BAYER_PATTERN,
        stretch: DisplayStretch,
        channelStretch: PerChannelStretch? = nil,
        toneCurves: ChannelToneCurves? = nil,
        filterGain: SIMD3<Float> = SIMD3(repeating: 1)
    ) -> CGImage? {
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            if isColorCamera, frame.imageType == ASI_IMG_RAW8,
               let rgb = Debayer.debayerRAW8(frame, pattern: bayerPattern) {
                return makeRGB8Image(
                    rgb, width: frame.width, height: frame.height,
                    channelStretch: channelStretch ?? PerChannelStretch(uniform: stretch), toneCurves: toneCurves,
                    filterGain: filterGain
                )
            }
            return makeGrayscaleImage(
                frame.data,
                width: frame.width,
                height: frame.height,
                maxValue: 255,
                bytesPerSample: 1,
                stretch: stretch,
                toneCurve: toneCurves?.master
            )
        case ASI_IMG_RAW16:
            if isColorCamera, let rgb16 = Debayer.debayerRAW16(frame, pattern: bayerPattern) {
                return makeRGB16Image(
                    rgb16, width: frame.width, height: frame.height,
                    channelStretch: channelStretch ?? PerChannelStretch(uniform: stretch), toneCurves: toneCurves,
                    filterGain: filterGain
                )
            }
            return makeGrayscaleImage(
                frame.data,
                width: frame.width,
                height: frame.height,
                maxValue: 65535,
                bytesPerSample: 2,
                stretch: stretch,
                toneCurve: toneCurves?.master
            )
        case ASI_IMG_RGB24:
            return makeRGB8Image(
                frame.data, width: frame.width, height: frame.height,
                channelStretch: channelStretch ?? PerChannelStretch(uniform: stretch), toneCurves: toneCurves,
                filterGain: filterGain
            )
        default:
            return nil
        }
    }

    // MARK: - Mono

    private static func makeGrayscaleImage(
        _ data: Data,
        width: Int,
        height: Int,
        maxValue: Int,
        bytesPerSample: Int,
        stretch: DisplayStretch,
        toneCurve: ToneCurve?
    ) -> CGImage? {
        guard data.count >= width * height * bytesPerSample else { return nil }
        var lut = stretch.lookupTable(maxValue: maxValue)
        if let toneCurve {
            let curveLUT = toneCurve.lookupTable()
            lut = lut.map { curveLUT[Int($0)] }
        }
        var output = Data(count: width * height)

        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return }
                if bytesPerSample == 1 {
                    guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return }
                    for i in 0..<(width * height) {
                        dstBase[i] = lut[Int(srcBase[i])]
                    }
                } else {
                    guard let srcBase = src.bindMemory(to: UInt16.self).baseAddress else { return }
                    for i in 0..<(width * height) {
                        dstBase[i] = lut[Int(srcBase[i])]
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: output as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Color

    /// Three independent LUTs (one per channel) instead of one shared LUT — `channelStretch`'s
    /// black/white points, each further composed with `toneCurves`' own per-channel curve when
    /// present, so "Independent Channels" and "Curves" both apply identically whether the source
    /// went through debayering first (RAW8/RAW16) or is already packed RGB24.
    private static func channelLUTs(
        channelStretch: PerChannelStretch, maxValue: Int, toneCurves: ChannelToneCurves?,
        filterGain: SIMD3<Float> = SIMD3(repeating: 1)
    ) -> (red: [UInt8], green: [UInt8], blue: [UInt8]) {
        var red = channelStretch.red.lookupTable(maxValue: maxValue)
        var green = channelStretch.green.lookupTable(maxValue: maxValue)
        var blue = channelStretch.blue.lookupTable(maxValue: maxValue)
        if let toneCurves {
            let redCurve = toneCurves.effectiveRedLUT
            let greenCurve = toneCurves.effectiveGreenLUT
            let blueCurve = toneCurves.effectiveBlueLUT
            red = red.map { redCurve[Int($0)] }
            green = green.map { greenCurve[Int($0)] }
            blue = blue.map { blueCurve[Int($0)] }
        }
        // "Filters" tab — applied last, after stretch/curves, same order as the GPU path's
        // `applyFilterGainRGBA` (after `applyToneCurveRGBA`). Skipped entirely at the identity
        // gain (nothing selected) — the common case — rather than doing a wasted `* 1.0` pass.
        if filterGain != SIMD3(repeating: 1) {
            red = red.map { UInt8(clamping: Int((Float($0) * filterGain.x).rounded())) }
            green = green.map { UInt8(clamping: Int((Float($0) * filterGain.y).rounded())) }
            blue = blue.map { UInt8(clamping: Int((Float($0) * filterGain.z).rounded())) }
        }
        return (red, green, blue)
    }

    private static func makeRGB8Image(
        _ rgbData: Data,
        width: Int,
        height: Int,
        channelStretch: PerChannelStretch,
        toneCurves: ChannelToneCurves?,
        filterGain: SIMD3<Float> = SIMD3(repeating: 1)
    ) -> CGImage? {
        guard rgbData.count >= width * height * 3 else { return nil }
        let luts = channelLUTs(channelStretch: channelStretch, maxValue: 255, toneCurves: toneCurves, filterGain: filterGain)
        var output = Data(count: width * height * 3)
        rgbData.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<(width * height) {
                    let offset = i * 3
                    dstBase[offset] = luts.red[Int(srcBase[offset])]
                    dstBase[offset + 1] = luts.green[Int(srcBase[offset + 1])]
                    dstBase[offset + 2] = luts.blue[Int(srcBase[offset + 2])]
                }
            }
        }
        return makeRGB8CGImage(output, width: width, height: height)
    }

    private static func makeRGB16Image(
        _ rgb16Data: Data,
        width: Int,
        height: Int,
        channelStretch: PerChannelStretch,
        toneCurves: ChannelToneCurves?,
        filterGain: SIMD3<Float> = SIMD3(repeating: 1)
    ) -> CGImage? {
        guard rgb16Data.count >= width * height * 3 * 2 else { return nil }
        let luts = channelLUTs(channelStretch: channelStretch, maxValue: 65535, toneCurves: toneCurves, filterGain: filterGain)
        var output = Data(count: width * height * 3)
        rgb16Data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let srcBase = src.bindMemory(to: UInt16.self).baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<(width * height) {
                    let offset = i * 3
                    dstBase[offset] = luts.red[Int(srcBase[offset])]
                    dstBase[offset + 1] = luts.green[Int(srcBase[offset + 1])]
                    dstBase[offset + 2] = luts.blue[Int(srcBase[offset + 2])]
                }
            }
        }
        return makeRGB8CGImage(output, width: width, height: height)
    }

    private static func makeRGB8CGImage(_ data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: width * 3,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
