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

    @Test func scalingByTheReferenceTelescopeIsANoOp() {
        for preset in PlanetaryPreset.allCases {
            let scaled = preset.startingExposureSeconds(for: .reference)
            #expect(abs(scaled - preset.startingExposureSeconds) < 0.000_001)
        }
    }

    @Test func aFasterTelescopeNeedsLessExposure() {
        // Maksutov 90mm f/13.9 is slower (higher f/number) than the f/11.8 reference, and a
        // Newtonian 130mm f/5 is much faster — exposure should scale accordingly in each
        // direction, not just happen to differ.
        for preset in PlanetaryPreset.allCases {
            let reference = preset.startingExposureSeconds(for: .reference)
            let slower = preset.startingExposureSeconds(for: .maksutov90)
            let faster = preset.startingExposureSeconds(for: .newtonian130)
            #expect(slower > reference)
            #expect(faster < reference)
        }
    }

    @Test func scaledExposureStaysWithinSaneAbsoluteBounds() {
        for preset in PlanetaryPreset.allCases {
            for telescope in TelescopeProfile.allCases {
                let scaled = preset.startingExposureSeconds(for: telescope)
                #expect(scaled >= 0.00005)
                #expect(scaled <= 5.0)
            }
        }
    }

    @Test func exposureRangeForTelescopeScalesBothBoundsTogether() {
        let preset = PlanetaryPreset.saturn
        let reference = preset.exposureRangeSeconds(for: .reference)
        #expect(abs(reference.lowerBound - preset.exposureRangeSeconds.lowerBound) < 0.000_001)
        #expect(abs(reference.upperBound - preset.exposureRangeSeconds.upperBound) < 0.000_001)

        let scaled = preset.exposureRangeSeconds(for: .maksutov90)
        #expect(scaled.lowerBound > reference.lowerBound)
        #expect(scaled.upperBound > reference.upperBound)
        #expect(scaled.lowerBound <= scaled.upperBound)
    }
}

struct TelescopeProfileTests {
    @Test func focalRatioMatchesFocalLengthOverAperture() {
        for telescope in TelescopeProfile.allCases {
            let expected = telescope.focalLengthMillimeters / telescope.apertureMillimeters
            #expect(abs(telescope.focalRatio - expected) < 0.000_001)
        }
    }

    @Test func referenceIsMaksutov127() {
        #expect(TelescopeProfile.reference == .maksutov127)
    }

    @Test func everyProfileHasPositiveApertureAndFocalLength() {
        for telescope in TelescopeProfile.allCases {
            #expect(telescope.apertureMillimeters > 0)
            #expect(telescope.focalLengthMillimeters > 0)
        }
    }
}
