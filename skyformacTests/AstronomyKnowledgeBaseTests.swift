import Foundation
import Testing
@testable import skyformac

struct AstronomyKnowledgeBaseTests {
    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    @Test func ensureDefaultsExistWritesEveryDefaultFileToAnEmptyDirectory() {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        AstronomyKnowledgeBase.ensureDefaultsExist(in: root)

        for file in AstronomyKnowledgeBase.defaultFiles {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(file.name).path))
        }
    }

    @Test func ensureDefaultsExistNeverOverwritesAFileTheUserHasAlreadyEdited() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let firstDefault = AstronomyKnowledgeBase.defaultFiles[0]
        let editedURL = root.appendingPathComponent(firstDefault.name)
        try Data("My own edited notes.".utf8).write(to: editedURL)

        AstronomyKnowledgeBase.ensureDefaultsExist(in: root)

        let contents = try String(contentsOf: editedURL, encoding: .utf8)
        #expect(contents == "My own edited notes.")
    }

    @Test func restoreDefaultsOverwritesAnEditedDefaultFileBackToItsOriginalContent() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        AstronomyKnowledgeBase.ensureDefaultsExist(in: root)
        let firstDefault = AstronomyKnowledgeBase.defaultFiles[0]
        let editedURL = root.appendingPathComponent(firstDefault.name)
        try Data("Something the user changed.".utf8).write(to: editedURL)

        AstronomyKnowledgeBase.restoreDefaults(in: root)

        let contents = try String(contentsOf: editedURL, encoding: .utf8)
        #expect(contents == firstDefault.content)
    }

    @Test func restoreDefaultsLeavesAUserAddedFileUntouched() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        AstronomyKnowledgeBase.ensureDefaultsExist(in: root)
        let customURL = root.appendingPathComponent("my-own-notes.md")
        try Data("Custom local site notes.".utf8).write(to: customURL)

        AstronomyKnowledgeBase.restoreDefaults(in: root)

        let contents = try String(contentsOf: customURL, encoding: .utf8)
        #expect(contents == "Custom local site notes.")
    }

    @Test func contextTextConcatenatesEveryMarkdownFileInTheDirectory() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("Alpha content.".utf8).write(to: root.appendingPathComponent("alpha.md"))
        try Data("Beta content.".utf8).write(to: root.appendingPathComponent("beta.md"))
        try Data("not markdown".utf8).write(to: root.appendingPathComponent("ignored.txt"))

        let text = AstronomyKnowledgeBase.contextText(in: root)

        #expect(text.contains("Alpha content."))
        #expect(text.contains("Beta content."))
        #expect(!text.contains("not markdown"))
    }

    @Test func contextTextReturnsEmptyStringForAMissingDirectory() {
        let root = makeTempDirectory()

        let text = AstronomyKnowledgeBase.contextText(in: root)

        #expect(text.isEmpty)
    }

    @Test func contextTextIsCappedAtTheGivenCharacterLimit() throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(String(repeating: "x", count: 10_000).utf8).write(to: root.appendingPathComponent("huge.md"))

        let text = AstronomyKnowledgeBase.contextText(in: root, characterLimit: 500)

        #expect(text.count <= 500)
    }
}
