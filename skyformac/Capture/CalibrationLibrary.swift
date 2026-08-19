import Foundation
import Observation

enum CalibrationKind {
    case dark
    case flat
}

struct CalibrationFrame: Identifiable, Sendable {
    let id = UUID()
    var name: String
    let frame: CapturedFrame
    let capturedAt: Date
    let exposureMicroseconds: Int
    /// `ASI_GAIN`'s value at the moment this frame was captured — `nil` for a webcam/iPhone
    /// source (no such control) or if it couldn't be read. Matched against the live `ASI_GAIN`
    /// value at apply time (`CameraManager.darkFrameMismatchWarning`) — thermal/read noise is
    /// gain-dependent, so a dark captured at a different gain than what's currently running won't
    /// fully cancel the noise it's meant to, and unlike exposure this was previously tracked
    /// nowhere at all (implicitly "whatever gain happened to be set" with no record of what that
    /// was).
    let gain: Int?

    /// Mean pixel value of `frame`, computed once here rather than by `FlatFieldCorrector` on
    /// every single live frame — a flat frame is static once captured, so recomputing its mean
    /// per incoming video frame (a full extra pass over the flat's pixels, every frame, for the
    /// entire time flat correction stays enabled) was pure waste. Only meaningful for flats, but
    /// harmless (and cheap, since this only runs once per captured calibration frame) to compute
    /// for darks too rather than making it optional.
    let meanBrightness: Double

    init(name: String, frame: CapturedFrame, capturedAt: Date, exposureMicroseconds: Int, gain: Int? = nil) {
        self.name = name
        self.frame = frame
        self.capturedAt = capturedAt
        self.exposureMicroseconds = exposureMicroseconds
        self.gain = gain
        self.meanBrightness = CalibrationFrame.computeMeanBrightness(of: frame)
    }

    private static func computeMeanBrightness(of frame: CapturedFrame) -> Double {
        let count = frame.width * frame.height
        guard count > 0 else { return 0 }
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            guard frame.data.count >= count else { return 0 }
            var sum = 0.0
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for i in 0..<count { sum += Double(base[i]) }
            }
            return sum / Double(count)
        case ASI_IMG_RAW16:
            guard frame.data.count >= count * 2 else { return 0 }
            var sum = 0.0
            frame.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count { sum += Double(base[i]) }
            }
            return sum / Double(count)
        default:
            return 0
        }
    }
}

/// Holds multiple named dark and flat frames — not just one of each — so a session can switch
/// between calibration sets captured at different exposures/gains/temperatures without
/// re-capturing, the same way a real calibration library (SharpCap's dark/flat library, or a
/// PixInsight master-calibration set) works.
@Observable
final class CalibrationLibrary {
    private(set) var darkFrames: [CalibrationFrame] = []
    private(set) var flatFrames: [CalibrationFrame] = []
    var activeDarkID: UUID?
    var activeFlatID: UUID?

    var activeDark: CalibrationFrame? { darkFrames.first { $0.id == activeDarkID } }
    var activeFlat: CalibrationFrame? { flatFrames.first { $0.id == activeFlatID } }

    @discardableResult
    func addDark(_ frame: CapturedFrame, exposureMicroseconds: Int, gain: Int? = nil, name: String? = nil) -> CalibrationFrame {
        let entry = CalibrationFrame(
            name: name ?? "Dark \(darkFrames.count + 1) (\(String(format: "%.2f", Double(exposureMicroseconds) / 1_000_000))s)",
            frame: frame, capturedAt: Date(), exposureMicroseconds: exposureMicroseconds, gain: gain
        )
        darkFrames.append(entry)
        if activeDarkID == nil { activeDarkID = entry.id }
        return entry
    }

    @discardableResult
    func addFlat(_ frame: CapturedFrame, exposureMicroseconds: Int, gain: Int? = nil, name: String? = nil) -> CalibrationFrame {
        let entry = CalibrationFrame(
            name: name ?? "Flat \(flatFrames.count + 1)",
            frame: frame, capturedAt: Date(), exposureMicroseconds: exposureMicroseconds, gain: gain
        )
        flatFrames.append(entry)
        if activeFlatID == nil { activeFlatID = entry.id }
        return entry
    }

    func removeDark(id: UUID) {
        darkFrames.removeAll { $0.id == id }
        if activeDarkID == id { activeDarkID = darkFrames.first?.id }
    }

    func removeFlat(id: UUID) {
        flatFrames.removeAll { $0.id == id }
        if activeFlatID == id { activeFlatID = flatFrames.first?.id }
    }

    func reset() {
        darkFrames.removeAll()
        flatFrames.removeAll()
        activeDarkID = nil
        activeFlatID = nil
    }
}
