import Foundation

/// Writes a `CapturedFrame`'s raw (pre-debayer) sensor data as a minimal single-HDU FITS file —
/// the standard scientific astronomy image format. Real capture software always saves the raw
/// Bayer/mono sensor data as FITS, not a debayered picture: demosaicing is a display/processing
/// step done later (e.g. in PixInsight/Siril), not part of the archival capture.
///
/// Implements just enough of the FITS 4.0 standard for a single 2D image HDU: an ASCII header of
/// 80-character card images padded to a 2880-byte block, followed by big-endian pixel data
/// padded to a 2880-byte block. 8-bit data is unsigned per the FITS convention; 16-bit data is
/// stored as FITS's native signed 16-bit with the standard `BZERO=32768`/`BSCALE=1` offset so it
/// round-trips as unsigned (the same convention ASCOM/INDI/SharpCap all use).
enum FITSWriter {
    enum FITSError: Error {
        case unsupportedImageType
    }

    static func write(frame: CapturedFrame, instrumentName: String, to url: URL) throws {
        switch frame.imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8:
            try writeHeaderAndData(
                bitpix: 8,
                width: frame.width,
                height: frame.height,
                bzero: nil,
                instrumentName: instrumentName,
                pixelData: frame.data, // already unsigned bytes, no byte-order concerns
                to: url
            )
        case ASI_IMG_RAW16:
            let bigEndianSigned = try signedBigEndian16(from: frame)
            try writeHeaderAndData(
                bitpix: 16,
                width: frame.width,
                height: frame.height,
                bzero: 32768,
                instrumentName: instrumentName,
                pixelData: bigEndianSigned,
                to: url
            )
        default:
            throw FITSError.unsupportedImageType
        }
    }

    /// FITS 16-bit is signed, big-endian, with the pixel's true unsigned value recovered as
    /// `stored + 32768` by any BZERO-aware reader — so store `Int16(unsignedValue - 32768)`.
    private static func signedBigEndian16(from frame: CapturedFrame) throws -> Data {
        let count = frame.width * frame.height
        guard frame.data.count >= count * 2 else { throw FITSError.unsupportedImageType }

        var output = Data(count: count * 2)
        frame.data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.bindMemory(to: UInt16.self).baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let out = dst.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count {
                    let signed = Int32(base[i]) - 32768
                    out[i] = UInt16(bitPattern: Int16(truncatingIfNeeded: signed)).bigEndian
                }
            }
        }
        return output
    }

    private static func writeHeaderAndData(
        bitpix: Int,
        width: Int,
        height: Int,
        bzero: Int?,
        instrumentName: String,
        pixelData: Data,
        to url: URL
    ) throws {
        var cards: [String] = [
            card("SIMPLE", "T", comment: "conforms to FITS standard"),
            card("BITPIX", "\(bitpix)"),
            card("NAXIS", "2"),
            card("NAXIS1", "\(width)"),
            card("NAXIS2", "\(height)"),
        ]
        if let bzero {
            cards.append(card("BZERO", "\(bzero)", comment: "offset for unsigned integer data"))
            cards.append(card("BSCALE", "1", comment: "default scaling"))
        }
        cards.append(cardString("INSTRUME", instrumentName))
        cards.append("END".padding(toLength: 80, withPad: " ", startingAt: 0))

        var header = Data(cards.joined().utf8)
        header.append(paddingBytes(for: header.count, blockSize: 2880, fill: 0x20)) // ASCII space

        var body = pixelData
        body.append(paddingBytes(for: body.count, blockSize: 2880, fill: 0x00))

        var file = Data()
        file.append(header)
        file.append(body)
        try file.write(to: url, options: .atomic)
    }

    private static func paddingBytes(for length: Int, blockSize: Int, fill: UInt8) -> Data {
        let remainder = length % blockSize
        guard remainder != 0 else { return Data() }
        return Data(repeating: fill, count: blockSize - remainder)
    }

    /// A numeric-valued 80-character FITS header card, right-justified per convention.
    private static func card(_ keyword: String, _ value: String, comment: String? = nil) -> String {
        var line = keyword.padding(toLength: 8, withPad: " ", startingAt: 0) + "= "
        line += String(repeating: " ", count: max(0, 20 - value.count)) + value
        if let comment {
            line += " / " + comment
        }
        if line.count > 80 { line = String(line.prefix(80)) }
        return line.padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    /// A string-valued 80-character FITS header card (single-quoted, per the FITS standard).
    private static func cardString(_ keyword: String, _ value: String) -> String {
        let quoted = "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        var line = keyword.padding(toLength: 8, withPad: " ", startingAt: 0) + "= " + quoted
        if line.count > 80 { line = String(line.prefix(80)) }
        return line.padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
