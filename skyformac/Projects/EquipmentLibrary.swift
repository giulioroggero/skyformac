import Foundation
import Observation

/// The whole app's named equipment systems — one plain JSON file per system on disk, the same
/// "small dataset, no database needed, trivially inspectable/backupable" reasoning `ProjectStore`
/// already uses for Projects, just without the folder-per-item nesting (a handful of named rigs
/// doesn't need its own subfolder each). Previously backed by `AppSettings.equipmentSystems`
/// (`UserDefaults`) — "the equipments are not persisted on files, persist it" — moved to real
/// files specifically so equipment survives an app reinstall/`defaults delete`, can be backed up
/// or synced the same way Projects already are, and is inspectable outside the app. Mirrors
/// `ProjectsLibrary`'s "centralize CRUD, don't have views juggle raw persistence" shape.
@Observable
@MainActor
final class EquipmentLibrary {
    let rootDirectory: URL
    private let fileManager: FileManager
    private(set) var systems: [EquipmentSystem] = []

    init(rootDirectory: URL = EquipmentLibrary.defaultRootDirectory(), fileManager: FileManager = .default) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        systems = Self.loadAll(from: rootDirectory, fileManager: fileManager)
        migrateFromUserDefaultsIfNeeded()
    }

    /// A user-chosen folder (`AppSettings.customEquipmentDirectoryPath`, set via Settings) takes
    /// priority over `~/Documents/Skyformac Equipment` when one's actually been set — same
    /// "read once at launch" shape `ProjectStore.defaultRootDirectory()` already uses for the
    /// Projects folder.
    static func defaultRootDirectory() -> URL {
        if let customPath = AppSettings.customEquipmentDirectoryPath, !customPath.isEmpty {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent("Skyformac Equipment", isDirectory: true)
    }

    @discardableResult
    func createSystem(name: String) -> EquipmentSystem {
        let system = EquipmentSystem.newSystem(name: name)
        systems.insert(system, at: 0)
        persist(system)
        return system
    }

    func save(_ system: EquipmentSystem) {
        replace(system)
        persist(system)
    }

    func delete(_ system: EquipmentSystem) {
        systems.removeAll { $0.id == system.id }
        try? fileManager.removeItem(at: fileURL(for: system))
    }

    /// `nil` for `nil` input (the common "no equipment assigned" case) or an ID that no longer
    /// matches any system (one that was since deleted) — callers treat both the same way, as
    /// "nothing to show."
    func system(withID id: EquipmentSystem.ID?) -> EquipmentSystem? {
        guard let id else { return nil }
        return systems.first { $0.id == id }
    }

    private func replace(_ system: EquipmentSystem) {
        if let index = systems.firstIndex(where: { $0.id == system.id }) {
            systems[index] = system
        } else {
            systems.insert(system, at: 0)
        }
    }

    /// Keyed purely by `id`, not the system's (freely-editable) `name` — the same "renaming never
    /// moves anything on disk" reasoning `Project`/`Session`'s own `folderName` exists for,
    /// without needing a persisted `folderName` field on `EquipmentSystem` itself since there's no
    /// nested folder structure underneath it to keep stable, just the one file.
    private func fileURL(for system: EquipmentSystem) -> URL {
        rootDirectory.appendingPathComponent("\(system.id.uuidString).json")
    }

    private func persist(_ system: EquipmentSystem) {
        guard let data = try? JSONEncoder().encode(system) else { return }
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: system))
    }

    private static func loadAll(from directory: URL, fileManager: FileManager) -> [EquipmentSystem] {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? decoder.decode(EquipmentSystem.self, from: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One-time migration for anyone who set up equipment before this moved from `UserDefaults`
    /// to files — writes each legacy system out as its own file (via the normal `persist(_:)`
    /// path) exactly once, then clears the old key so this never runs again or fights a user who
    /// deletes every system afterward (an empty `systems` array from files is not "nothing was
    /// ever migrated," it's "the user doesn't have any equipment set up," full stop). A no-op
    /// (skipped entirely) when there's nothing left in the old key, or when files already exist —
    /// this only ever runs on a genuinely-first launch after upgrading.
    private func migrateFromUserDefaultsIfNeeded() {
        guard systems.isEmpty else { return }
        let legacy = AppSettings.equipmentSystems
        guard !legacy.isEmpty else { return }
        for system in legacy {
            persist(system)
        }
        systems = legacy
        AppSettings.equipmentSystems = []
    }
}
