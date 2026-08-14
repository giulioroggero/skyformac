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
}
