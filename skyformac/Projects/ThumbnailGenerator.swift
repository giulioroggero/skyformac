import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Downscales a `CGImage` (whatever was just exported/recorded — the same debayered/stretched
/// preview image, not raw sensor data) into a small JPEG for a session's timeline —
/// `ProjectStore.recordCapture` writes the result alongside each capture. A real image-decode
/// pass over a multi-megapixel FITS/PNG/TIFF file every time it's shown in a timeline would be
/// wasteful; generating one small file once, at save time, is the same "cheap to display many
/// times over" reasoning any photo app's own thumbnail cache uses.
enum ThumbnailGenerator {
    /// Longest edge of a generated thumbnail — comfortably enough detail to recognize what a
    /// capture was of in a timeline strip, small enough that hundreds of them across a project's
    /// full history stay a trivial amount of disk space (a few KB each as JPEG).
    static let maxDimension = 240

    /// `nil` if `image` has no pixels to scale (shouldn't happen for a real capture, but a
    /// zero-size `CGImage` isn't representable as a smaller one) or JPEG encoding itself fails.
    static func makeThumbnail(from image: CGImage) -> Data? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        let width = max(1, Int(Double(image.width) * min(scale, 1)))
        let height = max(1, Int(Double(image.height) * min(scale, 1)))

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
