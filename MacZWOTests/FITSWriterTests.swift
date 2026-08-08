import Foundation
import Testing
@testable import MacZWO

struct FITSWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".fits")
    }

    /// Parses a FITS header block into a [keyword: trimmed value] dictionary, tolerant of the
    /// exact column alignment (only the syntax — 80-char cards, "KEYWORD = value / comment" —
    /// is required by the standard, not particular whitespace widths).
    private func parseHeaderCards(_ headerData: Data) -> [String: String] {
        guard let header = String(data: headerData, encoding: .ascii) else { return [:] }
        var result: [String: String] = [:]
        var index = header.startIndex
        while index < header.endIndex {
            let end = header.index(index, offsetBy: 80, limitedBy: header.endIndex) ?? header.endIndex
            let card = String(header[index..<end])
            index = end
            if card.hasPrefix("END") { break }
            guard let eqIndex = card.firstIndex(of: "=") else { continue }
            let keyword = card[card.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            var valuePart = String(card[card.index(after: eqIndex)...])
            if let slashIndex = valuePart.firstIndex(of: "/") {
                valuePart = String(valuePart[valuePart.startIndex..<slashIndex])
            }
            result[keyword] = valuePart.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    @Test func raw8FileSizeIsMultipleOf2880AndDataRoundTrips() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pixelBytes: [UInt8] = [10, 20, 30, 40]
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW8, data: Data(pixelBytes))
        try FITSWriter.write(frame: frame, instrumentName: "Test Camera", to: url)

        let fileData = try Data(contentsOf: url)
        #expect(fileData.count % 2880 == 0)

        let paddedDataLength = 2880 // 4 raw bytes round up to one 2880-byte block
        let dataOffset = fileData.count - paddedDataLength
        let readBack = Array(fileData[dataOffset..<(dataOffset + pixelBytes.count)])
        #expect(readBack == pixelBytes)

        let cards = parseHeaderCards(fileData.prefix(dataOffset))
        #expect(cards["SIMPLE"] == "T")
        #expect(cards["BITPIX"] == "8")
        #expect(cards["NAXIS1"] == "2")
        #expect(cards["NAXIS2"] == "2")
        #expect(cards["BZERO"] == nil) // no offset needed for unsigned 8-bit
    }

    @Test func raw16UsesBZeroOffsetConventionAndBigEndianByteOrder() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let pixelValues: [UInt16] = [0, 32768, 40000, 65535]
        var data = Data(count: pixelValues.count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            for (i, v) in pixelValues.enumerated() { p[i] = v }
        }
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RAW16, data: data)
        try FITSWriter.write(frame: frame, instrumentName: "Test Camera", to: url)

        let fileData = try Data(contentsOf: url)
        #expect(fileData.count % 2880 == 0)

        let paddedDataLength = 2880 // 8 raw bytes round up to one block
        let dataOffset = fileData.count - paddedDataLength
        let pixelData = fileData[dataOffset..<(dataOffset + pixelValues.count * 2)]

        var recovered: [UInt16] = []
        pixelData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt16.self)
            for i in 0..<pixelValues.count {
                let storedSigned = Int16(bitPattern: UInt16(bigEndian: p[i]))
                recovered.append(UInt16(Int32(storedSigned) + 32768))
            }
        }
        #expect(recovered == pixelValues)

        let cards = parseHeaderCards(fileData.prefix(dataOffset))
        #expect(cards["BITPIX"] == "16")
        #expect(cards["BZERO"] == "32768")
    }

    @Test func unsupportedImageTypeThrows() {
        let url = tempURL()
        let frame = CapturedFrame(width: 1, height: 1, imageType: ASI_IMG_RGB24, data: Data([1, 2, 3]))
        #expect(throws: FITSWriter.FITSError.self) {
            try FITSWriter.write(frame: frame, instrumentName: "Test Camera", to: url)
        }
    }
}
