import Foundation
import Testing
@testable import skyformac

struct SkyCatalogTests {
    @Test func messierCatalogLoadsWithKnownObjects() {
        let m31 = SkyCatalog.messierObjects.first { $0.id == "M31" }
        #expect(m31?.commonName == "Andromeda Galaxy")
        #expect(SkyCatalog.messierObjects.count == 110)
    }

    @Test func brightStarsLoadWithSirius() {
        let sirius = SkyCatalog.brightStars.first { $0.id == "Sirius" }
        #expect(sirius != nil)
        #expect(sirius?.magnitude ?? 0 < 0) // Sirius is famously negative-magnitude
    }

    @Test func caldwellCatalogLoadsAllOneHundredNineObjectsWithUniqueIDs() {
        #expect(SkyCatalog.caldwellObjects.count == 109)
        #expect(Set(SkyCatalog.caldwellObjects.map(\.id)).count == 109)
    }

    @Test func caldwellCatalogHasKnownObjects() {
        let doubleCluster = SkyCatalog.caldwellObjects.first { $0.id == "C14" }
        #expect(doubleCluster?.commonName == "Double Cluster")
    }

    @Test func ngcCatalogLoadsWithUniqueIDsAndKnownObjects() {
        #expect(!SkyCatalog.ngcObjects.isEmpty)
        #expect(Set(SkyCatalog.ngcObjects.map(\.id)).count == SkyCatalog.ngcObjects.count)
        let heartNebula = SkyCatalog.ngcObjects.first { $0.commonName == "Heart Nebula" }
        #expect(heartNebula != nil)
    }

    @Test func ngcCatalogEntriesHaveValidCoordinatesAndMagnitude() {
        for object in SkyCatalog.ngcObjects {
            #expect((0...360).contains(object.raDegrees))
            #expect((-90...90).contains(object.decDegrees))
            #expect(object.magnitude < 9.0)
        }
    }
}
