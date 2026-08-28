import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import skyformac

@MainActor
struct CameraManagerImportMediaTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (CameraManager(projectStore: ProjectStore(rootDirectory: root)), root)
    }

    private func makeProjectWithOneSession() -> (project: Project, session: Session) {
        var project = Project.newProject(name: "Import Test Project")
        let session = Session.newSession(name: "Night 1")
        project.sessions = [session]
        return (project, session)
    }

    /// A real, tiny, valid PNG — `CGImageRenderer.loadDisplayImage`/`ThumbnailGenerator` both need
    /// an actually-decodable file, not just a `.png`-named empty one.
    private func writeSamplePNG(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return url
    }

    @Test func importMediaCopiesSupportedFilesAndSkipsUnsupportedOnes() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        let png = try writeSamplePNG(named: "photo.png", in: sourceDir)
        let unsupported = sourceDir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: unsupported)

        let (project, session) = makeProjectWithOneSession()
        let result = await manager.importMedia(from: [png, unsupported], into: session, project: project)

        #expect(result.imported.count == 1)
        #expect(result.skipped == [unsupported])
        #expect(result.imported[0].kind == .png)

        let destinationURL = manager.projectStore.sessionFolderURL(for: session, in: project)
            .appendingPathComponent(result.imported[0].fileName)
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))
    }

    /// The reactivity fix this session established elsewhere: a page reading live from
    /// `projectsLibrary.projects` should see the newly-imported capture without needing to be
    /// reopened — which only holds if `importMedia` actually calls `projectsLibrary.save`, not
    /// just `ProjectStore`'s own disk-only save.
    @Test func importMediaUpdatesTheObservableProjectsLibraryNotJustDisk() async throws {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sourceDir) }
        let png = try writeSamplePNG(named: "photo.png", in: sourceDir)

        let (project, session) = makeProjectWithOneSession()
        _ = await manager.importMedia(from: [png], into: session, project: project)

        let updatedProject = manager.projectsLibrary.projects.first(where: { $0.id == project.id })
        let updatedSession = updatedProject?.sessions.first(where: { $0.id == session.id })
        #expect(updatedSession?.captures.count == 1)
    }

    @Test func importMediaReturnsEmptyWhenEveryURLIsUnsupported() async {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        let (project, session) = makeProjectWithOneSession()
        let unsupported = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).txt")

        let result = await manager.importMedia(from: [unsupported], into: session, project: project)
        #expect(result.imported.isEmpty)
        #expect(result.skipped == [unsupported])
    }
}
