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

    @Test func showsTextIsAlwaysTrueForTheFirstVisibleEntry() {
        #expect(ObservationTimelineView.showsText(forVisibleIndices: [0], pixelsPerThumbnail: 10, columnWidth: 20) == [true])
    }

    @Test func showsTextIsTrueForEveryEntryWhenSpacingClearsTheColumnWidth() {
        #expect(
            ObservationTimelineView.showsText(forVisibleIndices: [0, 1, 2], pixelsPerThumbnail: 30, columnWidth: 20) == [true, true, true]
        )
    }

    @Test func showsTextAlternatesOnAFixedStrideWhenZoomedTighterThanTheColumnWidth() {
        // At half the column width per thumbnail, every other entry's text would collide with
        // its neighbor's — text shows on every 2nd entry (a fixed stride, not tied to real time).
        #expect(
            ObservationTimelineView.showsText(forVisibleIndices: [0, 1, 2, 3, 4], pixelsPerThumbnail: 10, columnWidth: 20)
                == [true, false, true, false, true]
        )
    }

    @Test func showsTextIsEmptyForNoVisibleIndices() {
        #expect(ObservationTimelineView.showsText(forVisibleIndices: [], pixelsPerThumbnail: 10, columnWidth: 20).isEmpty)
    }

    @Test func visibleIndicesShowsEveryEntryWhenSpacingClearsTheMinimum() {
        #expect(ObservationTimelineView.visibleIndices(count: 5, pixelsPerThumbnail: 30, minVisibleWidth: 25) == [0, 1, 2, 3, 4])
    }

    @Test func visibleIndicesHidesSomeThumbnailsWhenSpacingDropsBelowTheMinimum() {
        // At 5pt per thumbnail (well under the 25pt minimum), only every 5th thumbnail can get
        // its own real 25pt of space — the fix for "hide some images ... in order to keep the
        // min width of 25px."
        #expect(ObservationTimelineView.visibleIndices(count: 11, pixelsPerThumbnail: 5, minVisibleWidth: 25) == [0, 5, 10])
    }

    @Test func visibleIndicesAlwaysIncludesTheMostRecentEntry() {
        // 12 entries at a stride of 5 would naturally land on 0, 5, 10 — 11 (the most recent)
        // needs to be added on top so "jump to most recent" always has something real to select.
        #expect(ObservationTimelineView.visibleIndices(count: 12, pixelsPerThumbnail: 5, minVisibleWidth: 25) == [0, 5, 10, 11])
    }

    @Test func visibleIndicesIsEmptyForZeroEntries() {
        #expect(ObservationTimelineView.visibleIndices(count: 0, pixelsPerThumbnail: 5, minVisibleWidth: 25).isEmpty)
    }
}
