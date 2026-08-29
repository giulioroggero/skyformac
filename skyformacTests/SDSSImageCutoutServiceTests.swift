import Foundation
import Testing
@testable import skyformac

struct SDSSImageCutoutServiceTests {
    @Test func cutoutURLIncludesRAAndDecAsQueryParameters() {
        let url = SDSSImageCutoutService.cutoutURL(raDegrees: 10.68471, decDegrees: 41.26875)
        let string = try? #require(url?.absoluteString)
        #expect(string?.contains("ra=10.68471") == true)
        #expect(string?.contains("dec=41.26875") == true)
        #expect(string?.hasPrefix("https://skyserver.sdss.org/") == true)
    }

    @Test func cutoutURLUsesTheGivenScaleAndDimensions() {
        let url = SDSSImageCutoutService.cutoutURL(raDegrees: 0, decDegrees: 0, scaleArcsecPerPixel: 0.8, widthPixels: 200, heightPixels: 150)
        let string = try? #require(url?.absoluteString)
        #expect(string?.contains("scale=0.8") == true)
        #expect(string?.contains("width=200") == true)
        #expect(string?.contains("height=150") == true)
    }
}
