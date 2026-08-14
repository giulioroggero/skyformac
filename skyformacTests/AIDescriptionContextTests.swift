import Foundation
import Testing
@testable import skyformac

struct AIDescriptionContextTests {
    @Test func forProjectIncludesNameGoalLocationAndTags() {
        var project = Project.newProject(name: "Messier Marathon", goal: "See as many as possible")
        project.location = GeoLocation(latitude: 45, longitude: 8, name: "Orta San Giulio", source: .manual)
        project.tags = ["marathon"]

        let context = AIDescriptionContext.forProject(project) { _ in nil }

        #expect(context.contains("Messier Marathon"))
        #expect(context.contains("See as many as possible"))
        #expect(context.contains("Orta San Giulio"))
        #expect(context.contains("marathon"))
    }

    @Test func forProjectResolvesEquipmentNameFromID() {
        var project = Project.newProject(name: "P")
        let equipmentID = UUID()
        project.equipmentSystemID = equipmentID

        let context = AIDescriptionContext.forProject(project) { id in id == equipmentID ? "Backyard Rig" : nil }

        #expect(context.contains("Backyard Rig"))
    }

    @Test func forProjectListsEverySessionWithItsObjectsAndCaptureCount() {
        var project = Project.newProject(name: "P")
        var session = Session.newSession(name: "Night 1", plannedObjects: ["M13"])
        session.captures = [CaptureRecord(date: Date(), fileName: "a.fits", kind: .fits)]
        project.sessions = [session]

        let context = AIDescriptionContext.forProject(project) { _ in nil }

        #expect(context.contains("Night 1"))
        #expect(context.contains("M13"))
        #expect(context.contains("1 captures"))
    }

    @Test func forProjectReportsNoSessionsWhenThereAreNone() {
        let project = Project.newProject(name: "P")
        let context = AIDescriptionContext.forProject(project) { _ in nil }
        #expect(context.contains("No sessions yet"))
    }

    @Test func forSessionIncludesPlannedObjectsAndProjectName() {
        let project = Project.newProject(name: "Messier Marathon")
        let session = Session.newSession(name: "Night 1", goal: "See clusters", plannedObjects: ["M13", "M57"])

        let context = AIDescriptionContext.forSession(session, project: project) { _ in nil }

        #expect(context.contains("Night 1"))
        #expect(context.contains("Messier Marathon"))
        #expect(context.contains("See clusters"))
        #expect(context.contains("M13"))
        #expect(context.contains("M57"))
    }

    @Test func forSessionReportsCapturedObjectsAndPerKindBreakdown() {
        let project = Project.newProject(name: "P")
        var session = Session.newSession(name: "Night 1")
        session.captures = [
            CaptureRecord(date: Date(timeIntervalSince1970: 0), fileName: "a.fits", kind: .fits, object: "M13"),
            CaptureRecord(date: Date(timeIntervalSince1970: 100), fileName: "b.fits", kind: .fits, object: "M13"),
            CaptureRecord(date: Date(timeIntervalSince1970: 200), fileName: "c.png", kind: .png, object: "M57"),
        ]

        let context = AIDescriptionContext.forSession(session, project: project) { _ in nil }

        #expect(context.contains("M13"))
        #expect(context.contains("M57"))
        #expect(context.contains("FITS: 2"))
        #expect(context.contains("PNG: 1"))
    }

    @Test func forSessionReportsNoCapturesWhenThereAreNone() {
        let project = Project.newProject(name: "P")
        let session = Session.newSession(name: "Night 1")
        let context = AIDescriptionContext.forSession(session, project: project) { _ in nil }
        #expect(context.contains("No captures yet"))
    }

    @Test func forSessionUsesEffectiveLocationAndEquipmentInheritedFromProject() {
        var project = Project.newProject(name: "P")
        project.location = GeoLocation(latitude: 1, longitude: 1, name: "Backyard", source: .manual)
        let equipmentID = UUID()
        project.equipmentSystemID = equipmentID
        let session = Session.newSession(name: "Night 1")

        let context = AIDescriptionContext.forSession(session, project: project) { id in id == equipmentID ? "Backyard Rig" : nil }

        #expect(context.contains("Backyard"))
        #expect(context.contains("Backyard Rig"))
    }

    @Test func forSessionIncludesExistingNotes() {
        let project = Project.newProject(name: "P")
        var session = Session.newSession(name: "Night 1")
        session.notes = [Annotation(date: Date(), text: "Great seeing tonight")]

        let context = AIDescriptionContext.forSession(session, project: project) { _ in nil }

        #expect(context.contains("Great seeing tonight"))
    }
}
