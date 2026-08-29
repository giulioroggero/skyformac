import Foundation
import Testing
@testable import skyformac

struct PHD2GuideLogParserTests {
    private static let sampleLog = """
    PHD2 version 2.6.11, Log version 2.5. Log enabled at 2023-05-01 22:00:00

    Guiding Begins at 2023-05-01 22:15:03
    Pixel scale = 1.500 arc-sec/px, Binning = 1, Focal length = 400 mm
    Frame,Time,mount,dx,dy,RARawDistance,DECRawDistance,RAGuideDistance,DECGuideDistance,RADuration,RADirection,DECDuration,DECDirection,XStep,YStep,StarMass,SNR,ErrorCode
    1,0.500,Mount,0.10,-0.20,0.10,-0.20,0.10,-0.20,50,W,40,S,1,2,50000,25.0,0
    2,3.500,Mount,0.15,-0.10,0.15,-0.10,0.15,-0.10,60,W,30,S,1,2,50000,26.0,0
    3,6.500,Mount,-0.05,0.05,-0.05,0.05,-0.05,0.05,20,E,15,N,1,2,50000,24.0,0
    Guiding Ends at 2023-05-01 23:00:00

    Guiding Begins at 2023-05-02 21:00:00
    Frame,Time,mount,dx,dy,RARawDistance,DECRawDistance,RAGuideDistance,DECGuideDistance,RADuration,RADirection,DECDuration,DECDirection,XStep,YStep,StarMass,SNR,ErrorCode
    1,1.000,Mount,0.20,0.20,0.20,0.20,0.20,0.20,50,W,40,S,1,2,50000,25.0,0
    Guiding Ends at 2023-05-02 21:30:00
    """

    @Test func parsesEverySeparateGuidingRunAsItsOwnSession() {
        let sessions = PHD2GuideLogParser.parse(Self.sampleLog)
        #expect(sessions.count == 2)
        #expect(sessions[0].frames.count == 3)
        #expect(sessions[1].frames.count == 1)
    }

    @Test func parsesTheStartTimestamp() {
        let sessions = PHD2GuideLogParser.parse(Self.sampleLog)
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: sessions[0].startedAt ?? Date(timeIntervalSince1970: 0))
        #expect(components.year == 2023 && components.month == 5 && components.day == 1)
        #expect(components.hour == 22 && components.minute == 15 && components.second == 3)
    }

    @Test func parsesThePixelScaleWhenPresent() {
        let sessions = PHD2GuideLogParser.parse(Self.sampleLog)
        #expect(sessions[0].pixelScaleArcsecPerPixel == 1.5)
        // The second session's own log excerpt never repeats the calibration line — real PHD2
        // logs only print it once per calibration, so it stays valid (and is carried forward)
        // until a recalibration line actually changes it, rather than resetting per session.
        #expect(sessions[1].pixelScaleArcsecPerPixel == 1.5)
    }

    @Test func parsesRARawDistanceAndDECRawDistancePreferentiallyOverDxDy() {
        let sessions = PHD2GuideLogParser.parse(Self.sampleLog)
        let firstFrame = sessions[0].frames[0]
        #expect(firstFrame.timeSeconds == 0.5)
        #expect(firstFrame.raDistance == 0.10)
        #expect(firstFrame.decDistance == -0.20)
    }

    @Test func ignoresUnparsableOrUnrelatedLinesWithoutCrashing() {
        let messyLog = "not a real log\n\(Self.sampleLog)\ntrailing garbage,1,2,3"
        let sessions = PHD2GuideLogParser.parse(messyLog)
        #expect(sessions.count == 2)
    }
}

struct PHD2GuideLogAnalyzerTests {
    @Test func statsComputeRMSAndOrthogonalityForASimpleSession() {
        let session = PHD2GuideLogSession(
            startedAt: nil, pixelScaleArcsecPerPixel: 1.5,
            frames: [
                .init(timeSeconds: 0, raDistance: 1, decDistance: -1),
                .init(timeSeconds: 1, raDistance: -1, decDistance: 1),
                .init(timeSeconds: 2, raDistance: 1, decDistance: -1),
                .init(timeSeconds: 3, raDistance: -1, decDistance: 1),
            ]
        )
        let stats = PHD2GuideLogAnalyzer.stats(for: session)
        #expect(stats.rmsRA == 1)
        #expect(stats.rmsDec == 1)
        #expect(stats.peakRA == 1)
        // RA and Dec are perfectly (anti-)correlated here by construction — orthogonality should
        // reflect that as -1, not 0.
        #expect(abs(stats.orthogonality - (-1)) < 0.0001)
    }

    @Test func orthogonalityIsZeroForTrulyIndependentAxes() {
        // A deliberately uncorrelated pair (RA alternates one way, Dec alternates a different,
        // unrelated way) — orthogonality should land near 0, not near ±1.
        let ra: [Double] = [1, -1, 1, -1, 1, -1, 1, -1]
        let dec: [Double] = [1, 1, -1, -1, 1, 1, -1, -1]
        let session = PHD2GuideLogSession(
            startedAt: nil, pixelScaleArcsecPerPixel: nil,
            frames: zip(ra, dec).enumerated().map { index, pair in .init(timeSeconds: Double(index), raDistance: pair.0, decDistance: pair.1) }
        )
        let stats = PHD2GuideLogAnalyzer.stats(for: session)
        #expect(abs(stats.orthogonality) < 0.0001)
    }

    @Test func periodogramPeaksAtTheInjectedPeriod() {
        // A pure 180-second sinusoid, sampled every 3 seconds for 30 minutes — the periodogram's
        // highest-power bin should land at (or immediately next to) 180s, not some other period in
        // the scanned 60...600s range.
        let period = 180.0
        var times: [Double] = []
        var values: [Double] = []
        var t = 0.0
        while t < 1800 {
            times.append(t)
            values.append(sin(2 * .pi * t / period))
            t += 3
        }
        let points = PHD2GuideLogAnalyzer.periodogram(times: times, values: values, minPeriodSeconds: 60, maxPeriodSeconds: 600, stepCount: 271)
        let peak = points.max { $0.power < $1.power }
        #expect(peak != nil)
        #expect(abs((peak?.periodSeconds ?? 0) - period) < 5)
    }

    @Test func periodogramReturnsEmptyForTooFewSamples() {
        let points = PHD2GuideLogAnalyzer.periodogram(times: [0, 1], values: [1, 2])
        #expect(points.isEmpty)
    }
}
