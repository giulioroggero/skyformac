import Foundation
import Testing
@testable import skyformac

struct StarNetElaborationTests {
    @Test func defaultCLIPathIsAGuessNotAGuarantee() {
        #expect(StarNetElaborationService.defaultCLIPath().path == "/usr/local/bin/starnet2")
    }

    @Test func argumentsIncludeInputOutputStrideAndQuietFlag() {
        let args = StarNetElaborationService.arguments(
            inputFileName: "image.tif", outputFileName: "image_starless.tif", parameters: .init(stride: 128)
        )
        #expect(args == ["-i", "image.tif", "-o", "image_starless.tif", "-s", "128", "-q"])
    }

    @Test func defaultParametersMatchStarNetsOwnSuggestedStride() {
        #expect(StarNetElaborationService.Parameters.default.stride == 256)
    }
}
