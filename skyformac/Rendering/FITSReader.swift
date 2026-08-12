import Foundation

/// Reads a minimal single-HDU FITS file back into a `CapturedFrame` — the inverse of
/// `FITSWriter`, and specifically only of what `FITSWriter` itself produces (`SIMPLE`/`BITPIX`/
/// `NAXIS1`/`NAXIS2`/`BZERO`/`BSCALE`/`INSTRUME`/`BAYERPAT` cards, 8- or 16-bit integer data).
/// This is what makes "open a previously exported/recorded FITS file back in skyformac" possible
/// at all — letting the app's own debayer/stretch pipeline render a file it (or a compatible
/// tool using the same `BAYERPAT` convention) already wrote, rather than the app being a
/// write-only capture tool.
///
/// Deliberately not a general-purpose FITS reader: real FITS files can have multiple HDUs,
/// arbitrary additional header cards, world-coordinate-system keywords, and floating-point pixel
/// data (`BITPIX` -32/-64) — none of that is needed for what this app itself ever writes, and
/// pretending to support the full standard would be exactly the kind of overreach this codebase
/// otherwise avoids (see `docs/design-notes.md`'s running list of deliberately-scoped-out
/// features).
enum FITSReader {
    enum FITSError: Error {
        case notAFITSFile
        case missingRequiredCard(String)
        case unsupportedBitpix(Int)
        case truncatedPixelData
    }

    struct ParsedFITS {
        let frame: CapturedFrame
        let instrumentName: String?
        let isColorCamera: Bool
        let bayerPattern: ASI_BAYER_PATTERN
    }

    static func read(from url: URL) throws -> ParsedFITS {
        let data = try Data(contentsOf: url)
        let (cards, headerBlockCount) = try parseHeaderCards(data)

        guard cards["SIMPLE"]?.uppercased().hasPrefix("T") == true else { throw FITSError.notAFITSFile }
        guard let bitpixString = cards["BITPIX"], let bitpix = Int(bitpixString) else {
            throw FITSError.missingRequiredCard("BITPIX")
        }
        guard let widthString = cards["NAXIS1"], let width = Int(widthString) else {
            throw FITSError.missingRequiredCard("NAXIS1")
        }
        guard let heightString = cards["NAXIS2"], let height = Int(heightString) else {
            throw FITSError.missingRequiredCard("NAXIS2")
        }

        let bodyOffset = headerBlockCount * 2880
        let pixelCount = width * height
        let bayerPattern = cards["BAYERPAT"].flatMap { FITSWriter.bayerPattern(fromCardValue: unquote($0)) }
        let isColorCamera = bayerPattern != nil

        switch bitpix {
        case 8:
            guard data.count >= bodyOffset + pixelCount else { throw FITSError.truncatedPixelData }
            let pixelData = data.subdata(in: bodyOffset..<(bodyOffset + pixelCount))
            let frame = CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: pixelData)
            return ParsedFITS(
                frame: frame, instrumentName: cards["INSTRUME"].map(unquote),
                isColorCamera: isColorCamera, bayerPattern: bayerPattern ?? ASI_BAYER_RG
            )
        case 16:
            guard data.count >= bodyOffset + pixelCount * 2 else { throw FITSError.truncatedPixelData }
            let bzero = cards["BZERO"].flatMap { Double($0) } ?? 0
            let bigEndianSigned = data.subdata(in: bodyOffset..<(bodyOffset + pixelCount * 2))
            let pixelData = unsignedLittleEndian16(from: bigEndianSigned, count: pixelCount, bzero: bzero)
            let frame = CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW16, data: pixelData)
            return ParsedFITS(
                frame: frame, instrumentName: cards["INSTRUME"].map(unquote),
                isColorCamera: isColorCamera, bayerPattern: bayerPattern ?? ASI_BAYER_RG
            )
        default:
            throw FITSError.unsupportedBitpix(bitpix)
        }
    }

    /// Parses 80-character card images out of the 2880-byte-block-padded ASCII header, stopping
    /// at `END` — the inverse of `FITSWriter`'s `card`/`cardString`. Returns the parsed
    /// `[keyword: rawValue]` map (comments and surrounding whitespace/quotes not yet stripped —
    /// `unquote` handles the string-valued ones) and how many 2880-byte blocks the header
    /// occupied, so the caller knows exactly where the pixel data block begins.
    ///
    /// Decodes one whole 2880-byte block at a time, as ASCII, and stops the instant `END` is
    /// found — deliberately never attempts to ASCII-decode anything past the header's own
    /// blocks. The pixel data immediately follows, and is arbitrary binary (any byte 0-255,
    /// non-ASCII bytes very much included for real sensor data) — `String(data:encoding:.ascii)`
    /// fails outright (`nil`) the instant it's handed data containing even one byte ≥ 128, so an
    /// earlier version of this function that decoded the whole file (or an overly generous
    /// prefix of it) as one ASCII string would spuriously report "not a FITS file" for any frame
    /// whose actual pixel values happened to include such a byte — which for real 8/16-bit
    /// sensor data is the common case, not a rare one.
    private static func parseHeaderCards(_ data: Data) throws -> (cards: [String: String], blockCount: Int) {
        var cards: [String: String] = [:]
        var blockIndex = 0
        var reachedEnd = false
        // A generous but finite cap — `FITSWriter` never writes more than a handful of cards, so
        // this only guards against spinning on a malformed file that never contains an END card.
        while !reachedEnd, blockIndex < 16 {
            let blockStart = blockIndex * 2880
            guard data.count >= blockStart + 2880,
                  let blockString = String(data: data.subdata(in: blockStart..<(blockStart + 2880)), encoding: .ascii)
            else { throw FITSError.notAFITSFile }

            var index = blockString.startIndex
            while index < blockString.endIndex {
                guard let end = blockString.index(index, offsetBy: 80, limitedBy: blockString.endIndex) else { break }
                let cardText = String(blockString[index..<end])
                index = end
                if cardText.hasPrefix("END") { reachedEnd = true; break }
                guard let eqIndex = cardText.firstIndex(of: "=") else { continue }
                let keyword = cardText[cardText.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
                var valuePart = String(cardText[cardText.index(after: eqIndex)...])
                // A `/` inside a single-quoted string value is part of the string, not a comment
                // delimiter — only split on `/` outside quotes. None of `FITSWriter`'s own
                // string-valued cards (`INSTRUME`/`BAYERPAT`) contain a literal `/`, so a simple
                // "does it start with a quote" check is sufficient here rather than a full scanner.
                if !valuePart.trimmingCharacters(in: .whitespaces).hasPrefix("'"),
                   let slashIndex = valuePart.firstIndex(of: "/") {
                    valuePart = String(valuePart[valuePart.startIndex..<slashIndex])
                }
                cards[keyword] = valuePart.trimmingCharacters(in: .whitespaces)
            }
            blockIndex += 1
        }
        guard reachedEnd else { throw FITSError.notAFITSFile }
        return (cards, blockIndex)
    }

    /// Strips a FITS string card's surrounding single quotes and un-escapes `''` back to `'`.
    private static func unquote(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("'"), trimmed.hasSuffix("'"), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return trimmed.replacingOccurrences(of: "''", with: "'")
    }

    /// The inverse of `FITSWriter.signedBigEndian16` — recovers the original unsigned value as
    /// `bigEndianSigned + bzero` (both writer and reader agree on `bzero = 32768`, but this reads
    /// whatever `BZERO` the file itself actually declares, in case a different tool wrote it with
    /// a different offset), and returns little-endian bytes, matching `CapturedFrame.data`'s own
    /// documented native byte order.
    private static func unsignedLittleEndian16(from bigEndianSigned: Data, count: Int, bzero: Double) -> Data {
        var output = Data(count: count * 2)
        bigEndianSigned.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            guard let base = src.bindMemory(to: UInt16.self).baseAddress else { return }
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                guard let out = dst.bindMemory(to: UInt16.self).baseAddress else { return }
                for i in 0..<count {
                    let signed = Int16(bitPattern: UInt16(bigEndian: base[i]))
                    let unsigned = Double(signed) + bzero
                    out[i] = UInt16(clamping: Int(unsigned.rounded())).littleEndian
                }
            }
        }
        return output
    }
}
