import Foundation
import Testing
@testable import skyformac

struct InsightsDataTests {
    private func makePreset(mode: AcquisitionMode) -> AcquisitionPreset {
        AcquisitionPreset(name: "", targetID: "", mode: mode, isDriftReductionEnabled: false, isSmartLiveStackEnabled: false)
    }

    private func makeCapture(object: String?, equipmentSystemID: UUID?, mode: AcquisitionMode?, date: Date) -> CaptureRecord {
        CaptureRecord(
            date: date, fileName: "f.fits", kind: .fits, object: object, equipmentSystemID: equipmentSystemID,
            preset: mode.map(makePreset)
        )
    }

    @Test func emptyProjectsProduceEmptyData() {
        let data = InsightsData.build(projects: [], equipmentSystems: [], knownObjects: ["Saturn"], now: Date())
        #expect(data.totalProjects == 0)
        #expect(data.totalCaptures == 0)
        #expect(data.suggestedNextObjects == ["Saturn"])
    }

    @Test func countsProjectsSessionsAndCaptures() {
        var project = Project.newProject(name: "P")
        var session = Session.newSession(name: "S")
        session.captures = [
            makeCapture(object: "Saturn", equipmentSystemID: nil, mode: .luckyImaging, date: Date()),
            makeCapture(object: "Saturn", equipmentSystemID: nil, mode: .luckyImaging, date: Date()),
        ]
        project.sessions = [session]

        let data = InsightsData.build(projects: [project], equipmentSystems: [], knownObjects: [], now: Date())
        #expect(data.totalProjects == 1)
        #expect(data.totalSessions == 1)
        #expect(data.totalCaptures == 2)
    }

    @Test func byObjectCountsAndSortsDescending() {
        var project = Project.newProject(name: "P")
        var session = Session.newSession(name: "S")
        session.captures = [
            makeCapture(object: "Saturn", equipmentSystemID: nil, mode: nil, date: Date()),
            makeCapture(object: "Saturn", equipmentSystemID: nil, mode: nil, date: Date()),
            makeCapture(object: "M13", equipmentSystemID: nil, mode: nil, date: Date()),
        ]
        project.sessions = [session]

        let data = InsightsData.build(projects: [project], equipmentSystems: [], knownObjects: [], now: Date())
        #expect(data.byObject.first?.name == "Saturn")
        #expect(data.byObject.first?.count == 2)
        #expect(data.byObject.last?.name == "M13")
    }

    @Test func byEquipmentSystemResolvesNamesFromIDs() {
        let system = EquipmentSystem.newSystem(name: "Backyard Rig")
        var project = Project.newProject(name: "P")
        var session = Session.newSession(name: "S")
        session.captures = [makeCapture(object: nil, equipmentSystemID: system.id, mode: nil, date: Date())]
        project.sessions = [session]

        let data = InsightsData.build(projects: [project], equipmentSystems: [system], knownObjects: [], now: Date())
        #expect(data.byEquipmentSystem == [NamedCount(name: "Backyard Rig", count: 1)])
    }

    @Test func byAcquisitionModeGroupsByPresetMode() {
        var project = Project.newProject(name: "P")
        var session = Session.newSession(name: "S")
        session.captures = [
            makeCapture(object: nil, equipmentSystemID: nil, mode: .liveStack, date: Date()),
            makeCapture(object: nil, equipmentSystemID: nil, mode: .luckyImaging, date: Date()),
        ]
        project.sessions = [session]

        let data = InsightsData.build(projects: [project], equipmentSystems: [], knownObjects: [], now: Date())
        #expect(Set(data.byAcquisitionMode.map(\.name)) == [AcquisitionMode.liveStack.label, AcquisitionMode.luckyImaging.label])
    }

    @Test func suggestedNextObjectsExcludesAlreadyCapturedCaseInsensitively() {
        var project = Project.newProject(name: "P")
        var session = Session.newSession(name: "S")
        session.captures = [makeCapture(object: "saturn", equipmentSystemID: nil, mode: nil, date: Date())]
        project.sessions = [session]

        let data = InsightsData.build(projects: [project], equipmentSystems: [], knownObjects: ["Saturn", "M13"], now: Date())
        #expect(data.suggestedNextObjects == ["M13"])
    }

    @Test func monthlyActivityBucketsByCalendarMonth() {
        let calendar = Calendar.current
        let januaryDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        let februaryDate = calendar.date(from: DateComponents(year: 2026, month: 2, day: 10))!
        var project = Project.newProject(name: "P")
        var session = Session.newSession(name: "S")
        session.captures = [
            makeCapture(object: nil, equipmentSystemID: nil, mode: nil, date: januaryDate),
            makeCapture(object: nil, equipmentSystemID: nil, mode: nil, date: februaryDate),
        ]
        project.sessions = [session]

        let data = InsightsData.build(projects: [project], equipmentSystems: [], knownObjects: [], now: Date())
        #expect(data.monthlyActivity.count == 2)
        #expect(data.monthlyActivity.allSatisfy { $0.count == 1 })
        #expect(data.monthlyActivity == data.monthlyActivity.sorted { $0.month < $1.month })
    }
}
