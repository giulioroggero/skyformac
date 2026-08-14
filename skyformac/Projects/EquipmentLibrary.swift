import Foundation
import Observation

/// The whole app's named equipment systems, backed by `AppSettings.equipmentSystems`. Mirrors
/// `ProjectsLibrary`'s "centralize CRUD, don't have views juggle raw persistence" shape at a much
/// smaller scale — a handful of named rigs, not a folder-per-item store.
@Observable
@MainActor
final class EquipmentLibrary {
    private(set) var systems: [EquipmentSystem] = []

    init() {
        systems = AppSettings.equipmentSystems
    }

    @discardableResult
    func createSystem(name: String) -> EquipmentSystem {
        let system = EquipmentSystem.newSystem(name: name)
        systems.insert(system, at: 0)
        persist()
        return system
    }

    func save(_ system: EquipmentSystem) {
        replace(system)
        persist()
    }

    func delete(_ system: EquipmentSystem) {
        systems.removeAll { $0.id == system.id }
        persist()
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

    private func persist() {
        AppSettings.equipmentSystems = systems
    }
}
