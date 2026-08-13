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
}
