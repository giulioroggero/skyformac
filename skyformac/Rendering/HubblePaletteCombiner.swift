import Foundation

/// Combines three independently-captured monochrome narrowband channels (Sulfur-II, Hydrogen-
/// alpha, Oxygen-III) into one false-color composite using the classic "Hubble/SHO" palette
/// mapping — SII → Red, Hα → Green, OIII → Blue. Distinct from `PlanetaryPostProcessor.stack`
/// (which combines many frames of the *same* target/filter into one) and `alignRGBChannels`
/// (which nudges a single already-combined color image's own R/G/B channels back into register
/// after atmospheric dispersion) — this combines three genuinely separate captures, each of which
/// has already been reduced to one representative frame (a single still, or a stacked video/`.ser`
/// burst) by the caller.
enum HubblePaletteCombiner {
    /// One channel's representative frame — normalized `[0, 1]`, row-major, single value per
    /// pixel. Pixel dimensions must match across all three channels being combined; nothing here
    /// resizes/crops to reconcile a mismatch, since silently resampling one channel to fit another
    /// would be exactly the kind of surprising, hard-to-notice distortion this app avoids
    /// elsewhere (see `GalleryLibrary`'s own "one level of nesting" scoping for the same instinct
    /// applied to a different feature).
    struct ChannelInput {
        var luminance: [Float]
        var width: Int
        var height: Int
    }

    enum CombineError: Error, LocalizedError {
        case dimensionMismatch
        case emptyChannel

        var errorDescription: String? {
            switch self {
            case .dimensionMismatch:
                return "The three channels aren't the same pixel size — re-crop or re-export them to match before combining."
            case .emptyChannel:
                return "One of the channels has no usable image data."
            }
        }
    }

    /// R = SII, G = Hα, B = OIII — the classic Hubble Palette mapping. `alignChannels` (on by
    /// default — see `alignmentShift`'s own doc comment for why deep-sky narrowband channels need
    /// real structural registration, not a brightness-centroid nudge) aligns SII and OIII onto Hα
    /// as the reference, since Hα is typically the strongest/most detailed signal of the three and
    /// so the most reliable target to register against.
    static func combine(
        sii: ChannelInput, ha: ChannelInput, oiii: ChannelInput, alignChannels: Bool = true,
        isCancelled: () -> Bool = { false }
    ) throws -> PlanetaryPostProcessor.StackedImage {
        guard sii.width == ha.width, sii.height == ha.height, oiii.width == ha.width, oiii.height == ha.height
        else { throw CombineError.dimensionMismatch }
        guard !sii.luminance.isEmpty, !ha.luminance.isEmpty, !oiii.luminance.isEmpty else { throw CombineError.emptyChannel }

        let width = ha.width, height = ha.height
        var siiValues = sii.luminance
        var oiiiValues = oiii.luminance

        if alignChannels {
            let siiShift = alignmentShift(of: sii, toReference: ha)
            siiValues = PlanetaryPostProcessor.bilinearShift(
                sii.luminance, width: width, height: height, channels: 1, dx: Float(-siiShift.dx), dy: Float(-siiShift.dy)
            )
            guard !isCancelled() else { return PlanetaryPostProcessor.StackedImage(width: width, height: height, channels: 3, values: []) }
            let oiiiShift = alignmentShift(of: oiii, toReference: ha)
            oiiiValues = PlanetaryPostProcessor.bilinearShift(
                oiii.luminance, width: width, height: height, channels: 1, dx: Float(-oiiiShift.dx), dy: Float(-oiiiShift.dy)
            )
        }

        var rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = siiValues[i]
            rgb[i * 3 + 1] = ha.luminance[i]
            rgb[i * 3 + 2] = oiiiValues[i]
        }
        return PlanetaryPostProcessor.StackedImage(width: width, height: height, channels: 3, values: rgb)
    }

    /// The integer-pixel `(dx, dy)` that best aligns `channel` onto `reference` — a coarse,
    /// downsampled brute-force search minimizing per-pixel squared difference over the
    /// overlapping region, not `alignRGBChannels`' intensity-weighted centroid. A single bright
    /// planetary disk makes a centroid a reliable, cheap stand-in for "where's the interesting
    /// thing" — a diffuse nebula shot through three different narrowband filters usually shows
    /// completely different *structures* brightest in each (that's the whole point of narrowband
    /// imaging), so a centroid would just as often lock onto the wrong region entirely. Matching
    /// each image's own overall pattern instead doesn't have that blind spot. Downsampled first
    /// (`maxGridDimension`) purely for speed — this runs once per channel pair, not once per
    /// frame, so it doesn't need `PlanetaryPostProcessor`'s own frame-burst performance budget,
    /// but a full-resolution brute-force search would still be needlessly slow.
    static func alignmentShift(
        of channel: ChannelInput, toReference reference: ChannelInput, maxShiftFraction: Double = 0.15
    ) -> (dx: Int, dy: Int) {
        guard channel.width == reference.width, channel.height == reference.height else { return (0, 0) }
        let maxGridDimension = 192
        let (referenceGrid, scale) = downsampled(reference, maxDimension: maxGridDimension)
        let (channelGrid, _) = downsampled(channel, maxDimension: maxGridDimension)
        guard referenceGrid.width == channelGrid.width, referenceGrid.height == channelGrid.height,
              referenceGrid.width > 0, referenceGrid.height > 0, scale > 0
        else { return (0, 0) }

        let maxShift = max(2, Int(Double(min(referenceGrid.width, referenceGrid.height)) * maxShiftFraction))
        var bestScore = Double.infinity
        var best = (dx: 0, dy: 0)
        for dy in -maxShift...maxShift {
            for dx in -maxShift...maxShift {
                let score = meanSquaredDifference(channelGrid, referenceGrid, dx: dx, dy: dy)
                if score < bestScore {
                    bestScore = score
                    best = (dx, dy)
                }
            }
        }
        return (Int((Double(best.dx) / scale).rounded()), Int((Double(best.dy) / scale).rounded()))
    }

    private struct Grid {
        let values: [Float]
        let width: Int
        let height: Int
    }

    /// Box-samples `input` down to at most `maxDimension` on its longer side (a no-op, `scale ==
    /// 1`, if it's already smaller) — nearest-neighbor is plenty for a coarse alignment search;
    /// this grid is discarded the instant `alignmentShift` returns, never shown or stacked.
    private static func downsampled(_ input: ChannelInput, maxDimension: Int) -> (grid: Grid, scale: Double) {
        guard input.width > maxDimension || input.height > maxDimension else {
            return (Grid(values: input.luminance, width: input.width, height: input.height), 1)
        }
        let scale = Double(maxDimension) / Double(max(input.width, input.height))
        let newWidth = max(1, Int(Double(input.width) * scale))
        let newHeight = max(1, Int(Double(input.height) * scale))
        var output = [Float](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            let srcY = min(input.height - 1, Int(Double(y) / scale))
            for x in 0..<newWidth {
                let srcX = min(input.width - 1, Int(Double(x) / scale))
                output[y * newWidth + x] = input.luminance[srcY * input.width + srcX]
            }
        }
        return (Grid(values: output, width: newWidth, height: newHeight), scale)
    }

    /// Mean squared difference between `a` (shifted by `dx`/`dy`) and `b`, over just the region
    /// where both are actually defined after that shift — a smaller region at large shifts is
    /// expected and fine, since the search only ever tries shifts up to a fraction of the frame.
    private static func meanSquaredDifference(_ a: Grid, _ b: Grid, dx: Int, dy: Int) -> Double {
        let width = a.width, height = a.height
        let xStart = max(0, -dx), xEnd = min(width, width - dx)
        let yStart = max(0, -dy), yEnd = min(height, height - dy)
        guard xEnd > xStart, yEnd > yStart else { return .infinity }
        var sum = 0.0
        var count = 0
        for y in yStart..<yEnd {
            let aRow = y * width
            let bRow = (y + dy) * width
            for x in xStart..<xEnd {
                let diff = Double(a.values[aRow + x] - b.values[bRow + x + dx])
                sum += diff * diff
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : .infinity
    }
}
