import Foundation

/// One continuous autoguiding run parsed out of a PHD2 `.log` file — a real log can contain
/// several of these back to back (one per "Guiding Begins"/"Guiding Ends" pair, e.g. one per
/// night or per meridian flip). `raDistance`/`decDistance` are in arcseconds when
/// `pixelScaleArcsecPerPixel` was found in the log (PHD2 prints it once per calibration, as
/// "Pixel scale = X arc-sec/px"), otherwise left in raw guide-camera pixels.
struct PHD2GuideLogSession: Identifiable, Sendable {
    let id = UUID()
    var startedAt: Date?
    var pixelScaleArcsecPerPixel: Double?
    var frames: [Frame]

    struct Frame: Sendable {
        /// Seconds since this session's own "Guiding Begins" — PHD2's own `Time` column.
        var timeSeconds: Double
        var raDistance: Double
        var decDistance: Double
    }

    var isInArcseconds: Bool { pixelScaleArcsecPerPixel != nil }
    var unitLabel: String { isInArcseconds ? "arcsec" : "px" }
}

/// A tolerant line-by-line parser for PHD2's own guide log format — tolerant because the exact
/// column set has changed across PHD2 versions (older logs lack `RARawDistance`/`DECRawDistance`,
/// only `dx`/`dy`), so this reads the header row's actual column names rather than assuming fixed
/// positions, and simply skips anything it doesn't recognize instead of failing the whole file.
enum PHD2GuideLogParser {
    static func parse(_ text: String) -> [PHD2GuideLogSession] {
        var sessions: [PHD2GuideLogSession] = []
        var currentPixelScale: Double?
        var currentColumns: [String]?
        var currentFrames: [PHD2GuideLogSession.Frame] = []
        var currentStart: Date?

        func flush() {
            guard !currentFrames.isEmpty else { return }
            sessions.append(PHD2GuideLogSession(startedAt: currentStart, pixelScaleArcsecPerPixel: currentPixelScale, frames: currentFrames))
            currentFrames = []
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Guiding Begins") {
                flush()
                currentStart = parseDate(from: line)
                currentColumns = nil
                continue
            }
            if line.hasPrefix("Guiding Ends") {
                flush()
                continue
            }
            if line.contains("Pixel scale") {
                if let scale = parsePixelScale(from: line) { currentPixelScale = scale }
                continue
            }
            if line.hasPrefix("Frame,Time") {
                currentColumns = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let columns = currentColumns else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= columns.count, let frame = frame(from: fields, columns: columns) else { continue }
            currentFrames.append(frame)
        }
        flush()
        return sessions
    }

    private static func index(of name: String, in columns: [String]) -> Int? {
        columns.firstIndex(of: name)
    }

    private static func frame(from fields: [String], columns: [String]) -> PHD2GuideLogSession.Frame? {
        guard let timeIndex = index(of: "Time", in: columns), let time = Double(fields[timeIndex]) else { return nil }
        let raIndex = index(of: "RARawDistance", in: columns) ?? index(of: "dx", in: columns)
        let decIndex = index(of: "DECRawDistance", in: columns) ?? index(of: "dy", in: columns)
        guard let raIndex, let decIndex, fields.indices.contains(raIndex), fields.indices.contains(decIndex),
              let ra = Double(fields[raIndex]), let dec = Double(fields[decIndex])
        else { return nil }
        return PHD2GuideLogSession.Frame(timeSeconds: time, raDistance: ra, decDistance: dec)
    }

    private static func parseDate(from line: String) -> Date? {
        guard let range = line.range(of: "at ") else { return nil }
        let rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        // PHD2 sometimes trails the timestamp with "(...)" (guiding parameters, mount name) on the
        // same line — only the leading "yyyy-MM-dd HH:mm:ss" is ever the timestamp itself.
        let timestampPart = String(rest.prefix(19))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: timestampPart)
    }

    private static func parsePixelScale(from line: String) -> Double? {
        guard let equalsRange = line.range(of: "=") else { return nil }
        let afterEquals = line[equalsRange.upperBound...]
        let numberPart = afterEquals.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == " " }
        return Double(numberPart.trimmingCharacters(in: .whitespaces))
    }
}
