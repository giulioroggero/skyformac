import Foundation
import Testing
@testable import skyformac

struct ObservationTimelineViewTests {
    private func date(_ secondsFromReference: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: secondsFromReference)
    }

    private func makeCapture(date: Date) -> CaptureRecord {
        CaptureRecord(date: date, fileName: "f-\(date.timeIntervalSinceReferenceDate).fits", kind: .fits)
    }

    private func makeProject(name: String, sessions: [Session]) -> Project {
        var project = Project.newProject(name: name)
        project.sessions = sessions
        return project
    }

    @Test func mergedEntriesInterleavesCapturesFromDifferentProjectsChronologically() {
        var sessionA = Session.newSession(name: "A")
        sessionA.captures = [makeCapture(date: date(300)), makeCapture(date: date(100))]
        var sessionB = Session.newSession(name: "B")
        sessionB.captures = [makeCapture(date: date(200))]

        let projects = [makeProject(name: "P1", sessions: [sessionA]), makeProject(name: "P2", sessions: [sessionB])]
        let entries = ObservationTimelineView.mergedEntries(from: projects)

        #expect(entries.map { $0.capture.date.timeIntervalSinceReferenceDate } == [100, 200, 300])
        // The middle entry (chronologically) came from the *other* project/session — confirming
        // captures are genuinely interleaved across projects, not grouped by project then sorted
        // within each.
        #expect(entries[1].project.name == "P2")
        #expect(entries[1].session.name == "B")
    }

    @Test func mergedEntriesIsEmptyForNoProjects() {
        #expect(ObservationTimelineView.mergedEntries(from: []).isEmpty)
    }

    @Test func dateRangeIsNilWhenThereAreNoEntries() {
        #expect(ObservationTimelineView.dateRange(for: []) == nil)
    }

    @Test func dateRangeSpansFirstToLastEntry() throws {
        var session = Session.newSession(name: "A")
        session.captures = [makeCapture(date: date(1000)), makeCapture(date: date(5000))]
        let entries = ObservationTimelineView.mergedEntries(from: [makeProject(name: "P", sessions: [session])])
        let range = try #require(ObservationTimelineView.dateRange(for: entries))
        #expect(range.lowerBound.timeIntervalSinceReferenceDate == 1000)
        #expect(range.upperBound.timeIntervalSinceReferenceDate == 5000)
    }

    @Test func dateRangeIsAtLeastAMinuteWideForASingleCapture() throws {
        var session = Session.newSession(name: "A")
        session.captures = [makeCapture(date: date(1000))]
        let entries = ObservationTimelineView.mergedEntries(from: [makeProject(name: "P", sessions: [session])])
        let range = try #require(ObservationTimelineView.dateRange(for: entries))
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == 60)
    }

    @Test func defaultPixelsPerHourIsNilRangeFallback() {
        #expect(ObservationTimelineView.defaultPixelsPerHour(for: nil) == 1400)
    }

    @Test func defaultPixelsPerHourScalesDownForALongRange() {
        // A one-year range should need far fewer pixels per hour than a one-hour range to land at
        // roughly the same total on-screen width.
        let oneHour = date(0)...date(3600)
        let oneYear = date(0)...date(3600 * 24 * 365)
        let hourly = ObservationTimelineView.defaultPixelsPerHour(for: oneHour)
        let yearly = ObservationTimelineView.defaultPixelsPerHour(for: oneYear)
        #expect(yearly < hourly)
        #expect(yearly > 0)
    }
}
