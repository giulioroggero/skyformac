import Foundation
import Testing
@testable import skyformac

struct GraXpertElaborationTests {
    // MARK: - CLI path resolution

    @Test func defaultCLIPathIsUnderStandardGraXpertInstall() {
        #expect(GraXpertElaborationService.defaultCLIPath().path == "/Applications/GraXpert.app/Contents/MacOS/GraXpert")
    }

    // MARK: - Argument construction (pure function, no process spawned)

    @Test func backgroundExtractionArgumentsIncludeCorrectionAndSmoothing() {
        let args = GraXpertElaborationService.arguments(
            inputFileName: "image.fits", operation: .backgroundExtraction,
            parameters: .init(correction: .division, smoothing: 0.25, denoiseStrength: 0.5, useGPU: true),
            outputBaseName: "out"
        )
        #expect(args == ["image.fits", "-cli", "-cmd", "background-extraction", "-gpu", "true", "-output", "out", "-correction", "Division", "-smoothing", "0.25"])
    }

    @Test func denoisingArgumentsIncludeStrengthNotCorrection() {
        let args = GraXpertElaborationService.arguments(
            inputFileName: "image.fits", operation: .denoising,
            parameters: .init(correction: .subtraction, smoothing: 0.1, denoiseStrength: 0.75, useGPU: false),
            outputBaseName: "out"
        )
        #expect(args == ["image.fits", "-cli", "-cmd", "denoising", "-gpu", "false", "-output", "out", "-strength", "0.75"])
        #expect(!args.contains("-correction"))
        #expect(!args.contains("-smoothing"))
    }

    @Test func defaultParametersMatchGraXpertsOwnDocumentedDefaults() {
        #expect(GraXpertElaborationService.Parameters.default.correction == .subtraction)
        #expect(GraXpertElaborationService.Parameters.default.denoiseStrength == 0.5)
        #expect(GraXpertElaborationService.Parameters.default.useGPU == true)
    }

    // MARK: - ElaboratedImage: back-compat + GraXpert's own tool label

    @Test func decodingAnOlderElaboratedImageJSONWithoutToolLabelDefaultsToNilAndFallsBackToRecipe() throws {
        let json = """
        {"id":"\(UUID().uuidString)","date":0,"fileName":"a.tif","sourceSessionIDs":[],"recipe":"deepSky"}
        """
        let decoded = try JSONDecoder().decode(ElaboratedImage.self, from: Data(json.utf8))
        #expect(decoded.toolLabel == nil)
        #expect(decoded.displayLabel == "Deep Sky")
    }

    @Test func aGraXpertResultHasNoRecipeAndDisplaysItsToolLabel() throws {
        let image = ElaboratedImage(
            date: Date(), fileName: "b.tif", sourceSessionIDs: [], sourceCaptureID: nil,
            recipe: nil, toolLabel: "GraXpert · Background Extraction"
        )
        #expect(image.displayLabel == "GraXpert · Background Extraction")
        let roundTripped = try JSONDecoder().decode(ElaboratedImage.self, from: JSONEncoder().encode(image))
        #expect(roundTripped.recipe == nil)
        #expect(roundTripped.displayLabel == "GraXpert · Background Extraction")
    }
}
