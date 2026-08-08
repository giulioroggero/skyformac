import Testing
@testable import skyformac

struct CloudDriftSentinelTests {
    @Test func firstSampleLocksBaselineWithoutAlerting() {
        let sentinel = CloudDriftSentinel()
        let alerted = sentinel.evaluate(brightness: 150)
        #expect(alerted == false)
        #expect(sentinel.isAlerting == false)
        #expect(sentinel.baseline == 150)
    }

    @Test func suddenBrightnessDropTriggersOneShotAlert() {
        let sentinel = CloudDriftSentinel()
        sentinel.evaluate(brightness: 150) // locks baseline

        let firstDrop = sentinel.evaluate(brightness: 20) // >60% drop
        #expect(firstDrop == true)
        #expect(sentinel.isAlerting == true)

        // Still dim on the next sample — already alerting, so no second one-shot trigger.
        let secondSample = sentinel.evaluate(brightness: 20)
        #expect(secondSample == false)
        #expect(sentinel.isAlerting == true)
    }

    @Test func suddenBrightnessSpikeAlsoTriggersAlert() {
        let sentinel = CloudDriftSentinel()
        sentinel.evaluate(brightness: 50)
        let alerted = sentinel.evaluate(brightness: 400) // a stray light source, not a cloud
        #expect(alerted == true)
        #expect(sentinel.isAlerting == true)
    }

    @Test func stableReadingsNeverAlert() {
        let sentinel = CloudDriftSentinel()
        var anyAlert = false
        for brightness in [150.0, 148, 152, 151, 149, 150] {
            anyAlert = anyAlert || sentinel.evaluate(brightness: brightness)
        }
        #expect(anyAlert == false)
        #expect(sentinel.isAlerting == false)
    }

    @Test func baselineDriftsSlowlyTowardSustainedNewBrightness() {
        let sentinel = CloudDriftSentinel()
        sentinel.evaluate(brightness: 150)
        for _ in 0..<500 { sentinel.evaluate(brightness: 100) }
        // A slow (0.98/0.02 per-sample) exponential moving average should have drifted the
        // baseline most of the way from 150 toward the new sustained 100 after 500 samples.
        #expect(abs((sentinel.baseline ?? 0) - 100) < 5)
    }

    @Test func resetClearsBaselineAndAlertState() {
        let sentinel = CloudDriftSentinel()
        sentinel.evaluate(brightness: 150)
        sentinel.evaluate(brightness: 10)
        #expect(sentinel.isAlerting == true)

        sentinel.reset()
        #expect(sentinel.baseline == nil)
        #expect(sentinel.isAlerting == false)

        // The next sample re-locks a fresh baseline instead of comparing against the old one.
        let alerted = sentinel.evaluate(brightness: 10)
        #expect(alerted == false)
    }
}
