import Foundation
import Testing
@testable import skyformac

struct CatalogRepositoryTests {
    @Test func fetchesAndromedaGalaxyWithinItsOwnField() async throws {
        let wcs = WCSFrame(
            centerRADeg: 10.684708, centerDecDeg: 41.26875,
            radiansPerPixel: (1.0 * .pi / 180) / 640,
            rotationRadians: 0, imageWidth: 640, imageHeight: 480
        )
        let objects = await CatalogRepository.shared.fetchObjects(
            in: wcs.boundingBox(), maxMagnitude: CatalogRepository.magnitudeLimit(forFOVDegrees: 1)
        )
        let m31 = try #require(objects.first { $0.catalog == "M" && $0.catalogNumber == 31 })
        #expect(m31.commonName == "Andromeda Galaxy")
        #expect(m31.badgeStyle == .messier)
    }

    @Test func fetchReturnsNothingFarFromAnyBoundedField() async {
        // A field with an empty (inverted) declination range can never match any row.
        let bounds = BoundingBox(raMinDeg: 0, raMaxDeg: 1, decMinDeg: 1, decMaxDeg: -1)
        let objects = await CatalogRepository.shared.fetchObjects(in: bounds, maxMagnitude: 20)
        #expect(objects.isEmpty)
    }
}
