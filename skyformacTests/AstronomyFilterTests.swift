import Foundation
import Testing
@testable import skyformac

@MainActor
struct AstronomyFilterTests {
    private func makeManager() -> (manager: CameraManager, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (CameraManager(projectStore: ProjectStore(rootDirectory: root)), root)
    }

    @Test func emptySelectionIsIdentityGain() {
        #expect(FilterSelection.combinedGain(for: []) == SIMD3<Float>(repeating: 1))
    }

    @Test func zeroIntensityIsIdentityGain() {
        let selections = [FilterSelection(filter: .hAlpha, intensity: 0)]
        #expect(FilterSelection.combinedGain(for: selections) == SIMD3<Float>(repeating: 1))
    }

    @Test func fullIntensityMatchesTheFilterTypesOwnChannelGain() {
        let selections = [FilterSelection(filter: .oiii, intensity: 1)]
        let actual = FilterSelection.combinedGain(for: selections)
        let expected = AstronomyFilterType.oiii.channelGain
        // Not exact `==` — composing `1 + (gain - 1) * 1.0` back through floating-point isn't
        // guaranteed bit-identical to `gain` itself (0.19999999 vs. 0.2, seen in practice).
        #expect(abs(actual.x - expected.x) < 0.0001)
        #expect(abs(actual.y - expected.y) < 0.0001)
        #expect(abs(actual.z - expected.z) < 0.0001)
    }

    @Test func halfIntensityIsHalfwayBetweenIdentityAndFullGain() {
        let selections = [FilterSelection(filter: .hAlpha, intensity: 0.5)]
        let expected = SIMD3<Float>(repeating: 1) + (AstronomyFilterType.hAlpha.channelGain - SIMD3<Float>(repeating: 1)) * 0.5
        let actual = FilterSelection.combinedGain(for: selections)
        #expect(abs(actual.x - expected.x) < 0.0001)
        #expect(abs(actual.y - expected.y) < 0.0001)
        #expect(abs(actual.z - expected.z) < 0.0001)
    }

    @Test func intensityIsClampedToZeroToOneRange() {
        let overOne = FilterSelection.combinedGain(for: [FilterSelection(filter: .hAlpha, intensity: 5)])
        let atOne = FilterSelection.combinedGain(for: [FilterSelection(filter: .hAlpha, intensity: 1)])
        #expect(overOne == atOne)

        let belowZero = FilterSelection.combinedGain(for: [FilterSelection(filter: .hAlpha, intensity: -5)])
        #expect(belowZero == SIMD3<Float>(repeating: 1))
    }

    @Test func combiningTwoFiltersMultipliesTheirGainsTogether() {
        let combined = FilterSelection.combinedGain(for: [
            FilterSelection(filter: .hAlpha, intensity: 1),
            FilterSelection(filter: .oiii, intensity: 1)
        ])
        let expected = AstronomyFilterType.hAlpha.channelGain * AstronomyFilterType.oiii.channelGain
        #expect(abs(combined.x - expected.x) < 0.0001)
        #expect(abs(combined.y - expected.y) < 0.0001)
        #expect(abs(combined.z - expected.z) < 0.0001)
    }

    @Test func everyFilterTypeHasAMildChannelGain() {
        // Never below 0.2 (see `channelGain`'s doc comment) — a full-intensity filter should tint
        // a channel, not clip it to pure black.
        for filter in AstronomyFilterType.allCases {
            let gain = filter.channelGain
            #expect(gain.x >= 0.2 && gain.x <= 2.0)
            #expect(gain.y >= 0.2 && gain.y <= 2.0)
            #expect(gain.z >= 0.2 && gain.z <= 2.0)
        }
    }

    // MARK: - CameraManager integration

    @Test func toggleFilterAddsWithDefaultIntensityThenRemoves() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(manager.filterIntensity(for: .uhc) == 0)

        manager.toggleFilter(.uhc)
        #expect(manager.filterIntensity(for: .uhc) > 0)

        manager.toggleFilter(.uhc)
        #expect(manager.filterIntensity(for: .uhc) == 0)
    }

    @Test func setFilterIntensityToZeroRemovesTheSelectionEntirely() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.setFilterIntensity(.sii, intensity: 0.6)
        #expect(manager.activeFilterSelections.count == 1)

        manager.setFilterIntensity(.sii, intensity: 0)
        #expect(manager.activeFilterSelections.isEmpty)
    }

    @Test func disableAllFiltersClearsEverySelection() {
        let (manager, root) = makeManager()
        defer { try? FileManager.default.removeItem(at: root) }
        manager.setFilterIntensity(.hAlpha, intensity: 0.5)
        manager.setFilterIntensity(.oiii, intensity: 0.8)
        #expect(manager.activeFilterSelections.count == 2)

        manager.disableAllFilters()
        #expect(manager.activeFilterSelections.isEmpty)
        #expect(manager.combinedFilterGain == SIMD3<Float>(repeating: 1))
    }

    // MARK: - Back-compat decoding

    @Test func decodingAnOlderAcquisitionPresetJSONWithoutSelectedFiltersDefaultsToNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old Preset","targetID":"","mode":"single",
         "isDriftReductionEnabled":false,"isSmartLiveStackEnabled":false}
        """
        let decoded = try JSONDecoder().decode(AcquisitionPreset.self, from: Data(json.utf8))
        #expect(decoded.selectedFilters == nil)
    }

    @Test func selectedFiltersRoundTripThroughJSON() throws {
        var preset = AcquisitionPreset(
            name: "P", targetID: "", mode: .single, isDriftReductionEnabled: false, isSmartLiveStackEnabled: false
        )
        preset.selectedFilters = [FilterSelection(filter: .lEnhance, intensity: 0.5)]

        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(AcquisitionPreset.self, from: data)

        #expect(decoded.selectedFilters?.count == 1)
        #expect(decoded.selectedFilters?.first?.filter == .lEnhance)
        #expect(decoded.selectedFilters?.first?.intensity == 0.5)
    }
}
