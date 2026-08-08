import CoreGraphics
import Vision

/// A detected star, in normalized (0...1, origin bottom-left per Vision convention) image
/// coordinates.
struct DetectedStar: Identifiable, Sendable {
    let id = UUID()
    let boundingBoxNormalized: CGRect
}

struct FocusAssistResult: Sendable {
    let stars: [DetectedStar]
    /// Smaller is sharper: the median star bounding-box diagonal, in pixels. `nil` if no stars
    /// were detected (nothing to focus on, or focus is so far off nothing is a point source yet).
    let medianStarDiameterPixels: Double?
}

/// Live focus-assist star detection using Vision's `VNDetectContoursRequest` — a general-purpose,
/// on-device, no-network "AI" building block repurposed here as a lightweight star/point-source
/// detector: bright, roughly-round blobs on the dark preview background are exactly what a
/// contour detector picks out well, and it needs no custom model or training data.
enum StarDetector {
    /// Runs contour detection on `image` and returns star-like contours (small, present, and
    /// non-degenerate). Performs Vision's (synchronous, potentially slow) request handler off
    /// the caller's thread — call this from a background `Task`, never from `@MainActor`.
    static func detectStars(in image: CGImage) throws -> FocusAssistResult {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 3.0
        request.detectsDarkOnLight = false // stars are bright blobs on a dark sky background
        request.maximumImageDimension = 768

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            return FocusAssistResult(stars: [], medianStarDiameterPixels: nil)
        }

        let width = Double(image.width)
        let height = Double(image.height)
        var stars: [DetectedStar] = []
        var diametersPixels: [Double] = []

        for contour in observation.topLevelContours {
            let box = contour.normalizedPath.boundingBoxOfPath
            // Reject anything that isn't a small, roughly point-like blob: stars are small in
            // frame and roughly as wide as they are tall. Large/irregular contours are noise,
            // gradients, or the frame border itself.
            guard box.width < 0.2, box.height < 0.2, box.width > 0, box.height > 0 else { continue }
            let aspect = box.width / box.height
            guard aspect > 0.4, aspect < 2.5 else { continue }

            stars.append(DetectedStar(boundingBoxNormalized: box))
            let dx = Double(box.width) * width
            let dy = Double(box.height) * height
            diametersPixels.append((dx * dx + dy * dy).squareRoot())
        }

        diametersPixels.sort()
        let median = diametersPixels.isEmpty ? nil : diametersPixels[diametersPixels.count / 2]
        return FocusAssistResult(stars: stars, medianStarDiameterPixels: median)
    }
}
