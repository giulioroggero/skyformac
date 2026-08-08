import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Exports the already-rendered, stretched display image (a `CGImage` from `CGImageRenderer`)
/// as a shareable PNG or TIFF — the "pretty picture" counterpart to `FITSWriter`'s raw
/// scientific data export.
enum ImageExporter {
    enum ExportError: Error {
        case destinationCreationFailed
        case finalizationFailed
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try write(image, to: url, type: .png)
    }

    static func writeTIFF(_ image: CGImage, to url: URL) throws {
        try write(image, to: url, type: .tiff)
    }

    private static func write(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ExportError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.finalizationFailed
        }
    }
}
