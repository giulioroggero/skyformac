import Foundation

/// Selectable demo-mode targets, for exercising the whole app with no hardware attached — like
/// `TestPatternGenerator`'s gradient/star pattern, but modeling recognizable solar-system and
/// deep-sky targets (using real positions/magnitudes from `SkyCatalog` where applicable) instead
/// of an abstract test card.
enum DemoTarget: Hashable, Identifiable {
    case jupiter
    case saturn
    case mars
    case starField
    case deepSky(SkyCatalogObject)

    var id: String {
        switch self {
        case .jupiter: return "jupiter"
        case .saturn: return "saturn"
        case .mars: return "mars"
        case .starField: return "starField"
        case .deepSky(let object): return object.id
        }
    }

    var displayName: String {
        switch self {
        case .jupiter: return "Jupiter"
        case .saturn: return "Saturn"
        case .mars: return "Mars"
        case .starField: return "Star Field (bright stars)"
        case .deepSky(let object): return "\(object.displayName) (\(object.objectType))"
        }
    }

    /// A representative sample of Messier deep-sky objects, spanning nebulae, clusters and
    /// galaxies, for the demo picker — not the full 110-object catalog (`SkyCatalog.messierObjects`
    /// has all of them, if a future picker wants the whole list).
    static var deepSkyShowcase: [DemoTarget] {
        let ids = ["M1", "M8", "M13", "M27", "M31", "M42", "M45", "M57", "M51", "M104"]
        return SkyCatalog.messierObjects
            .filter { ids.contains($0.id) }
            .sorted { ids.firstIndex(of: $0.id)! < ids.firstIndex(of: $1.id)! }
            .map { .deepSky($0) }
    }

    /// The true pointing/FOV of the field this target renders into, for `SkyHUDView`
    /// (spec/MacZWO_Catalog_HUD_Spec.md) — this app has no blind plate solver (see
    /// `StarPatternRecognizer`'s doc comment), so a `WCSFrame` only exists where the ground truth
    /// is known by construction: demo targets pinned to real sky coordinates. Planets are
    /// procedural, not sky-positioned (see `DemoTargetGenerator`'s doc comment), so they have none.
    ///
    /// `rotationRadians: .pi` reproduces `DemoTargetGenerator.project`'s own sign convention
    /// (+RA → +x, +Dec → -y) exactly: at θ=π, the spec's projection matrix reduces to
    /// `x = Xc + ξ/s, y = Yc - η/s`, which is that same mapping.
    func groundTruthWCS(width: Int, height: Int) -> WCSFrame? {
        switch self {
        case .jupiter, .saturn, .mars:
            return nil
        case .starField:
            // Mirrors `DemoTargetGenerator.starField`'s own centerRA/centerDec/fovDegrees.
            let fovRadians = 25.0 * .pi / 180
            return WCSFrame(
                centerRADeg: 30.0, centerDecDeg: 80.0,
                radiansPerPixel: fovRadians / Double(width),
                rotationRadians: .pi, imageWidth: width, imageHeight: height
            )
        case .deepSky(let object):
            // Mirrors `DemoTargetGenerator.deepSky`'s own assumedFOVArcmin, and its choice to
            // always center the frame exactly on the target object.
            let assumedFOVRadians = (60.0 / 60.0) * .pi / 180
            return WCSFrame(
                centerRADeg: object.raDegrees, centerDecDeg: object.decDegrees,
                radiansPerPixel: assumedFOVRadians / Double(min(width, height)),
                rotationRadians: .pi, imageWidth: width, imageHeight: height
            )
        }
    }
}

/// Renders `DemoTarget`s as synthetic `CapturedFrame`s. Planets are procedural (banding,
/// oblateness, rings) rather than photographic — there's no telescope-view planet imagery to
/// source from the Stellarium repo (its `landscapes/{jupiter,saturn,...}` are surface panoramas
/// for standing on those bodies, not disk textures). Deep-sky objects render as a soft glow
/// scaled to the catalog's real angular size, embedded in a star field placed using real
/// magnitudes.
enum DemoTargetGenerator {
    static func generate(_ target: DemoTarget, width: Int, height: Int, animationPhase: Double = 0) -> CapturedFrame {
        switch target {
        case .jupiter:
            return planet(width: width, height: height, radiusFraction: 0.22, bandiness: 1.0, moonCount: 4, phase: animationPhase)
        case .saturn:
            return planet(width: width, height: height, radiusFraction: 0.16, bandiness: 0.4, moonCount: 1, ring: true, phase: animationPhase)
        case .mars:
            return planet(width: width, height: height, radiusFraction: 0.10, bandiness: 0.15, moonCount: 0, polarCap: true, phase: animationPhase)
        case .starField:
            return starField(width: width, height: height, phase: animationPhase)
        case .deepSky(let object):
            return deepSky(object, width: width, height: height, phase: animationPhase)
        }
    }

    // MARK: - Planets

    private static func planet(
        width: Int,
        height: Int,
        radiusFraction: Double,
        bandiness: Double,
        moonCount: Int,
        ring: Bool = false,
        polarCap: Bool = false,
        phase: Double
    ) -> CapturedFrame {
        var pixels = [UInt8](repeating: 8, count: width * height) // faint sky background, not pure black
        let cx = Double(width) / 2
        let cy = Double(height) / 2
        let radius = Double(min(width, height)) * radiusFraction
        let oblateness = 0.93 // Jupiter/Saturn are visibly flattened; a fine generic approximation

        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx
                let dy = (Double(y) - cy) / oblateness
                let r = (dx * dx + dy * dy).squareRoot()

                if ring, r > radius * 1.15, r < radius * 2.1, abs(dy) < radius * 0.35 {
                    pixels[y * width + x] = UInt8(clamping: 90 + Int(20 * sin(r)))
                    continue
                }
                guard r <= radius else { continue }

                let band = 1.0 + bandiness * 0.35 * sin(dy * 0.9 + phase)
                var brightness = 150.0 * band
                if polarCap, dy < -radius * 0.7 {
                    brightness += 60
                }
                let limbDarkening = 1.0 - 0.3 * (r / radius)
                pixels[y * width + x] = UInt8(clamping: Int(brightness * limbDarkening))
            }
        }

        for moonIndex in 0..<moonCount {
            let angle = phase * 0.3 + Double(moonIndex) * (2 * .pi / Double(max(moonCount, 1)))
            let distance = radius * (2.2 + Double(moonIndex) * 0.6)
            let mx = Int(cx + distance * cos(angle))
            let my = Int(cy + distance * sin(angle) * oblateness)
            drawGaussianBlob(into: &pixels, width: width, height: height, cx: Double(mx), cy: Double(my), peak: 180, sigma: 1.2)
        }

        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(pixels))
    }

    // MARK: - Star field (real magnitudes, tangent-plane projected)

    private static func starField(width: Int, height: Int, phase: Double) -> CapturedFrame {
        var pixels = [UInt8](repeating: 2, count: width * height)
        // Centered near Polaris. Note: `SkyCatalog.brightStars` are the sky's brightest stars
        // overall, scattered across the whole celestial sphere — not a real cluster — so only
        // whichever of them actually falls within this FOV (typically just Polaris itself, this
        // close to the pole) gets drawn with real position/magnitude data. The synthetic
        // "background stars" below are what actually make this a populated field to detect.
        let centerRA = 30.0
        let centerDec = 80.0
        let fovDegrees = 25.0

        for star in SkyCatalog.brightStars {
            guard let (x, y) = project(raDegrees: star.raDegrees, decDegrees: star.decDegrees,
                                        centerRA: centerRA, centerDec: centerDec, fovDegrees: fovDegrees,
                                        width: width, height: height) else { continue }
            // Brighter (lower/negative magnitude) stars get a bigger, more intense blob. Sigma is
            // deliberately much larger than a photometrically-realistic stellar PSF would be —
            // Vision's `VNDetectContoursRequest` (used by `StarDetector`/`PlanetDetector`) needs
            // several pixels of extent to trace a contour at all, especially after its own
            // internal downscaling; a 1-2px point (realistic for a real sensor) is invisible to
            // it. This is a demo/test target, not a simulated real exposure, so legibility to the
            // same detectors real frames go through wins over photometric accuracy.
            let peak = max(60.0, 255.0 - star.magnitude * 40.0)
            let sigma = max(3.0, 6.0 - star.magnitude * 0.4)
            drawGaussianBlob(into: &pixels, width: width, height: height, cx: x, cy: y, peak: peak, sigma: sigma)
        }

        // Randomly-but-deterministically placed synthetic stars — the actual bulk of this demo
        // field (see note above), bright and large enough for Vision's contour detector to
        // reliably pick up individually (verified during development: dimmer/smaller values here
        // previously left only ~1 detectable contour in the entire frame). Deterministic seed
        // keeps frames reproducible.
        var rng = SeededGenerator(seed: 1)
        for _ in 0..<40 {
            let x = Double.random(in: 20..<Double(width - 20), using: &rng)
            let y = Double.random(in: 20..<Double(height - 20), using: &rng)
            let peak = Double.random(in: 120...240, using: &rng)
            let sigma = Double.random(in: 2.5...5.0, using: &rng)
            drawGaussianBlob(into: &pixels, width: width, height: height, cx: x, cy: y, peak: peak, sigma: sigma)
        }

        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(pixels))
    }

    // MARK: - Deep-sky objects

    private static func deepSky(_ object: SkyCatalogObject, width: Int, height: Int, phase: Double) -> CapturedFrame {
        var pixels = [UInt8](repeating: 2, count: width * height)
        let cx = Double(width) / 2
        let cy = Double(height) / 2

        // Scale the catalog's real angular size (arcmin) into pixels using an assumed FOV, so
        // bigger objects (e.g. M31 at ~190') visibly fill more of the frame than compact ones
        // (e.g. M57 at ~1.5').
        let assumedFOVArcmin = 60.0
        let majorAxis = object.majorAxisArcmin ?? 10
        let pixelRadius = max(6.0, (majorAxis / assumedFOVArcmin) * Double(min(width, height)) / 2)

        switch object.objectType {
        case "Globular Cluster", "Open Cluster", "Cluster", "Star Cloud", "Cluster with Nebulosity":
            var rng = SeededGenerator(seed: UInt64(abs(object.id.hashValue)))
            let starCount = object.objectType == "Globular Cluster" ? 400 : 60
            for _ in 0..<starCount {
                let angle = Double.random(in: 0..<(2 * .pi), using: &rng)
                // Denser toward the center for globulars, more uniform for open clusters.
                let falloff = object.objectType == "Globular Cluster" ? 0.35 : 0.9
                let r = pixelRadius * pow(Double.random(in: 0...1, using: &rng), 1 / falloff)
                let x = cx + r * cos(angle)
                let y = cy + r * sin(angle)
                drawGaussianBlob(into: &pixels, width: width, height: height, cx: x, cy: y,
                                  peak: Double.random(in: 60...220, using: &rng), sigma: 0.8)
            }
        default: // nebulae, galaxies: soft extended glow
            drawGaussianBlob(into: &pixels, width: width, height: height, cx: cx, cy: cy,
                              peak: 140, sigma: max(4, pixelRadius / 2.2))
            var rng = SeededGenerator(seed: UInt64(abs(object.id.hashValue)))
            for _ in 0..<30 {
                let x = Double.random(in: (cx - pixelRadius)...(cx + pixelRadius), using: &rng)
                let y = Double.random(in: (cy - pixelRadius)...(cy + pixelRadius), using: &rng)
                drawGaussianBlob(into: &pixels, width: width, height: height, cx: x, cy: y,
                                  peak: Double.random(in: 100...255, using: &rng), sigma: 0.9)
            }
        }

        return CapturedFrame(width: width, height: height, imageType: ASI_IMG_RAW8, data: Data(pixels))
    }

    // MARK: - Shared helpers

    /// Small-angle tangent-plane projection, adequate for a demo field of view — not a
    /// precision astrometric projection (no attempt at true gnomonic distortion). Both axes are
    /// scaled by `width` (not `height` for `dDec`) so the pixel scale is isotropic — matching
    /// `WCSFrame`'s single-scalar `radiansPerPixel` (`DemoTarget.groundTruthWCS`), which is what
    /// lets `SkyHUDView`'s catalog badges land exactly on the real stars drawn here.
    private static func project(
        raDegrees: Double, decDegrees: Double,
        centerRA: Double, centerDec: Double, fovDegrees: Double,
        width: Int, height: Int
    ) -> (Double, Double)? {
        let dRA = (raDegrees - centerRA) * cos(centerDec * .pi / 180)
        let dDec = decDegrees - centerDec
        guard abs(dRA) < fovDegrees / 2, abs(dDec) < fovDegrees / 2 else { return nil }
        let x = Double(width) / 2 + (dRA / fovDegrees) * Double(width)
        let y = Double(height) / 2 - (dDec / fovDegrees) * Double(width)
        return (x, y)
    }

    private static func drawGaussianBlob(
        into pixels: inout [UInt8], width: Int, height: Int,
        cx: Double, cy: Double, peak: Double, sigma: Double
    ) {
        let radius = Int(sigma * 4) + 1
        let minX = max(0, Int(cx) - radius)
        let maxX = min(width - 1, Int(cx) + radius)
        let minY = max(0, Int(cy) - radius)
        let maxY = min(height - 1, Int(cy) + radius)
        guard minX <= maxX, minY <= maxY else { return }

        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let value = peak * exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
                let index = y * width + x
                pixels[index] = UInt8(clamping: Int(pixels[index]) + Int(value))
            }
        }
    }
}

/// Deterministic seeded RNG (a simple splitmix64) so demo frames are reproducible run-to-run —
/// `Double.random(using:)` needs a `RandomNumberGenerator`, and the system default isn't seedable.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
