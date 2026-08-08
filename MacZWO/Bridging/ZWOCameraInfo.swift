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

    /// Synthetic camera info for the "Simulate Test Pattern" debug path — lets the capture,
    /// debayer, histogram, and Metal rendering pipelines all be exercised end-to-end with no
    /// physical ASI camera attached. `cameraID: -1` so it can never collide with a real device.
    private init(
        simulatedName name: String,
        isColorCamera: Bool,
        bayerPattern: ASI_BAYER_PATTERN,
        maxWidth: Int,
        maxHeight: Int,
        bitDepth: Int
    ) {
        self.name = name
        self.cameraID = -1
        self.maxHeight = maxHeight
        self.maxWidth = maxWidth
        self.isColorCamera = isColorCamera
        self.bayerPattern = bayerPattern
        self.supportedBinnings = [1]
        self.supportedVideoFormats = [ASI_IMG_RAW8, ASI_IMG_RAW16]
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

    static func simulatedMono(width: Int = 640, height: Int = 480) -> ZWOCameraInfo {
        ZWOCameraInfo(
            simulatedName: "Simulated Mono Camera",
            isColorCamera: false,
            bayerPattern: ASI_BAYER_RG,
            maxWidth: width,
            maxHeight: height,
            bitDepth: 8
        )
    }

    static func simulatedColor(width: Int = 640, height: Int = 480) -> ZWOCameraInfo {
        ZWOCameraInfo(
            simulatedName: "Simulated Color Camera",
            isColorCamera: true,
            bayerPattern: ASI_BAYER_RG,
            maxWidth: width,
            maxHeight: height,
            bitDepth: 8
        )
    }
}
