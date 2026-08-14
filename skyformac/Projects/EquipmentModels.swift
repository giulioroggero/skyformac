import Foundation

/// The kind of gear an `EquipmentItem` is. Camera/mount/optical tube are what every real setup
/// has; everything else is optional extra gear some setups use and others don't.
enum EquipmentCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case camera
    case mount
    case opticalTube
    case trackingSystem
    case imagingAndOptics
    case autoguiding
    case powerAndControl
    case eyepiece
    case smartphoneMount
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .camera: return "Camera"
        case .mount: return "Mount"
        case .opticalTube: return "Optical Tube"
        case .trackingSystem: return "Tracking System"
        case .imagingAndOptics: return "Imaging & Optics"
        case .autoguiding: return "Autoguiding"
        case .powerAndControl: return "Power & Control"
        case .eyepiece: return "Eyepiece"
        case .smartphoneMount: return "Smartphone Mount"
        case .other: return "Other"
        }
    }

    var icon: String {
        switch self {
        case .camera: return "camera.fill"
        case .mount: return "gyroscope"
        case .opticalTube: return "scope"
        case .trackingSystem: return "location.north.line.fill"
        case .imagingAndOptics: return "camera.aperture"
        case .autoguiding: return "viewfinder"
        case .powerAndControl: return "bolt.fill"
        case .eyepiece: return "circle.dotted"
        case .smartphoneMount: return "iphone"
        case .other: return "shippingbox"
        }
    }

    /// The three every real setup needs — shown first (and always, even empty) in the system
    /// editor; every other category only shows once it actually has an item in it.
    var isCore: Bool { self == .camera || self == .mount || self == .opticalTube }
}

/// One curated, well-known piece of gear — a starting point so common equipment doesn't need to
/// be typed in by hand; "Add Custom" still covers anything not listed here, the same "curated
/// presets, not an exhaustive catalog, freely extensible" scoping `PlanetaryPreset`/
/// `DeepSkyObject` already use for observing targets.
struct EquipmentCatalogItem: Identifiable, Hashable, Sendable {
    let id: String
    let category: EquipmentCategory
    let brand: String
    let model: String

    var displayName: String { "\(brand) \(model)" }
}

enum EquipmentCatalog {
    static let items: [EquipmentCatalogItem] = [
        // Cameras
        EquipmentCatalogItem(id: "camera.zwo.asi678mc", category: .camera, brand: "ZWO", model: "ASI678MC"),
        EquipmentCatalogItem(id: "camera.zwo.asi294mc", category: .camera, brand: "ZWO", model: "ASI294MC Pro"),
        EquipmentCatalogItem(id: "camera.zwo.asi224mc", category: .camera, brand: "ZWO", model: "ASI224MC"),
        EquipmentCatalogItem(id: "camera.qhy.qhy268m", category: .camera, brand: "QHYCCD", model: "QHY268M"),
        EquipmentCatalogItem(id: "camera.canon.eosra", category: .camera, brand: "Canon", model: "EOS Ra"),
        // Mounts
        EquipmentCatalogItem(id: "mount.celestron.avx", category: .mount, brand: "Celestron", model: "Advanced VX"),
        EquipmentCatalogItem(id: "mount.skywatcher.eqm35", category: .mount, brand: "Sky-Watcher", model: "EQM-35 Pro"),
        EquipmentCatalogItem(id: "mount.skywatcher.heq5", category: .mount, brand: "Sky-Watcher", model: "HEQ5 Pro"),
        EquipmentCatalogItem(id: "mount.zwo.am5", category: .mount, brand: "ZWO", model: "AM5"),
        EquipmentCatalogItem(id: "mount.ioptron.gem28", category: .mount, brand: "iOptron", model: "GEM28"),
        // Optical tubes
        EquipmentCatalogItem(id: "tube.celestron.nexstar127", category: .opticalTube, brand: "Celestron", model: "NexStar 127 SLT Maksutov"),
        EquipmentCatalogItem(id: "tube.skywatcher.evostar72", category: .opticalTube, brand: "Sky-Watcher", model: "Evostar 72ED"),
        EquipmentCatalogItem(id: "tube.celestron.c8edgehd", category: .opticalTube, brand: "Celestron", model: "C8 EdgeHD"),
        EquipmentCatalogItem(id: "tube.orion.newtonian130", category: .opticalTube, brand: "Orion", model: "SpaceProbe 130ST Newtonian"),
        EquipmentCatalogItem(id: "tube.televue.np101is", category: .opticalTube, brand: "Tele Vue", model: "NP101is"),
        // Tracking systems
        EquipmentCatalogItem(id: "tracking.skywatcher.staradventurer", category: .trackingSystem, brand: "Sky-Watcher", model: "Star Adventurer GTi"),
        EquipmentCatalogItem(id: "tracking.ioptron.skyguider", category: .trackingSystem, brand: "iOptron", model: "SkyGuider Pro"),
        // Imaging & optics
        EquipmentCatalogItem(id: "optics.zwo.efw", category: .imagingAndOptics, brand: "ZWO", model: "EFW Filter Wheel"),
        EquipmentCatalogItem(id: "optics.celestron.reducer", category: .imagingAndOptics, brand: "Celestron", model: "0.63x Reducer/Corrector"),
        EquipmentCatalogItem(id: "optics.baader.uhcs", category: .imagingAndOptics, brand: "Baader", model: "UHC-S Filter"),
        // Autoguiding
        EquipmentCatalogItem(id: "guide.zwo.oag", category: .autoguiding, brand: "ZWO", model: "Off-Axis Guider"),
        EquipmentCatalogItem(id: "guide.zwo.asi120mmmini", category: .autoguiding, brand: "ZWO", model: "ASI120MM Mini Guide Camera"),
        EquipmentCatalogItem(id: "guide.orion.starshoot", category: .autoguiding, brand: "Orion", model: "StarShoot AutoGuider"),
        // Power & control
        EquipmentCatalogItem(id: "power.celestron.powertank", category: .powerAndControl, brand: "Celestron", model: "PowerTank Lithium"),
        EquipmentCatalogItem(id: "power.zwo.asiairplus", category: .powerAndControl, brand: "ZWO", model: "ASIAIR Plus"),
        EquipmentCatalogItem(id: "power.anker.powercore", category: .powerAndControl, brand: "Anker", model: "PowerCore USB Power Bank"),
        // Eyepieces
        EquipmentCatalogItem(id: "eyepiece.televue.plossl25", category: .eyepiece, brand: "Tele Vue", model: "Plössl 25mm"),
        EquipmentCatalogItem(id: "eyepiece.explorescientific.82-14", category: .eyepiece, brand: "Explore Scientific", model: "82° 14mm"),
        EquipmentCatalogItem(id: "eyepiece.celestron.xcel7", category: .eyepiece, brand: "Celestron", model: "X-Cel LX 7mm"),
        // Smartphone mounts (holding a phone to the eyepiece for afocal projection)
        EquipmentCatalogItem(id: "phone.celestron.nexyz", category: .smartphoneMount, brand: "Celestron", model: "NexYZ 3-Axis Smartphone Adapter"),
        EquipmentCatalogItem(id: "phone.orion.steadypix", category: .smartphoneMount, brand: "Orion", model: "SteadyPix Deluxe Smartphone Adapter"),
        EquipmentCatalogItem(id: "phone.generic.universal", category: .smartphoneMount, brand: "Generic", model: "Universal Eyepiece Phone Adapter"),
    ]

    static func items(for category: EquipmentCategory) -> [EquipmentCatalogItem] {
        items.filter { $0.category == category }
    }
}

/// One physical piece of gear in a system — either picked from `EquipmentCatalog` (brand/model
/// filled in from there) or entered by hand for anything not listed.
struct EquipmentItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var category: EquipmentCategory
    var brand: String
    var model: String
    var notes: String

    var displayName: String {
        let name = "\(brand) \(model)".trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? category.displayName : name
    }

    static func fromCatalog(_ catalogItem: EquipmentCatalogItem) -> EquipmentItem {
        EquipmentItem(category: catalogItem.category, brand: catalogItem.brand, model: catalogItem.model, notes: "")
    }

    static func custom(category: EquipmentCategory, brand: String, model: String) -> EquipmentItem {
        EquipmentItem(category: category, brand: brand, model: model, notes: "")
    }
}

/// A named collection of `EquipmentItem`s used together — "Backyard Rig," "Travel Setup" —
/// composed freely: more than one of the same category is fine (two cameras, a main scope plus a
/// guide scope, and so on), matching how a real imaging train is actually built. Associated with
/// a `Project` (and, per-session, optionally overridden) via `equipmentSystemID`.
struct EquipmentSystem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var items: [EquipmentItem]

    static func newSystem(name: String) -> EquipmentSystem {
        EquipmentSystem(name: name, items: [])
    }

    func items(in category: EquipmentCategory) -> [EquipmentItem] {
        items.filter { $0.category == category }
    }
}
