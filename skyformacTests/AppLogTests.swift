import Foundation
import Testing
@testable import skyformac

@MainActor
struct AppLogTests {
    /// `AppLog` is a singleton (it needs to be reachable from anywhere without threading a
    /// reference through), so every test clears it first/last to avoid leaking state into
    /// whichever test happens to run next.
    private func withCleanLog(_ body: () -> Void) {
        AppLog.shared.clear()
        body()
        AppLog.shared.clear()
    }

    @Test func logAppendsAnEntry() {
        withCleanLog {
            AppLog.shared.log("hello")
            #expect(AppLog.shared.entries.count == 1)
            #expect(AppLog.shared.entries.first?.message == "hello")
        }
    }

    @Test func clearRemovesEverything() {
        withCleanLog {
            AppLog.shared.log("one")
            AppLog.shared.log("two")
            AppLog.shared.clear()
            #expect(AppLog.shared.entries.isEmpty)
        }
    }

    @Test func fullTextJoinsEveryFormattedLine() {
        withCleanLog {
            AppLog.shared.log("first")
            AppLog.shared.log("second")
            let lines = AppLog.shared.fullText.components(separatedBy: "\n")
            #expect(lines.count == 2)
            #expect(lines[0].contains("first"))
            #expect(lines[1].contains("second"))
        }
    }

    @Test func formattedLineIncludesATimestampAndTheMessage() {
        let entry = LogEntry(date: Date(timeIntervalSince1970: 0), message: "test message")
        #expect(entry.formattedLine.contains("test message"))
        #expect(entry.formattedLine.hasPrefix("["))
    }

    @Test func logCapsToMaxEntriesDroppingTheOldest() {
        withCleanLog {
            for index in 0..<2010 {
                AppLog.shared.log("entry \(index)")
            }
            #expect(AppLog.shared.entries.count == 2000)
            // The oldest entries were dropped — the earliest surviving one is #10, not #0.
            #expect(AppLog.shared.entries.first?.message == "entry 10")
            #expect(AppLog.shared.entries.last?.message == "entry 2009")
        }
    }
}
