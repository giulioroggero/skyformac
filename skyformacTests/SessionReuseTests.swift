import Foundation
import Testing
@testable import skyformac

struct SessionReuseTests {
    @Test func duplicatedForReuseCopiesSetupNotHistory() {
        var original = Session.newSession(name: "Original", goal: "See M13", plannedObjects: ["M13", "M57"])
        original.location = GeoLocation(latitude: 45, longitude: 9, name: "Backyard", source: .manual)
        original.tags = ["favorites"]
        original.equipmentSystemID = UUID()
        original.notes = [Annotation(date: Date(), text: "Great night")]
        original.captures = [CaptureRecord(date: Date(), fileName: "a.fits", kind: .fits)]

        let copy = original.duplicatedForReuse(name: "New Session")

        #expect(copy.name == "New Session")
        #expect(copy.goal == original.goal)
        #expect(copy.plannedObjects == original.plannedObjects)
        #expect(copy.location == original.location)
        #expect(copy.tags == original.tags)
        #expect(copy.equipmentSystemID == original.equipmentSystemID)
        #expect(copy.notes.isEmpty)
        #expect(copy.captures.isEmpty)
        #expect(copy.id != original.id)
        #expect(copy.folderName != original.folderName)
    }

    @Test func duplicatedForReusePassesThroughPlannedDate() {
        let original = Session.newSession(name: "Original")
        let plannedDate = Date(timeIntervalSince1970: 1_000_000)

        let copy = original.duplicatedForReuse(name: "New Session", plannedDate: plannedDate)

        #expect(copy.plannedDate == plannedDate)
    }

    @Test func effectiveLocationPrefersSessionOverProject() {
        var project = Project.newProject(name: "P")
        project.location = GeoLocation(latitude: 1, longitude: 1, name: "Project Spot", source: .manual)
        var session = Session.newSession(name: "S")
        session.location = GeoLocation(latitude: 2, longitude: 2, name: "Session Spot", source: .manual)

        #expect(session.effectiveLocation(inProject: project)?.name == "Session Spot")
    }

    @Test func effectiveLocationFallsBackToProject() {
        var project = Project.newProject(name: "P")
        project.location = GeoLocation(latitude: 1, longitude: 1, name: "Project Spot", source: .manual)
        let session = Session.newSession(name: "S")

        #expect(session.effectiveLocation(inProject: project)?.name == "Project Spot")
    }

    @Test func effectiveLocationNilWhenNeitherHasOne() {
        let project = Project.newProject(name: "P")
        let session = Session.newSession(name: "S")

        #expect(session.effectiveLocation(inProject: project) == nil)
    }
}
