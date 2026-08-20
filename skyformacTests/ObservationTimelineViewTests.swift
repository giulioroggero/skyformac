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

    @Test func defaultPixelsPerThumbnailFallsBackForFewerThanTwoEntries() {
        #expect(ObservationTimelineView.defaultPixelsPerThumbnail(count: 0) > 0)
        #expect(ObservationTimelineView.defaultPixelsPerThumbnail(count: 1) > 0)
    }

    @Test func defaultPixelsPerThumbnailScalesDownAsCaptureCountGrows() {
        // More thumbnails to fit into the same target width means each one gets less space —
        // "the scale of the timeline ... depends on how many thumbnails are present," not on how
        // much real time separates them.
        let few = ObservationTimelineView.defaultPixelsPerThumbnail(count: 10)
        let many = ObservationTimelineView.defaultPixelsPerThumbnail(count: 1000)
        #expect(many < few)
        #expect(many > 0)
    }

    @Test func showsTextIsAlwaysTrueForTheFirstEntry() {
        #expect(ObservationTimelineView.showsText(count: 1, pixelsPerThumbnail: 10, columnWidth: 20) == [true])
    }

    @Test func showsTextIsTrueForEveryEntryWhenSpacingClearsTheColumnWidth() {
        #expect(
            ObservationTimelineView.showsText(count: 3, pixelsPerThumbnail: 30, columnWidth: 20) == [true, true, true]
        )
    }

    @Test func showsTextAlternatesOnAFixedStrideWhenZoomedTighterThanTheColumnWidth() {
        // At half the column width per thumbnail, every other entry's text would collide with
        // its neighbor's — text shows on every 2nd entry (a fixed stride, not tied to real time).
        #expect(
            ObservationTimelineView.showsText(count: 5, pixelsPerThumbnail: 10, columnWidth: 20) == [true, false, true, false, true]
        )
    }

    @Test func showsTextIsEmptyForNoEntries() {
        #expect(ObservationTimelineView.showsText(count: 0, pixelsPerThumbnail: 10, columnWidth: 20).isEmpty)
    }
}
