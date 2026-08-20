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

    @Test func compressedTotalHoursIsAtLeastTenthHourForFewerThanTwoEntries() {
        #expect(ObservationTimelineView.compressedTotalHours(for: []) == 0.1)
        var session = Session.newSession(name: "A")
        session.captures = [makeCapture(date: date(1000))]
        let entries = ObservationTimelineView.mergedEntries(from: [makeProject(name: "P", sessions: [session])])
        #expect(ObservationTimelineView.compressedTotalHours(for: entries) == 0.1)
    }

    @Test func compressedTotalHoursSumsGapsBelowTheCap() {
        // Two captures three hours apart — well under the 6-hour cap — should sum to exactly
        // that real gap, not get compressed.
        var session = Session.newSession(name: "A")
        session.captures = [makeCapture(date: date(0)), makeCapture(date: date(3 * 3600))]
        let entries = ObservationTimelineView.mergedEntries(from: [makeProject(name: "P", sessions: [session])])
        #expect(ObservationTimelineView.compressedTotalHours(for: entries) == 3)
    }

    @Test func compressedTotalHoursCapsALongQuietGap() {
        // A one-year gap between two captures should compress down to the 6-hour cap instead of
        // reporting ~8760 hours — the fix for "remove the empty spaces... compress the timeline
        // dynamically if there is no observation."
        var session = Session.newSession(name: "A")
        session.captures = [makeCapture(date: date(0)), makeCapture(date: date(3600 * 24 * 365))]
        let entries = ObservationTimelineView.mergedEntries(from: [makeProject(name: "P", sessions: [session])])
        #expect(ObservationTimelineView.compressedTotalHours(for: entries) == 6)
    }

    @Test func lanesPutsWidelySpacedEntriesInOneLane() {
        // At 10 px/hour with a 20-point column, offsets 0h and 10h are 100pt apart — nowhere
        // near overlapping — so both should land in the same (first) lane.
        let lanes = ObservationTimelineView.lanes(offsetsInHours: [0, 10], pixelsPerHour: 10, columnWidth: 20)
        #expect(lanes == [[0, 1]])
    }

    @Test func lanesSplitsOverlappingEntriesIntoSeparateLanes() {
        // At 10 px/hour with a 20-point column, offsets 0h and 1h are only 10pt apart — well
        // inside the 20pt column width — so the second entry must move to a new lane instead of
        // overlapping the first.
        let lanes = ObservationTimelineView.lanes(offsetsInHours: [0, 1], pixelsPerHour: 10, columnWidth: 20)
        #expect(lanes == [[0], [1]])
    }

    @Test func lanesReusesAnEarlierLaneOnceItsLastEntryClearsTheColumnWidth() {
        // Entry 1 overlaps entry 0 (forced into lane 1), but entry 2 is far enough past entry 0
        // that lane 0 is free again — it should reuse lane 0 rather than opening a third lane.
        let lanes = ObservationTimelineView.lanes(offsetsInHours: [0, 1, 10], pixelsPerHour: 10, columnWidth: 20)
        #expect(lanes == [[0, 2], [1]])
    }

    @Test func compressedOffsetsInHoursCapsEachGapIndependently() {
        // Three captures: a 2-hour gap, then a 10-hour (over-the-cap) gap — offsets should be
        // [0, 2, 2 + 6], not [0, 2, 12].
        var session = Session.newSession(name: "A")
        session.captures = [
            makeCapture(date: date(0)), makeCapture(date: date(2 * 3600)), makeCapture(date: date(12 * 3600)),
        ]
        let entries = ObservationTimelineView.mergedEntries(from: [makeProject(name: "P", sessions: [session])])
        #expect(ObservationTimelineView.compressedOffsetsInHours(for: entries) == [0, 2, 8])
    }
}
