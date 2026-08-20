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

    @Test func showsTextIsAlwaysTrueForTheFirstEntry() {
        #expect(ObservationTimelineView.showsText(offsetsInHours: [0], pixelsPerHour: 10) == [true])
    }

    @Test func showsTextIsTrueWhenEntriesAreWellSpacedApart() {
        // At 10 px/hour, a 10-hour gap is 100pt — comfortably past the ~88pt column width — so
        // both entries should show their text.
        #expect(ObservationTimelineView.showsText(offsetsInHours: [0, 10], pixelsPerHour: 10) == [true, true])
    }

    @Test func showsTextIsFalseWhenTwoEntriesWouldCollide() {
        // At 10 px/hour, a 1-hour gap is only 10pt — well inside the column width — so the
        // second entry's text (the one that would land on top of the first's) is suppressed,
        // while its thumbnail image still renders (just without the label underneath).
        #expect(ObservationTimelineView.showsText(offsetsInHours: [0, 1], pixelsPerHour: 10) == [true, false])
    }

    @Test func showsTextChainsSoAFarEnoughEntryShowsAgainEvenAfterACrowdedRun() {
        // Entry 1 is too close to entry 0 (hidden), but entry 2 is far enough past entry 0 (and
        // therefore also far enough past entry 1, since positions only increase) to show again.
        #expect(ObservationTimelineView.showsText(offsetsInHours: [0, 1, 10], pixelsPerHour: 10) == [true, false, true])
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
