import Foundation
import Testing
@testable import skyformac

struct AcquisitionTargetTests {
    @Test func allListsEveryPlanetaryPresetAndDeepSkyObject() {
        let all = AcquisitionTarget.all
        #expect(all.count == PlanetaryPreset.allCases.count + DeepSkyObject.allCases.count)
    }

    @Test func moonRecommendsBothTechniques() {
        let moon = AcquisitionTarget.planetary(.moon)
        #expect(moon.recommendedMode == .both)
        let preset = moon.recommendedPreset()
        #expect(preset.mode == .both)
        #expect(preset.luckyBurstCount != nil)
        #expect(preset.isSmartLiveStackEnabled)
    }

    @Test func otherPlanetsRecommendLuckyImagingOnly() {
        for preset in PlanetaryPreset.allCases where preset != .moon {
            let target = AcquisitionTarget.planetary(preset)
            #expect(target.recommendedMode == .luckyImaging)
            let recommended = target.recommendedPreset()
            #expect(recommended.mode == .luckyImaging)
            #expect(recommended.luckyBurstCount != nil)
            #expect(!recommended.isSmartLiveStackEnabled)
        }
    }

    @Test func deepSkyObjectsRecommendLiveStackWithDriftReduction() {
        for object in DeepSkyObject.allCases {
            let target = AcquisitionTarget.deepSky(object)
            #expect(target.recommendedMode == .liveStack)
            let preset = target.recommendedPreset()
            #expect(preset.mode == .liveStack)
            #expect(preset.isDriftReductionEnabled)
            #expect(preset.isSmartLiveStackEnabled)
            #expect(preset.luckyBurstCount == nil)
            #expect(preset.roiWidth == nil)
        }
    }

    @Test func recommendedPresetUsesCustomNameWhenGiven() {
        let preset = AcquisitionTarget.deepSky(.m13).recommendedPreset(name: "My 8 inch setup")
        #expect(preset.name == "My 8 inch setup")
    }

    @Test func recommendedPresetDefaultsNameToTargetName() {
        let target = AcquisitionTarget.planetary(.saturn)
        #expect(target.recommendedPreset().name == target.name)
    }

    @Test func resolveFindsAMatchingTarget() throws {
        let target = AcquisitionTarget.deepSky(.m42)
        let resolved = try #require(AcquisitionTarget.resolve(id: target.id))
        #expect(resolved == target)
    }

    @Test func resolveReturnsNilForAnUnknownID() {
        #expect(AcquisitionTarget.resolve(id: "not.a.real.target") == nil)
    }

    @Test func presetRoundTripsThroughJSON() throws {
        let original = AcquisitionTarget.planetary(.jupiter).recommendedPreset(name: "Test Jupiter")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AcquisitionPreset.self, from: data)
        #expect(decoded == original)
    }

    @Test func deepSkyPresetRoundTripsThroughJSON() throws {
        let original = AcquisitionTarget.deepSky(.m56).recommendedPreset(name: "Test M56")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AcquisitionPreset.self, from: data)
        #expect(decoded == original)
    }

    /// "Experimental" mesh-based drift correction is worth trying deliberately, not silently
    /// inherited from a "recommended" preset — never `true` out of `recommendedPreset`, for
    /// either target genre, even the deep-sky one where it'd actually apply.
    @Test func recommendedPresetNeverAutoEnablesMeshDriftCorrection() {
        for target in AcquisitionTarget.all {
            #expect(target.recommendedPreset().isMeshDriftCorrectionEnabled == false)
        }
    }

    /// A preset file saved before `isMeshDriftCorrectionEnabled` existed has no such key at all —
    /// it must still decode (as `nil`, not throw) rather than breaking every previously-saved
    /// preset the moment this field was added.
    @Test func presetMissingMeshDriftCorrectionKeyStillDecodes() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Old Preset",
            "targetID": "deepSky.M13 (Hercules Cluster)",
            "mode": "liveStack",
            "isDriftReductionEnabled": true,
            "isSmartLiveStackEnabled": true
        }
        """
        let decoded = try JSONDecoder().decode(AcquisitionPreset.self, from: Data(json.utf8))
        #expect(decoded.isMeshDriftCorrectionEnabled == nil)
    }

    @Test func currentModeIsLiveStackOnlyWhenNoLuckySession() {
        #expect(AcquisitionMode.current(isLiveStackingEnabled: true, hasLuckyImagingSession: false) == .liveStack)
    }

    @Test func currentModeIsBothWhenLiveStackingAndLuckySessionActive() {
        #expect(AcquisitionMode.current(isLiveStackingEnabled: true, hasLuckyImagingSession: true) == .both)
    }

    @Test func currentModeIsLuckyImagingWhenLiveStackingIsOff() {
        #expect(AcquisitionMode.current(isLiveStackingEnabled: false, hasLuckyImagingSession: false) == .luckyImaging)
        #expect(AcquisitionMode.current(isLiveStackingEnabled: false, hasLuckyImagingSession: true) == .luckyImaging)
    }
}
