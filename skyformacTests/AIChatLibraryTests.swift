import Foundation
import Testing
@testable import skyformac

@MainActor
struct AIChatLibraryTests {
    private func makeLibrary() -> (library: AIChatLibrary, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (AIChatLibrary(rootDirectory: root), root)
    }

    @Test func creatingASessionPersistsItAndAutoTitlesFromTheFirstMessage() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = library.createSession(firstMessageText: "What can I see tonight?")

        #expect(session.title == "What can I see tonight?")
        #expect(library.sessions.count == 1)
        let reloaded = AIChatLibrary(rootDirectory: root)
        #expect(reloaded.sessions.first?.id == session.id)
        #expect(reloaded.sessions.first?.title == "What can I see tonight?")
    }

    @Test func creatingASessionWithNoFirstMessageUsesAGenericTitle() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = library.createSession()

        #expect(session.title == "New Chat")
    }

    @Test func aVeryLongFirstMessageIsTruncatedForTheTitle() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let longText = String(repeating: "a", count: 100)

        let session = library.createSession(firstMessageText: longText)

        #expect(session.title.count == 41) // 40 chars + the truncation ellipsis
        #expect(session.title.hasSuffix("…"))
    }

    @Test func savingUpdatesMessagesAndPersistsThemAcrossReload() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = library.createSession(firstMessageText: "Hello")
        session.messages = [AssistantMessage(role: .user, text: "Hello"), AssistantMessage(role: .assistant, text: "Hi there")]

        library.save(session)

        let reloaded = AIChatLibrary(rootDirectory: root)
        #expect(reloaded.sessions.first?.messages.count == 2)
        #expect(reloaded.sessions.first?.messages.last?.text == "Hi there")
    }

    @Test func deletingASessionRemovesItFromMemoryAndDisk() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = library.createSession(firstMessageText: "Delete me")

        library.delete(session.id)

        #expect(library.sessions.isEmpty)
        let reloaded = AIChatLibrary(rootDirectory: root)
        #expect(reloaded.sessions.isEmpty)
    }

    @Test func renamingUpdatesTheTitleWithoutTouchingMessages() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        var session = library.createSession(firstMessageText: "Original")
        session.messages = [AssistantMessage(role: .user, text: "Original")]
        library.save(session)

        library.rename(session.id, to: "My Chat")

        #expect(library.sessions.first?.title == "My Chat")
        #expect(library.sessions.first?.messages.count == 1)
    }

    @Test func sessionsAreOrderedMostRecentlyUpdatedFirst() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let older = library.createSession(firstMessageText: "Older")
        var olderUpdated = older
        olderUpdated.updatedDate = Date().addingTimeInterval(-100)
        library.save(olderUpdated)
        let newer = library.createSession(firstMessageText: "Newer")
        var newerUpdated = newer
        newerUpdated.updatedDate = Date()
        library.save(newerUpdated)

        #expect(library.sessions.first?.id == newer.id)
        #expect(library.sessions.last?.id == older.id)
    }

    @Test func sessionWithIDReturnsNilForAnUnknownOrNilID() throws {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(library.session(withID: nil) == nil)
        #expect(library.session(withID: UUID()) == nil)
    }
}
