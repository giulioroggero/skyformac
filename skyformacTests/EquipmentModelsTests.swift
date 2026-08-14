import Foundation
import Testing
@testable import skyformac

struct EquipmentModelsTests {
    @Test func catalogItemsForCategoryOnlyReturnsThatCategory() {
        let cameras = EquipmentCatalog.items(for: .camera)
        #expect(!cameras.isEmpty)
        #expect(cameras.allSatisfy { $0.category == .camera })
    }

    @Test func everyCoreCategoryHasAtLeastOneCatalogItem() {
        for category in EquipmentCategory.allCases where category.isCore {
            #expect(!EquipmentCatalog.items(for: category).isEmpty, "\(category) has no curated catalog items")
        }
    }

    @Test func catalogItemIDsAreUnique() {
        let ids = EquipmentCatalog.items.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func fromCatalogCopiesBrandModelAndCategory() {
        let catalogItem = EquipmentCatalog.items(for: .mount).first!
        let item = EquipmentItem.fromCatalog(catalogItem)
        #expect(item.brand == catalogItem.brand)
        #expect(item.model == catalogItem.model)
        #expect(item.category == catalogItem.category)
        #expect(item.displayName == catalogItem.displayName)
    }

    @Test func customItemDisplayNameCombinesBrandAndModel() {
        let item = EquipmentItem.custom(category: .eyepiece, brand: "Tele Vue", model: "Nagler 13mm")
        #expect(item.displayName == "Tele Vue Nagler 13mm")
    }

    @Test func itemsInCategoryFiltersASystemsItems() {
        var system = EquipmentSystem.newSystem(name: "Backyard Rig")
        system.items = [
            .custom(category: .camera, brand: "ZWO", model: "ASI678MC"),
            .custom(category: .mount, brand: "Sky-Watcher", model: "HEQ5"),
            .custom(category: .camera, brand: "ZWO", model: "ASI120MM Mini"),
        ]
        #expect(system.items(in: .camera).count == 2)
        #expect(system.items(in: .mount).count == 1)
        #expect(system.items(in: .eyepiece).isEmpty)
    }

    @Test func coreCategoriesAreExactlyCameraMountAndOpticalTube() {
        let core = EquipmentCategory.allCases.filter(\.isCore)
        #expect(Set(core) == [.camera, .mount, .opticalTube])
    }
}
