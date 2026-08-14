import Foundation
import Testing
@testable import skyformac

/// `EquipmentLibrary` persists to real files under an injectable `rootDirectory` — a temp
/// directory per test, exactly the same isolation `ProjectStoreTests` already uses for
/// `ProjectStore`, so these tests never touch a real user's actual Equipment folder.
@MainActor
struct EquipmentLibraryTests {
    private func makeLibrary() -> (library: EquipmentLibrary, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (EquipmentLibrary(rootDirectory: root), root)
    }

    @Test func createSystemAddsAndPersistsItAsAFile() {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }

        let system = library.createSystem(name: "Backyard Rig")

        #expect(library.systems.count == 1)
        let fileURL = root.appendingPathComponent("\(system.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func saveUpdatesAnExistingSystemOnDisk() {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        var system = library.createSystem(name: "Backyard Rig")
        system.items.append(.custom(category: .camera, brand: "ZWO", model: "ASI678MC"))

        library.save(system)

        #expect(library.systems.count == 1)
        #expect(library.systems.first?.items.count == 1)

        // Reloading from the same directory picks up the saved change — proof it actually
        // persisted to the file, not just to the in-memory `systems` array.
        let reloaded = EquipmentLibrary(rootDirectory: root)
        #expect(reloaded.systems.first?.items.count == 1)
    }

    @Test func deleteRemovesTheSystemAndItsFile() {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let system = library.createSystem(name: "Travel Setup")
        let fileURL = root.appendingPathComponent("\(system.id.uuidString).json")

        library.delete(system)

        #expect(library.systems.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func systemWithIDReturnsNilForNilOrUnknownID() {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(library.system(withID: nil) == nil)
        #expect(library.system(withID: UUID()) == nil)
    }

    @Test func systemWithIDFindsAKnownSystem() {
        let (library, root) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let system = library.createSystem(name: "Backyard Rig")
        #expect(library.system(withID: system.id)?.name == "Backyard Rig")
    }

    @Test func aFreshDirectoryLoadsWhateverFilesAreAlreadyThere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let system = EquipmentSystem.newSystem(name: "Pre-existing Rig")
        let data = try JSONEncoder().encode(system)
        try data.write(to: root.appendingPathComponent("\(system.id.uuidString).json"))

        let library = EquipmentLibrary(rootDirectory: root)

        #expect(library.systems.map(\.name) == ["Pre-existing Rig"])
    }

    @Test func migratesLegacyUserDefaultsSystemsIntoFilesOnFirstLoad() {
        let originalLegacy = AppSettings.equipmentSystems
        defer { AppSettings.equipmentSystems = originalLegacy }
        let legacySystem = EquipmentSystem.newSystem(name: "Legacy Rig")
        AppSettings.equipmentSystems = [legacySystem]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = EquipmentLibrary(rootDirectory: root)

        #expect(library.systems.map(\.name) == ["Legacy Rig"])
        #expect(AppSettings.equipmentSystems.isEmpty) // migrated exactly once, old key cleared
        let fileURL = root.appendingPathComponent("\(legacySystem.id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func doesNotMigrateWhenFilesAlreadyExist() {
        let originalLegacy = AppSettings.equipmentSystems
        defer { AppSettings.equipmentSystems = originalLegacy }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let onDisk = EquipmentLibrary(rootDirectory: root)
        onDisk.createSystem(name: "Already On Disk")
        AppSettings.equipmentSystems = [EquipmentSystem.newSystem(name: "Should Not Appear")]

        let reloaded = EquipmentLibrary(rootDirectory: root)

        #expect(reloaded.systems.map(\.name) == ["Already On Disk"])
    }
}
