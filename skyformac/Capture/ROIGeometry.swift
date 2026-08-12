import Foundation

/// Pure ROI arithmetic behind `CaptureEngine.setROI` — kept separate from the actor's SDK-call
/// plumbing so the clamping/centering math is unit-testable without a real camera.
enum ROIGeometry {
    /// Clamps `value` to the ASI SDK's own hard constraints (`ASISetROIFormat`: width a multiple
    /// of 8, height a multiple of 2) and to the sensor's real dimension.
    static func clampedDimension(_ value: Int, maximum: Int, multipleOf: Int) -> Int {
        let clamped = min(max(value, multipleOf), maximum)
        return (clamped / multipleOf) * multipleOf
    }

    /// The top-left `(startX, startY)` `ASISetStartPos` needs so a `width`×`height` ROI is
    /// *centered* at `centerX`/`centerY` (both full-sensor pixel coordinates) — clamped so the
    /// ROI never extends past the sensor's own edge, and never negative.
    ///
    /// - Important: Without this, every ROI capture landed at a fixed `(0, 0)` — `ASISetStartPos`
    ///   was never called at all, so the ASI SDK's own default (the sensor's top-left corner) is
    ///   what every "small ROI" request actually got, regardless of where the target the ROI was
    ///   supposed to isolate actually sat in the frame. A target anywhere near the center of a
    ///   full-sensor preview (the common case, once framed) would simply not appear at all in an
    ///   800×600 crop of a multi-thousand-pixel sensor.
    static func startPosition(
        width: Int, height: Int, centerX: Int, centerY: Int, sensorWidth: Int, sensorHeight: Int
    ) -> (x: Int, y: Int) {
        let rawX = centerX - width / 2
        let rawY = centerY - height / 2
        let maxX = max(sensorWidth - width, 0)
        let maxY = max(sensorHeight - height, 0)
        return (x: min(max(rawX, 0), maxX), y: min(max(rawY, 0), maxY))
    }
}
