import Foundation
import Testing
@testable import skyformac

struct InsightsDrillLevelTests {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    @Test func yearLevelGroupsByCalendarYearAndOmitsYearsWithNoActivity() {
        let dates = [date(2024, 1, 1), date(2024, 6, 1), date(2026, 3, 1)]
        let buckets = DrillLevel.year.bucket(dates)
        #expect(buckets.map(\.label) == ["2024", "2026"])
        #expect(buckets.map(\.count) == [2, 1])
        #expect(buckets.map(\.component) == [2024, 2026])
    }

    @Test func monthLevelScopesToTheGivenYearAndZeroFillsAllTwelveMonths() {
        let dates = [date(2026, 1, 5), date(2026, 8, 1), date(2026, 8, 2), date(2025, 8, 1)]
        let buckets = DrillLevel.month(year: 2026).bucket(dates)
        #expect(buckets.count == 12)
        #expect(buckets[0].count == 1) // January
        #expect(buckets[7].count == 2) // August
        #expect(buckets[7].component == 8)
        #expect(buckets[1].count == 0) // February — no activity, still present
    }

    @Test func dayLevelScopesToTheGivenMonthAndCoversEveryDayInIt() {
        let dates = [date(2026, 2, 1), date(2026, 2, 14), date(2026, 2, 14)]
        // 2026 is not a leap year — February has 28 days.
        let buckets = DrillLevel.day(year: 2026, month: 2).bucket(dates)
        #expect(buckets.count == 28)
        #expect(buckets[0].count == 1)
        #expect(buckets[13].count == 2) // the 14th
        #expect(buckets[13].component == 14)
    }

    @Test func dayLevelHandlesALeapFebruary() {
        let buckets = DrillLevel.day(year: 2024, month: 2).bucket([])
        #expect(buckets.count == 29)
    }

    @Test func hourLevelScopesToOneSpecificCalendarDayAndCoversAll24Hours() {
        let dates = [date(2026, 8, 16, 14, 5), date(2026, 8, 16, 14, 45), date(2026, 8, 17, 14, 0)]
        let buckets = DrillLevel.hour(year: 2026, month: 8, day: 16).bucket(dates)
        #expect(buckets.count == 24)
        #expect(buckets[14].count == 2) // the 17th's 14:00 capture is excluded
        #expect(buckets[14].component == 14)
        #expect(buckets[0].count == 0)
    }

    @Test func minuteLevelScopesToOneSpecificHourAndCoversAll60Minutes() {
        let dates = [date(2026, 8, 16, 14, 5), date(2026, 8, 16, 14, 5), date(2026, 8, 16, 15, 5)]
        let buckets = DrillLevel.minute(year: 2026, month: 8, day: 16, hour: 14).bucket(dates)
        #expect(buckets.count == 60)
        #expect(buckets[5].count == 2) // the 15:05 capture is excluded (different hour)
        #expect(buckets[5].component == 5)
    }

    @Test func drillingWalksYearToMonthToDayToHourToMinuteThenStops() {
        let yearBucket = ActivityBucket(sortKey: 2026, label: "2026", count: 1, component: 2026)
        guard case .month(let year)? = DrillLevel.year.drilling(into: yearBucket) else {
            Issue.record("expected .month")
            return
        }
        #expect(year == 2026)

        let monthBucket = ActivityBucket(sortKey: 8, label: "Aug", count: 1, component: 8)
        guard case .day(let y, let m)? = DrillLevel.month(year: 2026).drilling(into: monthBucket) else {
            Issue.record("expected .day")
            return
        }
        #expect((y, m) == (2026, 8))

        let dayBucket = ActivityBucket(sortKey: 16, label: "16", count: 1, component: 16)
        guard case .hour(let y2, let m2, let d)? = DrillLevel.day(year: 2026, month: 8).drilling(into: dayBucket) else {
            Issue.record("expected .hour")
            return
        }
        #expect((y2, m2, d) == (2026, 8, 16))

        let hourBucket = ActivityBucket(sortKey: 14, label: "14", count: 1, component: 14)
        guard case .minute(let y3, let m3, let d3, let h)? = DrillLevel.hour(year: 2026, month: 8, day: 16).drilling(into: hourBucket) else {
            Issue.record("expected .minute")
            return
        }
        #expect((y3, m3, d3, h) == (2026, 8, 16, 14))

        let minuteBucket = ActivityBucket(sortKey: 5, label: "5", count: 1, component: 5)
        #expect(DrillLevel.minute(year: 2026, month: 8, day: 16, hour: 14).drilling(into: minuteBucket) == nil)
    }

    @Test func isDeepestIsTrueOnlyForMinute() {
        #expect(!DrillLevel.year.isDeepest)
        #expect(!DrillLevel.month(year: 2026).isDeepest)
        #expect(!DrillLevel.day(year: 2026, month: 8).isDeepest)
        #expect(!DrillLevel.hour(year: 2026, month: 8, day: 16).isDeepest)
        #expect(DrillLevel.minute(year: 2026, month: 8, day: 16, hour: 14).isDeepest)
    }

    @Test func breadcrumbTrailBuildsTheFullPathFromRoot() {
        let trail = DrillLevel.hour(year: 2026, month: 8, day: 16).breadcrumbTrail
        #expect(trail.map(\.title) == ["All Time", "2026", "August", "16"])
    }
}
