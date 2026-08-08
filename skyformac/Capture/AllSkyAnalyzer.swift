import Foundation

/// Pure, camera-independent logic behind `AllSkyMonitor`'s cloud/motion alerts — separated out
/// so it's directly unit-testable without a real `CVPixelBuffer`/`AVCaptureSession`, which can't
/// be exercised headlessly. `AllSkyMonitor` itself just extracts downsampled luma bytes from
/// each video frame and hands them here.
enum AllSkyAnalyzer {
    /// Mean brightness (0...255) of a downsampled grayscale sample of a frame.
    static func averageBrightness(_ samples: [UInt8]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
    }

    /// Mean absolute per-sample difference between two same-sized downsampled frames — a coarse
    /// but cheap motion/disturbance score (a static all-sky view should hover near zero; a cable
    /// snag, bump, or passing headlight sweep spikes it).
    static func motionScore(current: [UInt8], previous: [UInt8]) -> Double {
        guard current.count == previous.count, !current.isEmpty else { return 0 }
        var total = 0
        for i in 0..<current.count {
            total += abs(Int(current[i]) - Int(previous[i]))
        }
        return Double(total) / Double(current.count)
    }

    /// A brightness ratio far from 1.0 against a rolling baseline suggests either sudden cloud
    /// cover (much dimmer — the stars/baseline sky glow got blocked) or a light source enter the
    /// frame (much brighter — headlights, a door opening, moonrise).
    static func isCloudOrLightAlert(currentBrightness: Double, baseline: Double, ratioThreshold: Double = 0.5) -> Bool {
        guard baseline > 1 else { return false }
        let ratio = currentBrightness / baseline
        return ratio < ratioThreshold || ratio > (1 / ratioThreshold)
    }

    static func isMotionAlert(score: Double, threshold: Double = 15) -> Bool {
        score > threshold
    }
}
