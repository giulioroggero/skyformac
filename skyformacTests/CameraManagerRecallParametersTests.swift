import Foundation
import Testing
@testable import skyformac

@MainActor
struct CameraManagerRecallParametersTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (CameraManager(projectStore: ProjectStore(rootDirectory: root)), root)
    }

    @Test func recallParametersHoldsPendingWhenNoCameraConnected() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let preset = AcquisitionPreset(name: "Test", targetID: "", mode: .liveStack, gain: 150, isDriftReductionEnabled: false, isSmartLiveStackEnabled: false)

        manager.recallParameters(preset)

        #expect(manager.pendingAcquisitionPreset == preset)
    }

    @Test func quickStartForObjectNameResolvesAMatchingCuratedTarget() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = AcquisitionTarget.deepSky(.m13)

        let session = manager.quickStart(forObjectName: target.name)

        #expect(session.plannedObjects == [target.name])
        #expect(manager.pendingAcquisitionPreset?.mode == target.recommendedMode)
    }

    @Test func quickStartForObjectNameFallsBackToAPlainSessionWhenNoTargetMatches() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = manager.quickStart(forObjectName: "Comet Custom-42")

        #expect(session.plannedObjects == ["Comet Custom-42"])
        #expect(manager.activeProject?.name == "Comet Custom-42")
        #expect(manager.pendingAcquisitionPreset == nil)
    }
}
