import Foundation

/// Incremental writer for the SER video format — the standard uncompressed raw-frame video
/// container planetary/lunar "lucky imaging" workflows are actually built around: record a small
/// ROI at a high frame rate for a few minutes, then align and stack the sharpest fraction of
/// frames in a dedicated tool (AutoStakkert!3, PIPP) that expects exactly this format, not FITS
/// or PNG. Frames stream straight to disk as they arrive rather than buffering in memory — the
/// same reasoning `CameraManager`'s existing FITS "Record to Disk" already applies, just more
/// pressing here: 100+ FPS for a few minutes is tens of thousands of frames, easily multiple
/// gigabytes, that a naive in-memory buffer would have to hold before writing a single byte.
///
/// Implements the open SER format specification (the "SER Player"/Grabbing format used by
/// FireCapture, SharpCap, PIPP, and AutoStakkert!3): a 178-byte header, each frame's raw pixel
/// bytes back-to-back, then an optional per-frame timestamp trailer (included here — one
/// .NET-tick `Int64` per frame — since it's cheap to provide and some downstream tools use it,
/// rather than omitting it and hoping every reader tolerates that).
final class SERWriter {
    enum SERError: Error {
        case unsupportedImageType
        case fileCreationFailed
        case frameMismatch
    }

    /// SER's `ColorID` field — matches the sensor's actual Bayer pattern (or plain mono/RGB) so a
    /// reader debayers correctly; getting this wrong wouldn't corrupt the file, but would make
    /// every downstream tool demosaic with the wrong pattern.
    private enum ColorID: Int32 {
        case mono = 0
        case bayerRGGB = 8
        case bayerGRBG = 9
        case bayerGBRG = 10
        case bayerBGGR = 11
        case rgb = 100
    }

    private let fileHandle: FileHandle
    private let width: Int
    private let height: Int
    private let bytesPerPixel: Int
    private let planeCount: Int
    private var frameCount: Int32 = 0
    private var frameTimestamps: [Int64] = []

    /// `bayerPattern` is only consulted for RAW8/RAW16 (Bayer mono sensor data) — RGB24
    /// (already-debayered webcam/iPhone frames) always writes as `.rgb` regardless of it, and a
    /// mono (non-Bayer) camera's `isColorCamera == false` writes as `.mono` regardless of it too.
    init(firstFrame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN, instrumentName: String, url: URL) throws {
        let bpp: Int
        let planes: Int
        let colorID: ColorID
        switch firstFrame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            bpp = 1
            planes = 1
            colorID = isColorCamera ? Self.colorID(for: bayerPattern) : .mono
        case ASI_IMG_RAW16:
            bpp = 2
            planes = 1
            colorID = isColorCamera ? Self.colorID(for: bayerPattern) : .mono
        case ASI_IMG_RGB24:
            // 8 bits *per plane*, 3 planes — the per-pixel byte order this app already produces
            // (`WebcamCaptureEngine`'s `vImageConvert_BGRA8888toRGB888`) is R,G,B, matching SER's
            // `.rgb` ColorID exactly (as opposed to `.bgr`, which SER also supports but this app
            // never produces).
            bpp = 1
            planes = 3
            colorID = .rgb
        default:
            throw SERError.unsupportedImageType
        }

        self.width = firstFrame.width
        self.height = firstFrame.height
        self.bytesPerPixel = bpp
        self.planeCount = planes

        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: url.path)
        else { throw SERError.fileCreationFailed }
        self.fileHandle = handle

        try handle.write(contentsOf: Self.header(
            width: width, height: height, bytesPerPixel: bpp, colorID: colorID, instrumentName: instrumentName
        ))
    }

    private static func colorID(for bayerPattern: ASI_BAYER_PATTERN) -> ColorID {
        switch bayerPattern {
        case ASI_BAYER_RG: return .bayerRGGB
        case ASI_BAYER_BG: return .bayerBGGR
        case ASI_BAYER_GR: return .bayerGRBG
        case ASI_BAYER_GB: return .bayerGBRG
        default: return .bayerRGGB
        }
    }

    /// Appends one frame's raw pixel bytes. Must match the dimensions/byte layout `init` was
    /// given — a mid-recording ROI or format change would otherwise silently corrupt the file
    /// (every frame after the change would be the wrong size for what the header promised), so
    /// this refuses instead.
    func write(_ frame: CapturedFrame) throws {
        let expectedByteCount = width * height * bytesPerPixel * planeCount
        guard frame.width == width, frame.height == height, frame.data.count >= expectedByteCount
        else { throw SERError.frameMismatch }
        try fileHandle.write(contentsOf: frame.data.prefix(expectedByteCount))
        frameCount += 1
        frameTimestamps.append(Self.dotNetTicks(for: Date()))
    }

    /// Writes the timestamp trailer, patches the header's `FrameCount` field (unknown until now —
    /// SER is a streamed format with no length prefix elsewhere), and closes the file. Call
    /// exactly once when recording stops; safe to call even if `write` was never invoked (yields
    /// a valid, empty SER file).
    func close() throws {
        for tick in frameTimestamps {
            try fileHandle.write(contentsOf: Self.int64LE(tick))
        }
        try fileHandle.seek(toOffset: 38) // FrameCount field offset — see `header`'s layout.
        try fileHandle.write(contentsOf: Self.int32LE(frameCount))
        try fileHandle.closeFile()
    }

    /// The fixed 178-byte SER header. Field layout/offsets (all little-endian) per the format
    /// spec: FileID(14) + LuID(4) + ColorID(4) + LittleEndian(4) + Width(4) + Height(4) +
    /// PixelDepthPerPlane(4) + FrameCount(4) + Observer(40) + Instrument(40) + Telescope(40) +
    /// DateTime(8) + DateTime_UTC(8) = 178. `FrameCount` is written as 0 here and patched by
    /// `close()` once the real count is known.
    private static func header(width: Int, height: Int, bytesPerPixel: Int, colorID: ColorID, instrumentName: String) -> Data {
        var data = Data(capacity: 178)
        data.append(fixedASCII("LUCAM-RECORDER", length: 14))
        data.append(int32LE(0)) // LuID — not a real Lucam camera, no meaningful ID to report.
        data.append(int32LE(colorID.rawValue))
        // This app's raw sensor/RGB bytes are already native little-endian (see
        // `CapturedFrame`'s doc comment) — no byte-swap needed before writing, and this field
        // just has to accurately say so.
        data.append(int32LE(1))
        data.append(int32LE(Int32(width)))
        data.append(int32LE(Int32(height)))
        data.append(int32LE(Int32(bytesPerPixel * 8)))
        data.append(int32LE(0)) // FrameCount — patched in `close()`.
        data.append(fixedASCII("", length: 40)) // Observer
        data.append(fixedASCII(instrumentName, length: 40)) // Instrument
        data.append(fixedASCII("", length: 40)) // Telescope
        let ticks = dotNetTicks(for: Date())
        data.append(int64LE(ticks)) // DateTime (local) — this app doesn't track a separate
        data.append(int64LE(ticks)) // DateTime_UTC — timezone-aware capture time from UTC.
        return data
    }

    /// .NET `DateTime.Ticks` — 100ns intervals since `0001-01-01`, the timestamp convention SER
    /// inherited from its Windows/.NET origins. `62_135_596_800` is the number of seconds between
    /// that epoch and the Unix epoch (`1970-01-01`), a standard, well-known constant for this
    /// exact conversion.
    private static func dotNetTicks(for date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + 62_135_596_800) * 10_000_000)
    }

    private static func fixedASCII(_ string: String, length: Int) -> Data {
        var bytes = Array(string.utf8.prefix(length))
        bytes.append(contentsOf: repeatElement(0, count: max(0, length - bytes.count)))
        return Data(bytes)
    }

    private static func int32LE(_ value: Int32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }

    private static func int64LE(_ value: Int64) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 8)
    }
}
