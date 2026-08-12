import Testing
@testable import skyformac

struct PlanetaryPresetTests {
    @Test func startingValuesAreTheLowEndOfEachRange() {
        for preset in PlanetaryPreset.allCases {
            #expect(preset.startingExposureSeconds == preset.exposureRangeSeconds.lowerBound)
            #expect(preset.startingGain == preset.gainRange.lowerBound)
        }
    }

    @Test func onlyJupiterHasTheRotationBlurNote() {
        for preset in PlanetaryPreset.allCases {
            #expect((preset.note != nil) == (preset == .jupiter))
        }
    }

    @Test func moonPresetUsesFullSensorWhileOthersUseACrop() {
        #expect(PlanetaryPreset.moon.roi == nil)
        for preset in PlanetaryPreset.allCases where preset != .moon {
            #expect(preset.roi != nil)
        }
    }

    @Test func gainAndExposureRangesAreNonEmpty() {
        for preset in PlanetaryPreset.allCases {
            #expect(preset.gainRange.lowerBound <= preset.gainRange.upperBound)
            #expect(preset.exposureRangeSeconds.lowerBound <= preset.exposureRangeSeconds.upperBound)
            #expect(preset.histogramTargetPercent.lowerBound <= preset.histogramTargetPercent.upperBound)
        }
    }
}
