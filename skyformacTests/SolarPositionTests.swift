import Foundation
import Testing
@testable import skyformac

struct SolarPositionTests {
    @Test func rightAscensionStaysWithinValidBounds() {
        // A handful of dates spread across a year — every one should land in 0...360, not just
        // whichever season the test happens to be run in.
        let calendar = Calendar(identifier: .gregorian)
        for month in 1...12 {
            let date = calendar.date(from: DateComponents(year: 2026, month: month, day: 15))!
            let ra = SolarPosition.rightAscensionDegrees(on: date)
            #expect(ra >= 0 && ra < 360)
        }
    }

    @Test func rightAscensionAdvancesRoughlyOneDegreePerDayOverAWeek() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let aWeekLater = calendar.date(byAdding: .day, value: 7, to: start)!
        let startRA = SolarPosition.rightAscensionDegrees(on: start)
        let laterRA = SolarPosition.rightAscensionDegrees(on: aWeekLater)
        // The Sun's own RA increases by roughly 360°/365 days ≈ 0.986°/day — over a week (no
        // wraparound expected in early March), that's a real, checkable few-degree advance.
        let advance = laterRA - startRA
        #expect(advance > 5 && advance < 9)
    }

    @Test func tonightVisibleRARangesCoverA180DegreeBandTotal() {
        let ranges = SolarPosition.tonightVisibleRARanges(on: Date())
        #expect(!ranges.isEmpty)
        let totalWidth = ranges.reduce(0.0) { $0 + ($1.end - $1.start) }
        #expect(abs(totalWidth - 180) < 0.01)
        for range in ranges {
            #expect(range.start >= 0 && range.start <= 360)
            #expect(range.end >= 0 && range.end <= 360)
            #expect(range.start <= range.end)
        }
    }

    @Test func splitWrappedRangeStaysAsOneRangeWhenNotCrossingTheSeam() {
        let ranges = SolarPosition.splitWrappedRange(center: 180, halfWidth: 90)
        #expect(ranges.count == 1)
        #expect(ranges[0].start == 90)
        #expect(ranges[0].end == 270)
    }

    @Test func splitWrappedRangeSplitsInTwoWhenCrossingZero() {
        let ranges = SolarPosition.splitWrappedRange(center: 10, halfWidth: 90)
        #expect(ranges.count == 2)
        let totalWidth = ranges.reduce(0.0) { $0 + ($1.end - $1.start) }
        #expect(abs(totalWidth - 180) < 0.01)
        for range in ranges {
            #expect(range.start >= 0 && range.end <= 360)
        }
    }

    @Test func splitWrappedRangeSplitsInTwoWhenCrossingThreeSixty() {
        let ranges = SolarPosition.splitWrappedRange(center: 350, halfWidth: 90)
        #expect(ranges.count == 2)
        let totalWidth = ranges.reduce(0.0) { $0 + ($1.end - $1.start) }
        #expect(abs(totalWidth - 180) < 0.01)
        for range in ranges {
            #expect(range.start >= 0 && range.end <= 360)
        }
    }
}
