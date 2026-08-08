import Foundation

/// Computes the statistically-optimal sub-exposure length for the current sky conditions and
/// camera gain — the "how long should each sub be" question every deep-sky imaging session
/// needs answered.
///
/// - Important on where the numbers come from: the ZWO SDK does **not** expose a per-gain read
///   noise curve (there is no such call in `ASICamera2.h` — the closest thing,
///   `ASIGetGainOffset`, returns a recommended *gain setting* for lowest read noise, not the
///   read noise magnitude itself in electrons). Real capture software gets read noise either
///   from the vendor's published spec sheet, or — as done here — by directly *measuring* it:
///   capture the shortest possible exposure (a bias frame) and compute the standard deviation of
///   its pixel values. That's a standard, real astrophotography technique, not an invented one.
///   `ASI_CAMERA_INFO.ElecPerADU` (a real, fixed camera spec from the SDK) converts the ADU-space
///   measurement into electrons.
enum ExposureOptimizer {
    /// Read noise in electrons, from a bias/very-short-exposure frame's pixel standard deviation.
    static func readNoiseElectrons(biasFrame: CapturedFrame, electronsPerADU: Double) -> Double? {
        guard let stdDev = standardDeviation(of: biasFrame) else { return nil }
        return stdDev * electronsPerADU
    }

    /// Sky background electron rate (electrons/sec/pixel), from a short test exposure's median
    /// pixel value (median, not mean, so stars/hot pixels don't bias the background estimate).
    static func skyBackgroundRate(testFrame: CapturedFrame, exposureSeconds: Double, electronsPerADU: Double) -> Double? {
        guard exposureSeconds > 0, let median = medianValue(of: testFrame) else { return nil }
        return (median * electronsPerADU) / exposureSeconds
    }

    /// The classic sub-exposure-length formula (e.g. Robin Glover's widely-cited "how long
    /// should your subs be" derivation): pick `t` so sky background shot noise (which scales
    /// with `sqrt(rate * t)`) dominates the fixed read noise by `targetRatio` in *noise power*
    /// (variance) — i.e. `rate * t = targetRatio * readNoise^2`. A `targetRatio` of 5-10 means
    /// read noise contributes an insignificant (<10-20%) share of the total noise budget.
    static func optimalSubExposureSeconds(
        readNoiseElectrons: Double,
        skyRateElectronsPerSecond: Double,
        targetRatio: Double = 10.0
    ) -> Double? {
        guard skyRateElectronsPerSecond > 0, readNoiseElectrons > 0 else { return nil }
        return targetRatio * readNoiseElectrons * readNoiseElectrons / skyRateElectronsPerSecond
    }

    // MARK: - Frame statistics

    private static func rawSamples(of frame: CapturedFrame) -> [Double]? {
        let count = frame.width * frame.height
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            guard frame.data.count >= count else { return nil }
            return frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return [] }
                return (0..<count).map { Double(base[$0]) }
            }
        case ASI_IMG_RAW16:
            guard frame.data.count >= count * 2 else { return nil }
            return frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Double] in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return [] }
                return (0..<count).map { Double(base[$0]) }
            }
        default:
            return nil
        }
    }

    private static func standardDeviation(of frame: CapturedFrame) -> Double? {
        guard let samples = rawSamples(of: frame), !samples.isEmpty else { return nil }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(samples.count)
        return variance.squareRoot()
    }

    private static func medianValue(of frame: CapturedFrame) -> Double? {
        guard var samples = rawSamples(of: frame), !samples.isEmpty else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }
}
