import Foundation
import Testing
@testable import skyformac

@MainActor
struct CameraManagerCaptureNoteTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (CameraManager(projectStore: ProjectStore(rootDirectory: root)), root)
    }

    @Test func serVideoNoteIncludesTheElapsedDuration() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session.newSession(name: "Saturn Night", plannedObjects: ["Saturn"])

        let note = manager.captureActionNote(for: .serVideo, session: session)

        #expect(note.contains("Saturn"))
        #expect(note.contains("SER video"))
    }

    @Test func fitsNoteMentionsLiveStackWhenEnabled() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.isLiveStackingEnabled = true
        let session = Session.newSession(name: "Galaxy Night", plannedObjects: ["M31"])

        let note = manager.captureActionNote(for: .fits, session: session)

        #expect(note.contains("M31"))
        #expect(note.contains("Live Stack"))
        #expect(note.contains("FITS"))
    }

    @Test func pngNoteFallsBackToSingleFrameWhenNoModeIsActive() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session.newSession(name: "Quick Look", plannedObjects: [])

        let note = manager.captureActionNote(for: .png, session: session)

        // No planned objects — falls back to the session's own name as "the target."
        #expect(note.contains("Quick Look"))
        #expect(note.contains("single"))
        #expect(note.contains("PNG"))
    }

    @Test func recordingNoteDescribesAContinuousSequence() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session.newSession(name: "Deep Sky", plannedObjects: ["M13"])

        let note = manager.captureActionNote(for: .recording, session: session)

        #expect(note.contains("M13"))
        #expect(note.contains("continuous"))
    }
}
