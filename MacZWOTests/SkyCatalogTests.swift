import Foundation
import Testing
@testable import MacZWO

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
}

struct DemoTargetGeneratorTests {
    @Test func planetsProduceNonEmptyBrightPixels() {
        let frame = DemoTargetGenerator.generate(.jupiter, width: 64, height: 64)
        #expect(frame.data.contains { $0 > 100 })
    }

    @Test func starFieldPlacesRecognizableBrightSpot() {
        let frame = DemoTargetGenerator.generate(.starField, width: 128, height: 128)
        #expect(frame.data.contains { $0 > 150 })
    }

    @Test func deepSkyShowcaseIsNonEmptyAndRenders() {
        #expect(!DemoTarget.deepSkyShowcase.isEmpty)
        for target in DemoTarget.deepSkyShowcase {
            let frame = DemoTargetGenerator.generate(target, width: 48, height: 48)
            #expect(frame.width == 48 && frame.height == 48)
        }
    }
}
