import Testing
@testable import skyformac

struct ROIGeometryTests {
    @Test func clampedDimensionRoundsDownToMultiple() {
        #expect(ROIGeometry.clampedDimension(803, maximum: 4000, multipleOf: 8) == 800)
        #expect(ROIGeometry.clampedDimension(605, maximum: 4000, multipleOf: 2) == 604)
    }

    @Test func clampedDimensionNeverExceedsMaximum() {
        #expect(ROIGeometry.clampedDimension(10000, maximum: 3840, multipleOf: 8) == 3840)
    }

    @Test func clampedDimensionNeverGoesBelowOneStep() {
        #expect(ROIGeometry.clampedDimension(0, maximum: 4000, multipleOf: 8) == 8)
        #expect(ROIGeometry.clampedDimension(-100, maximum: 4000, multipleOf: 8) == 8)
    }

    @Test func startPositionCentersROIAtRequestedCenter() {
        // 800x600 ROI centered at (2000, 1000) on a 4000x3000 sensor: top-left should be
        // (2000 - 400, 1000 - 300) = (1600, 700).
        let start = ROIGeometry.startPosition(
            width: 800, height: 600, centerX: 2000, centerY: 1000, sensorWidth: 4000, sensorHeight: 3000
        )
        #expect(start.x == 1600)
        #expect(start.y == 700)
    }

    @Test func startPositionClampsNearSensorEdge() {
        // Requesting a center right at the sensor's top-left corner must not push the ROI
        // off-sensor into negative coordinates.
        let start = ROIGeometry.startPosition(
            width: 800, height: 600, centerX: 0, centerY: 0, sensorWidth: 4000, sensorHeight: 3000
        )
        #expect(start.x == 0)
        #expect(start.y == 0)
    }

    @Test func startPositionClampsAtFarEdge() {
        // Requesting a center at the sensor's bottom-right corner must keep the whole ROI
        // on-sensor instead of letting it extend past the far edge.
        let start = ROIGeometry.startPosition(
            width: 800, height: 600, centerX: 4000, centerY: 3000, sensorWidth: 4000, sensorHeight: 3000
        )
        #expect(start.x == 4000 - 800)
        #expect(start.y == 3000 - 600)
    }

    @Test func startPositionHandlesROILargerThanSensor() {
        // Shouldn't happen in practice (width/height are clamped to the sensor size before this
        // is ever called), but must not go negative or crash if it somehow does.
        let start = ROIGeometry.startPosition(
            width: 5000, height: 4000, centerX: 2000, centerY: 1500, sensorWidth: 4000, sensorHeight: 3000
        )
        #expect(start.x == 0)
        #expect(start.y == 0)
    }
}
