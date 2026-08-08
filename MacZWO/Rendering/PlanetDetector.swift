import CoreGraphics
import Vision

/// Finds the largest bright disk in a preview image — reuses `VNDetectContoursRequest` (the same
/// real Vision API `StarDetector` uses for point sources) but selects the single biggest contour
/// instead of many small ones, since a planet is one large, roughly-round, bright blob rather
/// than a field of point sources.
enum PlanetDetector {
    /// Normalized (Vision convention: bottom-left origin) bounding box covering the detected
    /// disk, or `nil` if nothing qualifies (e.g. pointed at empty sky).
    ///
    /// - Implementation note: a planet's own surface detail (Jupiter's cloud bands, sunspots,
    ///   lunar terminator) produces *multiple* separate internal contours rather than one clean
    ///   outer-edge contour — verified against synthetic banded-disk test frames, where picking
    ///   "the single largest contour" consistently missed the disk entirely (every individual
    ///   band-edge contour is long and thin, so none pass a combined width-and-height size
    ///   filter). Unioning every non-trivial contour's bounding box is far more robust: whatever
    ///   internal texture Vision breaks the disk into, their combined extent still approximates
    ///   the disk as a whole.
    static func detectDisk(in image: CGImage, minimumIndividualFraction: CGFloat = 0.0005) throws -> CGRect? {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = false
        request.maximumImageDimension = 512

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }

        var union = CGRect.null
        for contour in observation.topLevelContours {
            let box = contour.normalizedPath.boundingBoxOfPath
            guard box.width * box.height >= minimumIndividualFraction else { continue }
            union = union.union(box)
        }
        return union.isNull ? nil : union
    }
}
