import Foundation
import Observation

/// Every saved AI chat conversation — one plain JSON file per session on disk, the same
/// "small dataset, no database needed, trivially inspectable/backupable" shape `EquipmentLibrary`
/// already uses for equipment systems. Lets the user "create a new AI session and see the
/// history, recalling and continuing a conversation" instead of the app holding exactly one
/// forever-growing, unsaved conversation in memory.
@Observable
@MainActor
final class AIChatLibrary {
    let rootDirectory: URL
    private let fileManager: FileManager
    private(set) var sessions: [AIChatSession] = []

    init(rootDirectory: URL = AIChatLibrary.defaultRootDirectory(), fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        sessions = Self.loadAll(from: rootDirectory, fileManager: fileManager)
    }

    /// A user-chosen folder (`AppSettings.customAIChatsDirectoryPath`, set via Settings) takes
    /// priority over `~/Documents/Skyformac AI Chats` when one's actually been set — same
    /// "read once at launch" shape `ProjectStore`/`EquipmentLibrary` already use for their own
    /// folders.
    static func defaultRootDirectory() -> URL {
        AppSettings.resolveRootDirectory(customPath: AppSettings.customAIChatsDirectoryPath, defaultFolderName: "Skyformac AI Chats")
    }

    @discardableResult
    func createSession(firstMessageText: String? = nil) -> AIChatSession {
        let session = AIChatSession.newSession(firstMessageText: firstMessageText)
        sessions.insert(session, at: 0)
        persist(session)
        return session
    }

    func save(_ session: AIChatSession) {
        replace(session)
        resort()
        persist(session)
    }

    func delete(_ id: AIChatSession.ID) {
        sessions.removeAll { $0.id == id }
        try? fileManager.removeItem(at: fileURL(forID: id))
    }

    func session(withID id: AIChatSession.ID?) -> AIChatSession? {
        guard let id else { return nil }
        return sessions.first { $0.id == id }
    }

    func rename(_ id: AIChatSession.ID, to title: String) {
        guard var session = session(withID: id) else { return }
        session.title = title
        save(session)
    }

    private func replace(_ session: AIChatSession) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }

    /// Most-recently-updated first — what the AI panel's history menu shows, so continuing an
    /// old conversation is always near the top instead of buried under creation order.
    private func resort() {
        sessions.sort { $0.updatedDate > $1.updatedDate }
    }

    /// Keyed purely by `id`, never the (freely-editable) title — same reasoning
    /// `EquipmentLibrary.fileURL(for:)` already documents for its own systems.
    private func fileURL(forID id: AIChatSession.ID) -> URL {
        rootDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    private func persist(_ session: AIChatSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(session) else { return }
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(forID: session.id))
    }

    private static func loadAll(from directory: URL, fileManager: FileManager) -> [AIChatSession] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(AIChatSession.self, from: $0) } }
            .sorted { $0.updatedDate > $1.updatedDate }
    }
}
