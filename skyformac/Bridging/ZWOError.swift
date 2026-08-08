import Foundation

enum ZWOError: Error, CustomStringConvertible, Equatable {
    case invalidIndex
    case invalidID
    case invalidControlType
    case cameraClosed
    case cameraRemoved
    case invalidPath
    case invalidFileFormat
    case invalidSize
    case invalidImageType
    case outOfBoundary
    case timeout
    case invalidSequence
    case bufferTooSmall
    case videoModeActive
    case exposureInProgress
    case generalError
    case invalidMode
    case gpsNotSupported
    case gpsVersionError
    case gpsFPGAError
    case gpsParamOutOfRange
    case gpsDataInvalid
    case unknown(Int32)

    /// - Note: The ZWO header (`ASICamera2.h`) `#define`s `ASI_ERROR_CODE` to plain `int`
    ///   for every C-language (non-C++) declaration after line ~240, which is how this header
    ///   is imported into Swift. That means every `ASI*` function actually returns `Int32` in
    ///   Swift, not the `ASI_ERROR_CODE` enum type — so this initializer takes the raw code and
    ///   re-hydrates it into the enum type internally purely for readable pattern matching below.
    init(rawCode: Int32) {
        let code = ASI_ERROR_CODE(rawValue: UInt32(bitPattern: rawCode))
        switch code {
        case ASI_ERROR_INVALID_INDEX: self = .invalidIndex
        case ASI_ERROR_INVALID_ID: self = .invalidID
        case ASI_ERROR_INVALID_CONTROL_TYPE: self = .invalidControlType
        case ASI_ERROR_CAMERA_CLOSED: self = .cameraClosed
        case ASI_ERROR_CAMERA_REMOVED: self = .cameraRemoved
        case ASI_ERROR_INVALID_PATH: self = .invalidPath
        case ASI_ERROR_INVALID_FILEFORMAT: self = .invalidFileFormat
        case ASI_ERROR_INVALID_SIZE: self = .invalidSize
        case ASI_ERROR_INVALID_IMGTYPE: self = .invalidImageType
        case ASI_ERROR_OUTOF_BOUNDARY: self = .outOfBoundary
        case ASI_ERROR_TIMEOUT: self = .timeout
        case ASI_ERROR_INVALID_SEQUENCE: self = .invalidSequence
        case ASI_ERROR_BUFFER_TOO_SMALL: self = .bufferTooSmall
        case ASI_ERROR_VIDEO_MODE_ACTIVE: self = .videoModeActive
        case ASI_ERROR_EXPOSURE_IN_PROGRESS: self = .exposureInProgress
        case ASI_ERROR_GENERAL_ERROR: self = .generalError
        case ASI_ERROR_INVALID_MODE: self = .invalidMode
        case ASI_ERROR_GPS_NOT_SUPPORTED: self = .gpsNotSupported
        case ASI_ERROR_GPS_VER_ERR: self = .gpsVersionError
        case ASI_ERROR_GPS_FPGA_ERR: self = .gpsFPGAError
        case ASI_ERROR_GPS_PARAM_OUT_OF_RANGE: self = .gpsParamOutOfRange
        case ASI_ERROR_GPS_DATA_INVALID: self = .gpsDataInvalid
        default: self = .unknown(rawCode)
        }
    }

    var description: String {
        switch self {
        case .invalidIndex: return "No camera connected, or index out of range."
        case .invalidID: return "Invalid camera ID."
        case .invalidControlType: return "Invalid control type."
        case .cameraClosed: return "Camera is not open."
        case .cameraRemoved: return "Camera was removed."
        case .invalidPath: return "Invalid file path."
        case .invalidFileFormat: return "Invalid file format."
        case .invalidSize: return "Invalid video format size."
        case .invalidImageType: return "Unsupported image type."
        case .outOfBoundary: return "Start position out of boundary."
        case .timeout: return "Operation timed out."
        case .invalidSequence: return "Invalid sequence; stop capture first."
        case .bufferTooSmall: return "Buffer is too small."
        case .videoModeActive: return "Video capture mode is active."
        case .exposureInProgress: return "Exposure already in progress."
        case .generalError: return "General error (value out of valid range)."
        case .invalidMode: return "Current camera mode is invalid for this operation."
        case .gpsNotSupported: return "Camera does not support GPS."
        case .gpsVersionError: return "GPS FPGA version too low."
        case .gpsFPGAError: return "Failed to read/write FPGA data."
        case .gpsParamOutOfRange: return "GPS line parameter out of range."
        case .gpsDataInvalid: return "GPS has not acquired a satellite fix yet."
        case .unknown(let code): return "Unknown ZWO SDK error (\(code))."
        }
    }

    /// Throws a `ZWOError` if `rawCode` is not `ASI_SUCCESS`.
    static func check(_ rawCode: Int32) throws {
        guard rawCode == Int32(bitPattern: ASI_SUCCESS.rawValue) else {
            throw ZWOError(rawCode: rawCode)
        }
    }
}
