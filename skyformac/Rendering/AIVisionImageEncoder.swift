import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Downscales a `CGImage` to JPEG `Data` for sending to a vision-capable AI provider — the same
/// "scale down, then `CGImageDestination` JPEG encode" shape as `ThumbnailGenerator.makeThumbnail`,
/// just sized for a model to actually make out real detail (noise, star bloat, gradient, color
/// cast) rather than a session-timeline thumbnail's much smaller "just recognizable" target.
enum AIVisionImageEncoder {
    /// Longest edge sent to the model — comfortably enough resolution to judge noise/sharpness/
    /// color cast, small enough to stay well under every provider's own payload limits and keep
    /// round-trip latency reasonable.
    static let maxDimension = 1024

    /// `nil` if `image` has no pixels to scale, or JPEG encoding itself fails.
    static func jpegData(from image: CGImage, quality: CGFloat = 0.85) -> Data? {
        guard image.width > 0, image.height > 0 else { return nil }
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
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
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
