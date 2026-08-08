import Foundation
import Testing
@testable import MacZWO

struct FocusTrackerTests {
    @Test func detectsUpwardDriftTrend() {
        let tracker = FocusTracker()
        let start = Date(timeIntervalSince1970: 0)
        // HFD worsening by 1.0 px every minute for 10 minutes — a clear drift.
        for minute in 0..<10 {
            tracker.record(medianHFD: 2.0 + Double(minute) * 1.0, at: start.addingTimeInterval(Double(minute) * 60))
        }
        #expect(tracker.isDriftDetected(window: 10, thresholdPerMinute: 0.5))
        #expect((tracker.trendPerMinute(window: 10) ?? 0) > 0.9)
    }

    @Test func stableFocusDoesNotTriggerDrift() {
        let tracker = FocusTracker()
        let start = Date(timeIntervalSince1970: 0)
        for minute in 0..<10 {
            tracker.record(medianHFD: 2.5, at: start.addingTimeInterval(Double(minute) * 60))
        }
        #expect(!tracker.isDriftDetected(window: 10))
    }

    @Test func improvingFocusDoesNotTriggerDrift() {
        let tracker = FocusTracker()
        let start = Date(timeIntervalSince1970: 0)
        for minute in 0..<10 {
            tracker.record(medianHFD: 5.0 - Double(minute) * 0.3, at: start.addingTimeInterval(Double(minute) * 60))
        }
        #expect(!tracker.isDriftDetected(window: 10))
    }

    @Test func tooFewSamplesReturnsNilTrend() {
        let tracker = FocusTracker()
        tracker.record(medianHFD: 3.0, at: Date(timeIntervalSince1970: 0))
        #expect(tracker.trendPerMinute() == nil)
        #expect(!tracker.isDriftDetected())
    }

    @Test func resetClearsHistory() {
        let tracker = FocusTracker()
        tracker.record(medianHFD: 3.0, at: Date(timeIntervalSince1970: 0))
        tracker.reset()
        #expect(tracker.samples.isEmpty)
    }

    @Test func oldSamplesAreTrimmedBeyondMaxCount() {
        let tracker = FocusTracker(maxSamples: 5)
        let start = Date(timeIntervalSince1970: 0)
        for i in 0..<10 {
            tracker.record(medianHFD: Double(i), at: start.addingTimeInterval(Double(i)))
        }
        #expect(tracker.samples.count == 5)
        #expect(tracker.samples.first?.medianHFD == 5) // the oldest 5 were trimmed
    }
}
