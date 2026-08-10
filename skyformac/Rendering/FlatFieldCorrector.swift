import Foundation

/// Division-based flat-field correction — the standard technique for removing vignetting and
/// dust-shadow ("donut") artifacts: a flat frame (an image of an evenly-illuminated target, e.g.
/// twilight sky or a light panel) captures exactly how much dimmer each pixel is than it should
/// be, so dividing every light frame by the (mean-normalized) flat cancels that out.
enum FlatFieldCorrector {
    /// `corrected[p] = light[p] * mean(flat) / flat[p]`, clamped back into the original bit
    /// depth. `nil` if dimensions/image types don't match, or the flat is degenerate (all zero).
    ///
    /// `precomputedFlatMean`: pass `CalibrationFrame.meanBrightness` here when it's available
    /// (the flat frame is static once captured, so its mean shouldn't be recomputed from scratch
    /// on every live video frame this runs against) — `nil` falls back to computing it here, kept
    /// for callers (tests, one-off usages) that only have a bare `CapturedFrame`.
    static func correct(light: CapturedFrame, flat: CapturedFrame, precomputedFlatMean: Double? = nil) -> CapturedFrame? {
        guard light.imageType.rawValue == flat.imageType.rawValue,
              light.width == flat.width, light.height == flat.height
        else { return nil }

        switch light.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            return correct8(light: light, flat: flat, precomputedFlatMean: precomputedFlatMean)
        case ASI_IMG_RAW16:
            return correct16(light: light, flat: flat, precomputedFlatMean: precomputedFlatMean)
        default:
            return nil
        }
    }

    private static func correct8(light: CapturedFrame, flat: CapturedFrame, precomputedFlatMean: Double?) -> CapturedFrame? {
        let count = light.width * light.height
        guard light.data.count >= count, flat.data.count >= count else { return nil }

        var meanFlat: Double
        if let precomputedFlatMean {
            meanFlat = precomputedFlatMean
        } else {
            meanFlat = 0.0
            flat.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count { meanFlat += Double(base[i]) }
            }
            meanFlat /= Double(count)
        }
        guard meanFlat > 0 else { return nil }

        var output = Data(count: count)
        light.data.withUnsafeBytes { (lightRaw: UnsafeRawBufferPointer) in
            flat.data.withUnsafeBytes { (flatRaw: UnsafeRawBufferPointer) in
                output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                    guard let lightBase = lightRaw.bindMemory(to: UInt8.self).baseAddress,
                          let flatBase = flatRaw.bindMemory(to: UInt8.self).baseAddress,
                          let outBase = outRaw.bindMemory(to: UInt8.self).baseAddress
                    else { return }
                    for i in 0..<count {
                        let flatValue = max(Double(flatBase[i]), 1)
                        let corrected = Double(lightBase[i]) * meanFlat / flatValue
                        outBase[i] = UInt8(clamping: Int(corrected.rounded()))
                    }
                }
            }
        }
        return CapturedFrame(width: light.width, height: light.height, imageType: light.imageType, data: output)
    }

    private static func correct16(light: CapturedFrame, flat: CapturedFrame, precomputedFlatMean: Double?) -> CapturedFrame? {
        let count = light.width * light.height
        guard light.data.count >= count * 2, flat.data.count >= count * 2 else { return nil }

        var meanFlat: Double
        if let precomputedFlatMean {
            meanFlat = precomputedFlatMean
        } else {
            meanFlat = 0.0
            flat.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count { meanFlat += Double(base[i]) }
            }
            meanFlat /= Double(count)
        }
        guard meanFlat > 0 else { return nil }

        var output = Data(count: count * 2)
        light.data.withUnsafeBytes { (lightRaw: UnsafeRawBufferPointer) in
            flat.data.withUnsafeBytes { (flatRaw: UnsafeRawBufferPointer) in
                output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                    guard let lightBase = lightRaw.bindMemory(to: UInt16.self).baseAddress,
                          let flatBase = flatRaw.bindMemory(to: UInt16.self).baseAddress,
                          let outBase = outRaw.bindMemory(to: UInt16.self).baseAddress
                    else { return }
                    for i in 0..<count {
                        let flatValue = max(Double(flatBase[i]), 1)
                        let corrected = Double(lightBase[i]) * meanFlat / flatValue
                        outBase[i] = UInt16(clamping: Int(corrected.rounded()))
                    }
                }
            }
        }
        return CapturedFrame(width: light.width, height: light.height, imageType: light.imageType, data: output)
    }
}
