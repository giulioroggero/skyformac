import Foundation
import Testing
@testable import skyformac

/// `EquipmentLibrary` reads/writes `AppSettings.equipmentSystems`, which is real `UserDefaults` —
/// every test clears it first/last so state never leaks between tests (or into a real launch of
/// the app on this same machine).
@MainActor
struct EquipmentLibraryTests {
    private func withCleanDefaults(_ body: (EquipmentLibrary) throws -> Void) rethrows {
        AppSettings.equipmentSystems = []
        let library = EquipmentLibrary()
        defer { AppSettings.equipmentSystems = [] }
        try body(library)
    }

    @Test func createSystemAddsAndPersistsIt() {
        withCleanDefaults { library in
            let system = library.createSystem(name: "Backyard Rig")
            #expect(library.systems.count == 1)
            #expect(AppSettings.equipmentSystems.first?.id == system.id)
        }
    }

    @Test func saveUpdatesAnExistingSystem() {
        withCleanDefaults { library in
            var system = library.createSystem(name: "Backyard Rig")
            system.items.append(.custom(category: .camera, brand: "ZWO", model: "ASI678MC"))
            library.save(system)

            #expect(library.systems.count == 1)
            #expect(library.systems.first?.items.count == 1)
            #expect(AppSettings.equipmentSystems.first?.items.count == 1)
        }
    }

    @Test func deleteRemovesTheSystem() {
        withCleanDefaults { library in
            let system = library.createSystem(name: "Travel Setup")
            library.delete(system)
            #expect(library.systems.isEmpty)
            #expect(AppSettings.equipmentSystems.isEmpty)
        }
    }

    @Test func systemWithIDReturnsNilForNilOrUnknownID() {
        withCleanDefaults { library in
            #expect(library.system(withID: nil) == nil)
            #expect(library.system(withID: UUID()) == nil)
        }
    }

    @Test func systemWithIDFindsAKnownSystem() {
        withCleanDefaults { library in
            let system = library.createSystem(name: "Backyard Rig")
            #expect(library.system(withID: system.id)?.name == "Backyard Rig")
        }
    }
}
