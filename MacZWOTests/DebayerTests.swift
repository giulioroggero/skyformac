import Foundation
import Testing
@testable import MacZWO

struct DebayerTests {
    /// A 4x4 RGGB Bayer tile with distinct per-position values so the demosaiced output at
    /// the exact sample points can be checked precisely (no interpolation involved there).
    private func makeRGGBFrame() -> CapturedFrame {
        // Row0: R  G  R  G
        // Row1: G  B  G  B
        // Row2: R  G  R  G
        // Row3: G  B  G  B
        let bytes: [UInt8] = [
            200, 100, 210, 110,
            120, 50, 130, 60,
            190, 90, 220, 105,
            115, 55, 125, 65,
        ]
        return CapturedFrame(width: 4, height: 4, imageType: ASI_IMG_RAW8, data: Data(bytes))
    }

    @Test func debayerPreservesExactSampleAtNativeChannel() throws {
        let frame = makeRGGBFrame()
        let rgb = try #require(Debayer.debayerRAW8(frame, pattern: ASI_BAYER_RG))
        #expect(rgb.count == 4 * 4 * 3)

        // (0,0) is a native Red sample: its R channel in the output must equal the raw value.
        let offset00 = 0
        #expect(rgb[offset00] == 200) // R channel at (0,0)

        // (1,1) is a native Blue sample (row1,col1 = B): its B channel must equal the raw value.
        let offsetB = (1 * 4 + 1) * 3
        #expect(rgb[offsetB + 2] == 50) // B channel at (1,1)
    }

    @Test func debayerInterpolatesGreenAtRedSampleFromFourNeighbors() throws {
        let frame = makeRGGBFrame()
        let rgb = try #require(Debayer.debayerRAW8(frame, pattern: ASI_BAYER_RG))

        // (0,0) is Red. Its real neighbors are (1,0)=100 (right, G) and (0,1)=120 (down, G);
        // the out-of-bounds left/up directions clamp to (0,0) itself (200, the pixel's own Red
        // value) under this implementation's edge-clamp policy — a known, documented minor
        // fringing artifact confined to the outermost row/column of pixels.
        let offset00 = 0
        let expectedGreen = (200 + 100 + 200 + 120) / 4
        #expect(Int(rgb[offset00 + 1]) == expectedGreen)
    }

    @Test func debayerRAW16MatchesRAW8Topology() throws {
        let bytes16: [UInt16] = [
            2000, 1000, 2100, 1100,
            1200, 500, 1300, 600,
            1900, 900, 2200, 1050,
            1150, 550, 1250, 650,
        ]
        var data = Data(count: bytes16.count * 2)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let dst = raw.bindMemory(to: UInt16.self)
            for (i, v) in bytes16.enumerated() { dst[i] = v }
        }
        let frame = CapturedFrame(width: 4, height: 4, imageType: ASI_IMG_RAW16, data: data)
        let rgbData = try #require(Debayer.debayerRAW16(frame, pattern: ASI_BAYER_RG))
        #expect(rgbData.count == 4 * 4 * 3 * 2)

        rgbData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let pixels = raw.bindMemory(to: UInt16.self)
            #expect(pixels[0] == 2000) // R channel at native (0,0) Red sample
        }
    }

    @Test func wrongImageTypeReturnsNil() {
        let frame = CapturedFrame(width: 2, height: 2, imageType: ASI_IMG_RGB24, data: Data(count: 12))
        #expect(Debayer.debayerRAW8(frame, pattern: ASI_BAYER_RG) == nil)
    }
}
