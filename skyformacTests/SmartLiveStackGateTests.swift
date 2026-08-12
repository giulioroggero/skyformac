import Testing
@testable import skyformac

struct SmartLiveStackGateTests {
    @Test func keepsWhenNoBaselineYet() {
        // First frame of a session — nothing to compare against, so nothing gets rejected.
        let decision = SmartLiveStackGate.decide(
            sharpnessScore: 5, maxObservedScore: 0, qualityFraction: 0.5, isCloudAlertActive: false
        )
        #expect(decision == .keep)
    }

    @Test func keepsWhenScoreCannotBeMeasured() {
        // RGB24 (webcam/iPhone) frames have no GPU sharpness scorer — don't gate what can't be scored.
        let decision = SmartLiveStackGate.decide(
            sharpnessScore: nil, maxObservedScore: 100, qualityFraction: 0.5, isCloudAlertActive: false
        )
        #expect(decision == .keep)
    }

    @Test func keepsAtOrAboveTheThreshold() {
        let decision = SmartLiveStackGate.decide(
            sharpnessScore: 50, maxObservedScore: 100, qualityFraction: 0.5, isCloudAlertActive: false
        )
        #expect(decision == .keep)
    }

    @Test func rejectsBelowTheThreshold() {
        let decision = SmartLiveStackGate.decide(
            sharpnessScore: 49, maxObservedScore: 100, qualityFraction: 0.5, isCloudAlertActive: false
        )
        #expect(decision == .reject(.belowSharpnessThreshold))
    }

    @Test func cloudAlertRejectsEvenAPerfectlySharpFrame() {
        // A cloud/bright-flash alert takes priority — a sharp frame taken during a passing cloud
        // still shouldn't be folded into the stack.
        let decision = SmartLiveStackGate.decide(
            sharpnessScore: 1000, maxObservedScore: 100, qualityFraction: 0.5, isCloudAlertActive: true
        )
        #expect(decision == .reject(.cloudsOrBrightFlash))
    }

    @Test func respectsACustomQualityFraction() {
        // A stricter (higher) fraction rejects more of the same frame.
        let lenient = SmartLiveStackGate.decide(
            sharpnessScore: 80, maxObservedScore: 100, qualityFraction: 0.5, isCloudAlertActive: false
        )
        let strict = SmartLiveStackGate.decide(
            sharpnessScore: 80, maxObservedScore: 100, qualityFraction: 0.9, isCloudAlertActive: false
        )
        #expect(lenient == .keep)
        #expect(strict == .reject(.belowSharpnessThreshold))
    }
}
