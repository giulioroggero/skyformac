import Foundation

/// Thin, checked Swift wrapper around every `ASI*` C function used by this app.
///
/// Every call here either returns a plain Swift value or throws `ZWOError` — no raw C
/// pointers, C structs, or `ASI_ERROR_CODE` values are ever returned to callers, satisfying
/// the "never expose raw C pointers to the SwiftUI layer" rule from the project spec.
///
/// - Important: None of these functions is safe to call from `@MainActor`/the main thread
///   for the polling (`videoData`) or blocking calls — that isolation is enforced by
///   `CaptureEngine`, an `actor`, not by this type itself.
enum ZWOSDK {
    static func numOfConnectedCameras() -> Int {
        Int(ASIGetNumOfConnectedCameras())
    }

    static func cameraProperty(atIndex index: Int) throws -> ZWOCameraInfo {
        var info = ASI_CAMERA_INFO()
        try ZWOError.check(ASIGetCameraProperty(&info, Int32(index)))
        return ZWOCameraInfo(info)
    }

    static func cameraProperty(byID cameraID: Int32) throws -> ZWOCameraInfo {
        var info = ASI_CAMERA_INFO()
        try ZWOError.check(ASIGetCameraPropertyByID(cameraID, &info))
        return ZWOCameraInfo(info)
    }

    static func open(_ cameraID: Int32) throws {
        try ZWOError.check(ASIOpenCamera(cameraID))
    }

    static func initCamera(_ cameraID: Int32) throws {
        try ZWOError.check(ASIInitCamera(cameraID))
    }

    static func close(_ cameraID: Int32) throws {
        try ZWOError.check(ASICloseCamera(cameraID))
    }

    static func numOfControls(_ cameraID: Int32) throws -> Int {
        var count: Int32 = 0
        try ZWOError.check(ASIGetNumOfControls(cameraID, &count))
        return Int(count)
    }

    static func controlCaps(cameraID: Int32, index: Int) throws -> ZWOControlCaps {
        var caps = ASI_CONTROL_CAPS()
        try ZWOError.check(ASIGetControlCaps(cameraID, Int32(index), &caps))
        return ZWOControlCaps(caps)
    }

    static func allControlCaps(cameraID: Int32) throws -> [ZWOControlCaps] {
        let count = try numOfControls(cameraID)
        return try (0..<count).map { try controlCaps(cameraID: cameraID, index: $0) }
    }

    static func getControlValue(cameraID: Int32, controlType: ASI_CONTROL_TYPE) throws -> ZWOControlValue {
        var value: Int = 0
        var isAuto: Int32 = 0
        try ZWOError.check(ASIGetControlValue(cameraID, Int32(controlType.rawValue), &value, &isAuto))
        return ZWOControlValue(value: value, isAuto: isAuto == Int32(ASI_TRUE.rawValue))
    }

    static func setControlValue(
        cameraID: Int32,
        controlType: ASI_CONTROL_TYPE,
        value: Int,
        isAuto: Bool
    ) throws {
        let autoFlag: Int32 = isAuto ? Int32(ASI_TRUE.rawValue) : Int32(ASI_FALSE.rawValue)
        try ZWOError.check(ASISetControlValue(cameraID, Int32(controlType.rawValue), value, autoFlag))
    }

    static func setROIFormat(
        cameraID: Int32,
        width: Int,
        height: Int,
        binning: Int,
        imageType: ASI_IMG_TYPE
    ) throws {
        try ZWOError.check(
            ASISetROIFormat(cameraID, Int32(width), Int32(height), Int32(binning), imageType.rawValue)
        )
    }

    struct ROIFormat {
        var width: Int
        var height: Int
        var binning: Int
        var imageType: ASI_IMG_TYPE
    }

    static func getROIFormat(cameraID: Int32) throws -> ROIFormat {
        var width: Int32 = 0
        var height: Int32 = 0
        var binning: Int32 = 0
        var imageType: Int32 = 0
        try ZWOError.check(ASIGetROIFormat(cameraID, &width, &height, &binning, &imageType))
        return ROIFormat(
            width: Int(width),
            height: Int(height),
            binning: Int(binning),
            imageType: ASI_IMG_TYPE(rawValue: imageType)
        )
    }

    /// Positions the ROI `ASISetROIFormat` just set — must be called *after* it, per the SDK's
    /// own sample code. `(0, 0)` (the sensor's top-left corner) is the SDK's default if this is
    /// never called at all, which is almost never where a ROI should actually sit relative to a
    /// framed target — see `ROIGeometry.startPosition`'s doc comment.
    static func setStartPos(cameraID: Int32, startX: Int, startY: Int) throws {
        try ZWOError.check(ASISetStartPos(cameraID, Int32(startX), Int32(startY)))
    }

    static func getStartPos(cameraID: Int32) throws -> (x: Int, y: Int) {
        var startX: Int32 = 0
        var startY: Int32 = 0
        try ZWOError.check(ASIGetStartPos(cameraID, &startX, &startY))
        return (x: Int(startX), y: Int(startY))
    }

    static func startVideoCapture(cameraID: Int32) throws {
        try ZWOError.check(ASIStartVideoCapture(cameraID))
    }

    static func stopVideoCapture(cameraID: Int32) throws {
        try ZWOError.check(ASIStopVideoCapture(cameraID))
    }

    /// Blocking call — must only ever be invoked from the `CaptureEngine` actor's background
    /// execution context, never from `@MainActor`. `waitMilliseconds: -1` waits indefinitely.
    static func getVideoData(
        cameraID: Int32,
        buffer: UnsafeMutableRawBufferPointer,
        waitMilliseconds: Int32
    ) throws {
        guard let base = buffer.baseAddress else { return }
        try ZWOError.check(
            ASIGetVideoData(cameraID, base.assumingMemoryBound(to: UInt8.self), buffer.count, waitMilliseconds)
        )
    }

    static func getDroppedFrames(cameraID: Int32) throws -> Int {
        var dropped: Int32 = 0
        try ZWOError.check(ASIGetDroppedFrames(cameraID, &dropped))
        return Int(dropped)
    }

    static func startExposure(cameraID: Int32, isDark: Bool) throws {
        let flag: Int32 = isDark ? Int32(ASI_TRUE.rawValue) : Int32(ASI_FALSE.rawValue)
        try ZWOError.check(ASIStartExposure(cameraID, flag))
    }

    static func stopExposure(cameraID: Int32) throws {
        try ZWOError.check(ASIStopExposure(cameraID))
    }

    static func exposureStatus(cameraID: Int32) throws -> ASI_EXPOSURE_STATUS {
        var status = ASI_EXP_IDLE
        try ZWOError.check(ASIGetExpStatus(cameraID, &status))
        return status
    }

    /// Blocking-safe (single, bounded read once exposure succeeds) — call from `CaptureEngine`.
    static func getDataAfterExposure(cameraID: Int32, buffer: UnsafeMutableRawBufferPointer) throws {
        guard let base = buffer.baseAddress else { return }
        try ZWOError.check(
            ASIGetDataAfterExp(cameraID, base.assumingMemoryBound(to: UInt8.self), buffer.count)
        )
    }

    /// ZWO's own recommended gain/offset reference points for this specific camera model — the
    /// same numbers SharpCap's "gain presets" and ZWO's own ASICap show. Not every camera model
    /// supports this call (older/simpler sensors don't have separate dynamic-range/read-noise
    /// tradeoffs worth calling out) — callers should treat a thrown error as "not available for
    /// this camera," not a hard failure.
    struct GainOffsetPresets {
        /// Recommended offset at gain 0 — "Highest Dynamic Range" always means gain 0 by
        /// definition (dynamic range is monotonically best at the lowest gain), so only the
        /// offset for that setting is meaningful to report.
        var offsetHighestDynamicRange: Int
        /// Recommended offset at "Unity Gain" (where 1 ADU = 1 photoelectron) — the SDK doesn't
        /// separately report *which* gain value that is; ZWO documents it per camera model.
        var offsetUnityGain: Int
        var gainLowestReadNoise: Int
        var offsetLowestReadNoise: Int
    }

    static func gainOffsetPresets(cameraID: Int32) throws -> GainOffsetPresets {
        var offsetHighestDR: Int32 = 0
        var offsetUnityGain: Int32 = 0
        var gainLowestRN: Int32 = 0
        var offsetLowestRN: Int32 = 0
        try ZWOError.check(ASIGetGainOffset(cameraID, &offsetHighestDR, &offsetUnityGain, &gainLowestRN, &offsetLowestRN))
        return GainOffsetPresets(
            offsetHighestDynamicRange: Int(offsetHighestDR),
            offsetUnityGain: Int(offsetUnityGain),
            gainLowestReadNoise: Int(gainLowestRN),
            offsetLowestReadNoise: Int(offsetLowestRN)
        )
    }

    /// The "frequently-used" Low/Middle/High gain presets some camera models (mainly those with
    /// a dual-conversion-gain sensor) expose — `highGain`/`highOffset` is the lowest-read-noise
    /// setting, matching `GainOffsetPresets.gainLowestReadNoise`/`offsetLowestReadNoise` for
    /// cameras that support both calls.
    struct LMHGainOffsetPresets {
        var lowGain: Int
        var middleGain: Int
        var highGain: Int
        var highOffset: Int
    }

    static func lmhGainOffsetPresets(cameraID: Int32) throws -> LMHGainOffsetPresets {
        var lowGain: Int32 = 0
        var middleGain: Int32 = 0
        var highGain: Int32 = 0
        var highOffset: Int32 = 0
        try ZWOError.check(ASIGetLMHGainOffset(cameraID, &lowGain, &middleGain, &highGain, &highOffset))
        return LMHGainOffsetPresets(
            lowGain: Int(lowGain), middleGain: Int(middleGain), highGain: Int(highGain), highOffset: Int(highOffset)
        )
    }

    /// ST4 guide-port pulse guiding — only meaningful for a camera with a real ST4 port wired to
    /// a mount (`ZWOCameraInfo.hasST4Port`); a no-op-but-harmless call otherwise per the SDK's own
    /// doc comment ("this function only work on the module which have ST4 port").
    static func pulseGuideOn(cameraID: Int32, direction: ASI_GUIDE_DIRECTION) throws {
        try ZWOError.check(ASIPulseGuideOn(cameraID, Int32(direction.rawValue)))
    }

    static func pulseGuideOff(cameraID: Int32, direction: ASI_GUIDE_DIRECTION) throws {
        try ZWOError.check(ASIPulseGuideOff(cameraID, Int32(direction.rawValue)))
    }
}
