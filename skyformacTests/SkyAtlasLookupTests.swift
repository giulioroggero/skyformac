import Foundation
import Testing
@testable import skyformac

struct SkyAtlasLookupTests {
    @Test func resolvesABareMessierDesignation() {
        let position = SkyAtlasLookup.position(forObjectName: "M13")
        #expect(position != nil)
    }

    @Test func resolvesAMessierDesignationCaseInsensitively() {
        #expect(SkyAtlasLookup.position(forObjectName: "m13") == SkyAtlasLookup.position(forObjectName: "M13"))
    }

    @Test func resolvesAMessierDesignationWithATrailingCommonName() {
        // The Quick Start/`DeepSkyObject` list spells this "M13 (Hercules Cluster)" — a different
        // string than the bundled catalog's own bare "M13" `id`, but the same object.
        let withSuffix = SkyAtlasLookup.position(forObjectName: "M13 (Hercules Cluster)")
        let bare = SkyAtlasLookup.position(forObjectName: "M13")
        #expect(withSuffix == bare)
        #expect(withSuffix != nil)
    }

    @Test func resolvesAMessierObjectByItsCommonNameAlone() {
        // M1's bundled entry has commonName "Crab Nebula" — matching by that name (with no "M1"
        // anywhere in the string) should still find the same coordinates as the bare designation.
        let byCommonName = SkyAtlasLookup.position(forObjectName: "Crab Nebula")
        let byDesignation = SkyAtlasLookup.position(forObjectName: "M1")
        #expect(byCommonName == byDesignation)
        #expect(byCommonName != nil)
    }

    @Test func resolvesABareCaldwellDesignation() {
        let position = SkyAtlasLookup.position(forObjectName: "C14")
        #expect(position != nil)
    }

    @Test func resolvesACaldwellDesignationCaseInsensitively() {
        #expect(SkyAtlasLookup.position(forObjectName: "c14") == SkyAtlasLookup.position(forObjectName: "C14"))
    }

    @Test func resolvesACaldwellObjectByItsCommonNameAlone() {
        // C14's bundled entry is the Double Cluster — matching by that name (no "C14" anywhere in
        // the string) should still find the same coordinates as the bare designation.
        let byCommonName = SkyAtlasLookup.position(forObjectName: "Double Cluster")
        let byDesignation = SkyAtlasLookup.position(forObjectName: "C14")
        #expect(byCommonName == byDesignation)
        #expect(byCommonName != nil)
    }

    @Test func resolvesABrightStarByName() {
        guard let firstStar = SkyCatalog.brightStars.first else {
            Issue.record("Expected at least one bundled bright star to test against")
            return
        }
        #expect(SkyAtlasLookup.position(forObjectName: firstStar.displayName) != nil)
    }

    @Test func returnsNilForAnUncatalogedFreeTextObject() {
        #expect(SkyAtlasLookup.position(forObjectName: "Comet Custom-42") == nil)
    }

    @Test func returnsNilForAnEmptyOrBlankName() {
        #expect(SkyAtlasLookup.position(forObjectName: "") == nil)
        #expect(SkyAtlasLookup.position(forObjectName: "   ") == nil)
    }

    @Test func isSolarSystemObjectIsTrueForEveryPlanetaryPreset() {
        for preset in PlanetaryPreset.allCases {
            #expect(SkyAtlasLookup.isSolarSystemObject(preset.rawValue))
        }
    }

    @Test func isSolarSystemObjectIsFalseForADeepSkyObject() {
        #expect(!SkyAtlasLookup.isSolarSystemObject("M13"))
    }
}
