import Foundation
import Testing
@testable import skyformac

struct ProjectSearchTests {
    private func makeProjects() -> [Project] {
        var messier = Project.newProject(name: "Messier Marathon", goal: "See as many Messier objects as possible")
        messier.tags = ["marathon", "deep-sky"]
        var night1 = Session.newSession(name: "Night 1", goal: "Open clusters", plannedObjects: ["M13", "M57"])
        night1.tags = ["favorites"]
        night1.notes = [Annotation(date: Date(), text: "Great seeing tonight")]
        messier.sessions = [night1]

        var saturn = Project.newProject(name: "Saturn Opposition", goal: "Track Saturn's rings closing")
        saturn.tags = ["planetary"]

        return [messier, saturn]
    }

    @Test func emptyTextMatchesEveryProjectAndSession() {
        let results = ProjectSearch.search(makeProjects(), text: "")
        // 2 projects + 1 session.
        #expect(results.count == 3)
    }

    @Test func matchesProjectNameCaseInsensitively() {
        let results = ProjectSearch.search(makeProjects(), text: "SATURN")
        #expect(results.count == 1)
        #expect(results.first?.project.name == "Saturn Opposition")
        #expect(results.first?.session == nil)
    }

    @Test func matchesProjectGoal() {
        let results = ProjectSearch.search(makeProjects(), text: "rings closing")
        #expect(results.map(\.project.name) == ["Saturn Opposition"])
    }

    @Test func matchesProjectTag() {
        let results = ProjectSearch.search(makeProjects(), text: "marathon")
        #expect(results.contains { $0.project.name == "Messier Marathon" && $0.session == nil })
    }

    @Test func matchesSessionPlannedObject() {
        let results = ProjectSearch.search(makeProjects(), text: "M57")
        // Matches both the session directly and its project (via Project.allPlannedObjects).
        #expect(results.count == 2)
        #expect(results.contains { $0.session?.name == "Night 1" })
        #expect(results.contains { $0.project.name == "Messier Marathon" && $0.session == nil })
    }

    @Test func matchesSessionTag() {
        let results = ProjectSearch.search(makeProjects(), text: "favorites")
        #expect(results.first?.session?.name == "Night 1")
    }

    @Test func matchesAnnotationText() {
        let results = ProjectSearch.search(makeProjects(), text: "great seeing")
        #expect(results.first?.session?.name == "Night 1")
    }

    @Test func noMatchReturnsEmpty() {
        #expect(ProjectSearch.search(makeProjects(), text: "nonexistent-object-xyz").isEmpty)
    }

    @Test func dateRangeExcludesProjectsOutsideIt() {
        var projects = makeProjects()
        projects[0].createdDate = Date(timeIntervalSince1970: 0)
        projects[1].createdDate = Date(timeIntervalSince1970: 1_000_000)
        projects[0].sessions[0].createdDate = Date(timeIntervalSince1970: 0)

        let range = Date(timeIntervalSince1970: 500_000)...Date(timeIntervalSince1970: 1_500_000)
        let results = ProjectSearch.search(projects, text: "", dateRange: range)
        #expect(results.count == 1)
        #expect(results.first?.project.name == "Saturn Opposition")
    }

    @Test func tagFilterIsExactCaseInsensitiveMatch() {
        let projects = makeProjects()
        // "marathon" is a full tag on the project; "Mara" is a substring that should NOT match,
        // since tag/object filters are exact (picked from a list), unlike free-text search.
        #expect(ProjectSearch.search(projects, text: "", tag: "MARATHON").contains { $0.project.name == "Messier Marathon" && $0.session == nil })
        #expect(ProjectSearch.search(projects, text: "", tag: "Mara").isEmpty)
        #expect(ProjectSearch.search(projects, text: "", tag: "favorites").contains { $0.session?.name == "Night 1" })
    }

    @Test func objectFilterIsExactCaseInsensitiveMatch() {
        let projects = makeProjects()
        let results = ProjectSearch.search(projects, text: "", object: "m57")
        #expect(results.contains { $0.session?.name == "Night 1" })
        #expect(ProjectSearch.search(projects, text: "", object: "M5").isEmpty)
    }

    @Test func equipmentFilterMatchesProjectsOwnAssignment() {
        var projects = makeProjects()
        let systemID = UUID()
        projects[1].equipmentSystemID = systemID

        let results = ProjectSearch.search(projects, text: "", equipmentSystemID: systemID)
        #expect(results.count == 1)
        #expect(results.first?.project.name == "Saturn Opposition")
    }

    @Test func equipmentFilterMatchesASessionsEffectiveSystemIncludingInherited() {
        var projects = makeProjects()
        let projectSystemID = UUID()
        let sessionSystemID = UUID()
        projects[0].equipmentSystemID = projectSystemID
        // Session 0 inherits the project's system (no override); add a second session that
        // overrides it with its own.
        var overriding = Session.newSession(name: "Night 2", goal: "", plannedObjects: [])
        overriding.equipmentSystemID = sessionSystemID
        projects[0].sessions.append(overriding)

        let inheritedResults = ProjectSearch.search(projects, text: "", equipmentSystemID: projectSystemID)
        #expect(inheritedResults.contains { $0.session?.name == "Night 1" })
        #expect(!inheritedResults.contains { $0.session?.name == "Night 2" })

        let overriddenResults = ProjectSearch.search(projects, text: "", equipmentSystemID: sessionSystemID)
        #expect(overriddenResults.contains { $0.session?.name == "Night 2" })
        #expect(!overriddenResults.contains { $0.session?.name == "Night 1" })
    }
}

struct SessionEffectiveEquipmentTests {
    @Test func sessionsOwnOverrideWinsOverProjects() {
        var project = Project.newProject(name: "P", goal: "")
        project.equipmentSystemID = UUID()
        var session = Session.newSession(name: "S", goal: "", plannedObjects: [])
        session.equipmentSystemID = UUID()

        #expect(session.effectiveEquipmentSystemID(inProject: project) == session.equipmentSystemID)
    }

    @Test func fallsBackToProjectsWhenSessionHasNone() {
        var project = Project.newProject(name: "P", goal: "")
        project.equipmentSystemID = UUID()
        let session = Session.newSession(name: "S", goal: "", plannedObjects: [])

        #expect(session.effectiveEquipmentSystemID(inProject: project) == project.equipmentSystemID)
    }

    @Test func nilWhenNeitherHasOne() {
        let project = Project.newProject(name: "P", goal: "")
        let session = Session.newSession(name: "S", goal: "", plannedObjects: [])

        #expect(session.effectiveEquipmentSystemID(inProject: project) == nil)
    }
}

struct ObservedObjectCatalogTests {
    @Test func includesPlanetaryPresets() {
        let names = ObservedObjectCatalog.allKnownObjectNames(projects: [])
        for preset in PlanetaryPreset.allCases {
            #expect(names.contains(preset.rawValue))
        }
    }

    @Test func includesBundledSkyCatalogObjects() {
        let names = ObservedObjectCatalog.allKnownObjectNames(projects: [])
        if let firstMessier = SkyCatalog.messierObjects.first {
            #expect(names.contains(firstMessier.displayName))
        }
        if let firstStar = SkyCatalog.brightStars.first {
            #expect(names.contains(firstStar.displayName))
        }
    }

    @Test func includesUserPlannedObjectsNotInEitherCatalog() {
        var project = Project.newProject(name: "P", goal: "")
        project.sessions = [Session.newSession(name: "S", goal: "", plannedObjects: ["Comet Custom-42"])]

        let names = ObservedObjectCatalog.allKnownObjectNames(projects: [project])
        #expect(names.contains("Comet Custom-42"))
    }

    @Test func namesAreDeduplicatedAndSorted() {
        let names = ObservedObjectCatalog.allKnownObjectNames(projects: [])
        #expect(names == Array(Set(names)).sorted())
    }
}
