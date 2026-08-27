import Foundation
import Testing
@testable import skyformac

/// `DashboardHomeView.buildLast30DaysActivity(from:endingToday:)` — the Home page's "must be per
/// day, last 30 days" activity chart, pulled out as its own pure function (same reasoning as
/// `MonthlyActivity`/`InsightsDrillLevel`'s own dedicated coverage) so its bucketing is testable
/// without hosting the view.
struct DashboardHomeViewTests {
    private static let calendar = Calendar.current

    @Test func coversExactlyThirtyDaysEndingToday() {
        let now = Date()
        let buckets = DashboardHomeView.buildLast30DaysActivity(from: [], endingToday: now)
        #expect(buckets.count == 30)
        #expect(buckets.last?.day == Self.calendar.startOfDay(for: now))
        let expectedFirst = Self.calendar.date(byAdding: .day, value: -29, to: Self.calendar.startOfDay(for: now))
        #expect(buckets.first?.day == expectedFirst)
    }

    @Test func everyDayAppearsEvenWithNoActivity() {
        let buckets = DashboardHomeView.buildLast30DaysActivity(from: [], endingToday: Date())
        #expect(buckets.allSatisfy { $0.count == 0 })
    }

    @Test func groupsMultipleCapturesOnTheSameDayIntoOneBucket() {
        let now = Date()
        let today = Self.calendar.startOfDay(for: now)
        let morning = Self.calendar.date(byAdding: .hour, value: 9, to: today)!
        let evening = Self.calendar.date(byAdding: .hour, value: 21, to: today)!
        let buckets = DashboardHomeView.buildLast30DaysActivity(from: [morning, evening], endingToday: now)
        #expect(buckets.last?.count == 2)
    }

    /// A capture from before the 30-day window shouldn't silently inflate the oldest bucket shown
    /// — it should just not appear at all.
    @Test func capturesOutsideTheWindowAreExcluded() {
        let now = Date()
        let tooOld = Self.calendar.date(byAdding: .day, value: -40, to: now)!
        let buckets = DashboardHomeView.buildLast30DaysActivity(from: [tooOld], endingToday: now)
        #expect(buckets.allSatisfy { $0.count == 0 })
    }
}
