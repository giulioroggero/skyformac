import Accelerate
import AVFoundation
import CoreVideo
import Foundation

/// Reads an ordinary imported video file (`.mov`/`.mp4`/`.m4v` — a phone/camera recording, not
/// this app's own `.ser` planetary format) into the same shape `SERReader.read(from:)` produces,
/// so `PlanetaryPostProcessor`'s existing registration/stacking pipeline can "Post-Process…" an
/// imported video exactly the way it already does a `.ser` capture. Every frame decodes to
/// `ASI_IMG_RGB24` — the pipeline already passes that straight through with no debayer step (see
/// its own `case ASI_IMG_RGB24` branch in `PlanetaryPostProcessor.scoreAndRegister`), so nothing
/// downstream needs to know these frames came from an ordinary video file rather than a Bayer
/// sensor. The BGRA -> RGB24 conversion (`vImageConvert_BGRA8888toRGB888`) is the exact technique
/// `WebcamCaptureEngine`'s own sample-buffer forwarder already uses for a live Continuity Camera
/// feed — proven correct there, reused verbatim here for a file instead of a live capture session.
enum VideoFrameReader {
    enum VideoError: Error {
        case noVideoTrack
        case unreadableFrame
    }

    static func read(from url: URL) throws -> SERReader.ParsedSER {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw VideoError.noVideoTrack }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw VideoError.unreadableFrame }

        var frames: [CapturedFrame] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), let frame = makeFrame(from: pixelBuffer)
            else { continue }
            frames.append(frame)
        }
        guard reader.status == .completed, !frames.isEmpty else { throw VideoError.unreadableFrame }
        let width = frames[0].width
        let height = frames[0].height
        return SERReader.ParsedSER(
            width: width, height: height, imageType: ASI_IMG_RGB24,
            isColorCamera: true, bayerPattern: ASI_BAYER_RG, frames: frames
        )
    }

    private static func makeFrame(from pixelBuffer: CVPixelBuffer) -> CapturedFrame? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        var srcBuffer = vImage_Buffer(
            data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow
        )
        let conversionError = rgb.withUnsafeMutableBytes { destBytes -> vImage_Error in
            var destBuffer = vImage_Buffer(
                data: destBytes.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 3
            )
            return vImageConvert_BGRA8888toRGB888(&srcBuffer, &destBuffer, vImage_Flags(kvImageNoFlags))
        }
        guard conversionError == kvImageNoError else { return nil }
        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RGB24, data: Data(rgb))
    }
}
