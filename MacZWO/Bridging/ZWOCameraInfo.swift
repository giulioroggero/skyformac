import Foundation

/// Pure-Swift mirror of `ASI_CAMERA_INFO`. No raw C struct or pointer crosses this boundary.
struct ZWOCameraInfo: Identifiable, Hashable, Sendable {
    var id: Int32 { cameraID }

    let name: String
    let cameraID: Int32
    let maxHeight: Int
    let maxWidth: Int
    let isColorCamera: Bool
    let bayerPattern: ASI_BAYER_PATTERN
    let supportedBinnings: [Int]
    let supportedVideoFormats: [ASI_IMG_TYPE]
    let pixelSizeMicrons: Double
    let hasMechanicalShutter: Bool
    let hasST4Port: Bool
    let isCoolerCamera: Bool
    let isUSB3Host: Bool
    let isUSB3Camera: Bool
    let electronsPerADU: Float
    let bitDepth: Int
    let isTriggerCamera: Bool

    init(_ info: ASI_CAMERA_INFO) {
        name = CTuple.string(fromCCharTuple: info.Name)
        cameraID = Int32(info.CameraID)
        maxHeight = Int(info.MaxHeight)
        maxWidth = Int(info.MaxWidth)
        isColorCamera = info.IsColorCam.rawValue == ASI_TRUE.rawValue
        bayerPattern = info.BayerPattern
        supportedBinnings = CTuple.int32Array(fromTuple: info.SupportedBins, count: 16, terminator: 0)
            .map { Int($0) }
        supportedVideoFormats = CTuple.int32Array(
            fromTuple: info.SupportedVideoFormat,
            count: 8,
            terminator: ASI_IMG_END.rawValue
        ).compactMap { ASI_IMG_TYPE(rawValue: $0) }
        pixelSizeMicrons = info.PixelSize
        hasMechanicalShutter = info.MechanicalShutter.rawValue == ASI_TRUE.rawValue
        hasST4Port = info.ST4Port.rawValue == ASI_TRUE.rawValue
        isCoolerCamera = info.IsCoolerCam.rawValue == ASI_TRUE.rawValue
        isUSB3Host = info.IsUSB3Host.rawValue == ASI_TRUE.rawValue
        isUSB3Camera = info.IsUSB3Camera.rawValue == ASI_TRUE.rawValue
        electronsPerADU = info.ElecPerADU
        bitDepth = Int(info.BitDepth)
        isTriggerCamera = info.IsTriggerCam.rawValue == ASI_TRUE.rawValue
    }

    static func == (lhs: ZWOCameraInfo, rhs: ZWOCameraInfo) -> Bool {
        lhs.cameraID == rhs.cameraID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(cameraID)
    }

    /// Synthetic camera info for the non-ZWO-SDK connection path — real `WebcamCaptureEngine`
    /// sources (`cameraID: -2`, Continuity Camera/USB webcam) — so it can flow through the exact
    /// same `CameraManager`/`CGImageRenderer`/histogram pipeline a real ASI camera does, without
    /// an `ASI_CAMERA_INFO` to back it. `cameraID: -2` is distinguished by
    /// `CameraManager.isExternalWebcam` and can never collide with a real device (ZWO IDs are
    /// always >= 0).
    private init(
        simulatedName name: String,
        cameraID: Int32,
        isColorCamera: Bool,
        bayerPattern: ASI_BAYER_PATTERN,
        maxWidth: Int,
        maxHeight: Int,
        bitDepth: Int,
        supportedVideoFormats: [ASI_IMG_TYPE]
    ) {
        self.name = name
        self.cameraID = cameraID
        self.maxHeight = maxHeight
        self.maxWidth = maxWidth
        self.isColorCamera = isColorCamera
        self.bayerPattern = bayerPattern
        self.supportedBinnings = [1]
        self.supportedVideoFormats = supportedVideoFormats
        self.pixelSizeMicrons = 3.75
        self.hasMechanicalShutter = false
        self.hasST4Port = false
        self.isCoolerCamera = false
        self.isUSB3Host = true
        self.isUSB3Camera = true
        self.electronsPerADU = 1.0
        self.bitDepth = bitDepth
        self.isTriggerCamera = false
    }

    /// An iPhone/iPad (Continuity Camera, wired or wireless) or other AVFoundation webcam,
    /// connected via `WebcamCaptureEngine` instead of the ZWO SDK. Always RGB24: the frames
    /// arrive already through the device's own ISP (debayered, color-processed), so there's no
    /// raw Bayer data the way there is from an actual ASI sensor — `bayerPattern` is unused.
    static func external(name: String, width: Int, height: Int) -> ZWOCameraInfo {
        ZWOCameraInfo(
            simulatedName: name,
            cameraID: -2,
            isColorCamera: true,
            bayerPattern: ASI_BAYER_RG,
            maxWidth: width,
            maxHeight: height,
            bitDepth: 8,
            supportedVideoFormats: [ASI_IMG_RGB24]
        )
    }
}
