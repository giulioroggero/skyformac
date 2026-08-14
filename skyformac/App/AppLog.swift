import Foundation
import Observation

/// One line in the in-app log — timestamped free text. Deliberately not a full logging framework
/// (levels, categories, `os_log` integration) — this exists purely so a user reporting a problem
/// can grab what actually happened without attaching a whole Console.app export.
struct LogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let message: String

    var formattedLine: String {
        "[\(Self.timeFormatter.string(from: date))] \(message)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

/// The whole app's in-memory log, shown by "skyformac → Show Log…". A single `@MainActor`
/// singleton rather than something owned per-`CameraManager` — logging needs to work the same
/// way regardless of which camera session (if any) is active. Populated by
/// `CameraManager.lastErrorMessage`'s `didSet` (catches most real failures for free, since
/// they're already funneled through that one property) plus a handful of manually logged
/// lifecycle events (camera connect/disconnect, Quick Start, Ollama planning failures).
@Observable
@MainActor
final class AppLog {
    static let shared = AppLog()

    private(set) var entries: [LogEntry] = []
    /// Caps memory use for a long-running session — old entries age out once there are plenty
    /// more recent ones to actually look at instead.
    private let maxEntries = 2000

    private init() {}

    func log(_ message: String) {
        entries.append(LogEntry(date: Date(), message: message))
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var fullText: String {
        entries.map(\.formattedLine).joined(separator: "\n")
    }
}
