import CoreGraphics
import Testing
@testable import MacZWO

struct PlanetTrackerTests {
    @Test func firstDetectionSnapsDirectly() {
        let tracker = PlanetTracker(smoothingFactor: 0.3)
        let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let result = tracker.update(with: box)
        #expect(result == box)
    }

    @Test func subsequentDetectionMovesPartwayBySmoothingFactor() {
        let tracker = PlanetTracker(smoothingFactor: 0.5)
        _ = tracker.update(with: CGRect(x: 0, y: 0, width: 0.1, height: 0.1))
        let result = tracker.update(with: CGRect(x: 1, y: 0, width: 0.1, height: 0.1))
        // 50% of the way from x=0 to x=1.
        #expect(result != nil)
        #expect(abs((result?.minX ?? 0) - 0.5) < 0.0001)
    }

    @Test func nilDetectionKeepsLastKnownBox() {
        let tracker = PlanetTracker()
        let box = CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)
        _ = tracker.update(with: box)
        let result = tracker.update(with: nil)
        #expect(result == box)
    }

    @Test func resetClearsTrackedBox() {
        let tracker = PlanetTracker()
        _ = tracker.update(with: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        tracker.reset()
        #expect(tracker.update(with: nil) == nil)
    }
}
