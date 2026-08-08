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
    func addDark(_ frame: CapturedFrame, exposureMicroseconds: Int, name: String? = nil) -> CalibrationFrame {
        let entry = CalibrationFrame(
            name: name ?? "Dark \(darkFrames.count + 1) (\(String(format: "%.2f", Double(exposureMicroseconds) / 1_000_000))s)",
            frame: frame, capturedAt: Date(), exposureMicroseconds: exposureMicroseconds
        )
        darkFrames.append(entry)
        if activeDarkID == nil { activeDarkID = entry.id }
        return entry
    }

    @discardableResult
    func addFlat(_ frame: CapturedFrame, exposureMicroseconds: Int, name: String? = nil) -> CalibrationFrame {
        let entry = CalibrationFrame(
            name: name ?? "Flat \(flatFrames.count + 1)",
            frame: frame, capturedAt: Date(), exposureMicroseconds: exposureMicroseconds
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
