import CoreGraphics
import Foundation
import Testing
@testable import skyformac

struct WCSProjectionTests {
    private func makeFrame(
        centerRA: Double = 180, centerDec: Double = 0,
        fovDegrees: Double = 1, rotation: Double = 0,
        width: Int = 640, height: Int = 480
    ) -> WCSFrame {
        WCSFrame(
            centerRADeg: centerRA, centerDecDeg: centerDec,
            radiansPerPixel: (fovDegrees * .pi / 180) / Double(width),
            rotationRadians: rotation, imageWidth: width, imageHeight: height
        )
    }

    @Test func projectsFieldCenterToImageCenter() throws {
        let wcs = makeFrame()
        let pixel = try #require(wcs.projectToPixel(raDeg: 180, decDeg: 0))
        #expect(abs(pixel.x - 320) < 0.001)
        #expect(abs(pixel.y - 240) < 0.001)
    }

    /// At `rotationRadians: .pi`, +RA should move right and +Dec should move up — the sign
    /// convention `LiveWCSSolver` must also produce, since it's solving for the same `WCSFrame`.
    @Test func matchesLiveWCSSignConvention() throws {
        let wcs = makeFrame(fovDegrees: 10, rotation: .pi)
        let east = try #require(wcs.projectToPixel(raDeg: 180.5, decDeg: 0))
        #expect(east.x > 320) // +RA -> +x

        let north = try #require(wcs.projectToPixel(raDeg: 180, decDeg: 0.5))
        #expect(north.y < 240) // +Dec -> -y (up on screen)
    }

    @Test func boundingBoxCoversFullRAOnceHalfWidthPassesHalfCircle() {
        // Regression test: near a pole, a fixed sky-angle FOV spans a huge RA range (the cosδ
        // correction blows up), which previously wrapped past 360° back into a bogus *narrow*
        // slice instead of "the whole RA axis". Any two widely-separated RAs at this declination
        // must both fall inside the box.
        let wcs = makeFrame(centerRA: 30, centerDec: 80, fovDegrees: 25)
        let box = wcs.boundingBox()
        #expect(box.raMinDeg == 0)
        #expect(box.raMaxDeg == 360)
        #expect(!box.wrapsAround)
    }

    @Test func boundingBoxWrapsAcrossZeroSeam() {
        let wcs = makeFrame(centerRA: 359, centerDec: 0, fovDegrees: 4)
        let box = wcs.boundingBox()
        #expect(box.wrapsAround) // raMax (a few degrees past 0) < raMin (a few degrees below 359)
    }

    @Test func magnitudeLimitFollowsSpecLOD() {
        #expect(CatalogRepository.magnitudeLimit(forFOVDegrees: 10) == 6.0)
        #expect(CatalogRepository.magnitudeLimit(forFOVDegrees: 3) == 10.0)
        #expect(CatalogRepository.magnitudeLimit(forFOVDegrees: 0.5) == 14.0)
    }
}
