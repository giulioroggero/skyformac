import Foundation

/// Reads an existing SER video back into its individual frames — the inverse of `SERWriter`,
/// needed so a previously-recorded `.ser` can be re-cropped (see `SirilElaborationService`'s
/// "crop to the planet before elaborating" support) without re-encoding through some other tool
/// first. Implements the same 178-byte-header subset `SERWriter` writes: mono/Bayer/RGB, 8- or
/// 16-bit, an optional per-frame timestamp trailer this doesn't need to parse (frame data always
/// comes right after the header, regardless of whether a trailer follows it).
enum SERReader {
    enum SERError: Error {
        case notASERFile
        case truncatedFrameData
    }

    struct Header {
        let width: Int
        let height: Int
        let imageType: ASI_IMG_TYPE
        let isColorCamera: Bool
        let bayerPattern: ASI_BAYER_PATTERN
        let bytesPerPixel: Int
        let planeCount: Int
        let frameCount: Int

        fileprivate var frameByteCount: Int { width * height * bytesPerPixel * planeCount }
    }

    struct ParsedSER {
        let width: Int
        let height: Int
        let imageType: ASI_IMG_TYPE
        let isColorCamera: Bool
        let bayerPattern: ASI_BAYER_PATTERN
        let frames: [CapturedFrame]
    }

    /// Loads every frame into memory at once — matches `SirilElaborationService.elaborate`'s own
    /// existing "stage everything into a scratch directory up front" shape, and real planetary SER
    /// files (already a tightly-cropped ROI from the capture side) stay small enough for this to
    /// be reasonable; a multi-gigabyte deep-sky-scale video was never this format's use case.
    static func read(from url: URL) throws -> ParsedSER {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try readHeader(handle)

        var frames: [CapturedFrame] = []
        frames.reserveCapacity(header.frameCount)
        for _ in 0..<header.frameCount {
            guard let chunk = try handle.read(upToCount: header.frameByteCount), chunk.count == header.frameByteCount else {
                throw SERError.truncatedFrameData
            }
            frames.append(CapturedFrame(width: header.width, height: header.height, imageType: header.imageType, data: chunk))
        }

        return ParsedSER(
            width: header.width, height: header.height, imageType: header.imageType,
            isColorCamera: header.isColorCamera, bayerPattern: header.bayerPattern, frames: frames
        )
    }

    /// Just the header plus the very first frame — what a crop-preview thumbnail actually needs,
    /// without reading a potentially large video's every remaining frame into memory just to
    /// throw them away.
    static func readFirstFrame(from url: URL) throws -> (frame: CapturedFrame, isColorCamera: Bool, bayerPattern: ASI_BAYER_PATTERN) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try readHeader(handle)
        guard header.frameCount > 0, let chunk = try handle.read(upToCount: header.frameByteCount), chunk.count == header.frameByteCount
        else { throw SERError.truncatedFrameData }
        let frame = CapturedFrame(width: header.width, height: header.height, imageType: header.imageType, data: chunk)
        return (frame, header.isColorCamera, header.bayerPattern)
    }

    /// Reads and parses the fixed 178-byte header — leaves the file handle's offset positioned
    /// right at the start of frame data, ready for the caller to read frames sequentially.
    private static func readHeader(_ handle: FileHandle) throws -> Header {
        guard let headerData = try handle.read(upToCount: 178), headerData.count == 178 else { throw SERError.notASERFile }
        let fileID = String(data: headerData[0..<14], encoding: .ascii) ?? ""
        guard fileID.hasPrefix("LUCAM-RECORDER") else { throw SERError.notASERFile }

        // Field layout after the 14-byte FileID (matches `SERWriter.header(...)` exactly): LuID(4)
        // @14, ColorID(4) @18, LittleEndian(4) @22, Width(4) @26, Height(4) @30,
        // PixelDepthPerPlane(4) @34, FrameCount(4) @38.
        let colorIDRaw = int32LE(headerData, at: 18)
        let width = Int(int32LE(headerData, at: 26))
        let height = Int(int32LE(headerData, at: 30))
        let bitsPerPlane = Int(int32LE(headerData, at: 34))
        let frameCount = Int(int32LE(headerData, at: 38))

        let (imageType, isColorCamera, bayerPattern, planeCount): (ASI_IMG_TYPE, Bool, ASI_BAYER_PATTERN, Int)
        switch (colorIDRaw, bitsPerPlane) {
        case (0, 8): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW8, false, ASI_BAYER_RG, 1)
        case (0, 16): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW16, false, ASI_BAYER_RG, 1)
        case (8, 8): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW8, true, ASI_BAYER_RG, 1)
        case (8, 16): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW16, true, ASI_BAYER_RG, 1)
        case (9, 8): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW8, true, ASI_BAYER_GR, 1)
        case (9, 16): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW16, true, ASI_BAYER_GR, 1)
        case (10, 8): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW8, true, ASI_BAYER_GB, 1)
        case (10, 16): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW16, true, ASI_BAYER_GB, 1)
        case (11, 8): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW8, true, ASI_BAYER_BG, 1)
        case (11, 16): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RAW16, true, ASI_BAYER_BG, 1)
        case (100, 8): (imageType, isColorCamera, bayerPattern, planeCount) = (ASI_IMG_RGB24, true, ASI_BAYER_RG, 3)
        default: throw SERError.notASERFile
        }

        return Header(
            width: width, height: height, imageType: imageType, isColorCamera: isColorCamera,
            bayerPattern: bayerPattern, bytesPerPixel: bitsPerPlane > 8 ? 2 : 1, planeCount: planeCount, frameCount: frameCount
        )
    }

    private static func int32LE(_ data: Data, at offset: Int) -> Int32 {
        Int32(littleEndian: data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: Int32.self) })
    }
}
