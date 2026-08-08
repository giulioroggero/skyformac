import AVFoundation
import CoreVideo
import Foundation

/// A secondary video source — a webcam, or an iPhone via Continuity Camera — used as an
/// all-sky/cloud/rig safety monitor embedded in the capture UI, independent of the ZWO ASI
/// camera pipeline entirely. Built on plain `AVFoundation`: a nearby iPhone signed into the same
/// Apple ID shows up as a completely ordinary `AVCaptureDevice` once the app opts in to
/// `AVCaptureDeviceTypeContinuityCamera` (via the `NSCameraUseContinuityCameraDeviceType`
/// Info.plist key) — no special "Continuity Camera SDK" beyond that.
///
/// Beyond the bare PiP feed, this also runs a lightweight per-frame analysis (`AllSkyAnalyzer`)
/// via `AVCaptureVideoDataOutput`: a rolling brightness baseline flags sudden cloud cover or an
/// incoming light source, and frame-to-frame differencing flags motion (a cable snag, a bump).
@MainActor
final class AllSkyMonitor: NSObject, ObservableObject {
    @Published private(set) var availableDevices: [AVCaptureDevice] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastErrorMessage: String?

    @Published private(set) var currentBrightness: Double = 0
    @Published private(set) var brightnessBaseline: Double?
    @Published private(set) var isCloudOrLightAlert = false
    @Published private(set) var isMotionAlert = false

    let session = AVCaptureSession()
    private var currentInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "com.maczwo.allsky.analysis")
    private let sampleBufferHandler = SampleBufferHandler()

    override init() {
        super.init()
        session.sessionPreset = .medium // this is a safety monitor, not a science instrument
        sampleBufferHandler.onAnalysis = { [weak self] brightness, motionScore in
            Task { @MainActor in self?.applyAnalysis(brightness: brightness, motionScore: motionScore) }
        }
    }

    /// Discovers cameras: built-in/external webcams, and Continuity Camera (iPhone) sources.
    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        availableDevices = discovery.devices
    }

    func start(with device: AVCaptureDevice) {
        stop()
        lastErrorMessage = nil
        brightnessBaseline = nil
        sampleBufferHandler.reset()

        let deviceID = device.uniqueID
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.lastErrorMessage = "Camera access was denied — check System Settings > Privacy & Security > Camera."
                    return
                }
                guard let resolvedDevice = AVCaptureDevice(uniqueID: deviceID) else {
                    self.lastErrorMessage = "The selected camera is no longer available."
                    return
                }
                self.beginSession(with: resolvedDevice)
            }
        }
    }

    private func beginSession(with device: AVCaptureDevice) {
        do {
            let input = try AVCaptureDeviceInput(device: device)
            session.beginConfiguration()
            if let currentInput { session.removeInput(currentInput) }
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                lastErrorMessage = "Could not use \(device.localizedName) as a video source."
                return
            }
            session.addInput(input)
            currentInput = input

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(sampleBufferHandler, queue: analysisQueue)
            if session.outputs.contains(videoOutput) { session.removeOutput(videoOutput) }
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

            session.commitConfiguration()

            session.startRunning()
            isRunning = true
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()
        isRunning = false
    }

    private func applyAnalysis(brightness: Double, motionScore: Double) {
        currentBrightness = brightness
        if brightnessBaseline == nil {
            brightnessBaseline = brightness
        } else if let baseline = brightnessBaseline {
            // Slow exponential moving average, so the baseline drifts with e.g. dawn/dusk but
            // doesn't itself get fooled by the very cloud/light event we're trying to detect.
            brightnessBaseline = baseline * 0.98 + brightness * 0.02
        }
        isCloudOrLightAlert = AllSkyAnalyzer.isCloudOrLightAlert(
            currentBrightness: brightness, baseline: brightnessBaseline ?? brightness
        )
        isMotionAlert = AllSkyAnalyzer.isMotionAlert(score: motionScore)
    }
}

/// `AVCaptureVideoDataOutputSampleBufferDelegate` runs on an arbitrary queue, not `@MainActor`,
/// so this is a plain (non-isolated) `NSObject` — it extracts a coarse downsampled grayscale
/// buffer from each frame and hands the pure analysis off to `AllSkyAnalyzer`, then reports back
/// to `AllSkyMonitor` via a closure hop to the main actor.
private final class SampleBufferHandler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onAnalysis: (@Sendable (Double, Double) -> Void)?
    private var previousSamples: [UInt8]?
    private let lock = NSLock()

    func reset() {
        lock.lock()
        previousSamples = nil
        lock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = base.assumingMemoryBound(to: UInt8.self)
        let stride = 8 // coarse downsample — this is a safety monitor, not photometry

        var samples: [UInt8] = []
        samples.reserveCapacity((width / stride) * (height / stride))
        for y in Swift.stride(from: 0, to: height, by: stride) {
            let rowStart = y * bytesPerRow
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let pixelOffset = rowStart + x * 4 // BGRA
                let b = Int(buffer[pixelOffset])
                let g = Int(buffer[pixelOffset + 1])
                let r = Int(buffer[pixelOffset + 2])
                samples.append(UInt8((r + g + b) / 3))
            }
        }

        let brightness = AllSkyAnalyzer.averageBrightness(samples)
        lock.lock()
        let motionScore = previousSamples.map { AllSkyAnalyzer.motionScore(current: samples, previous: $0) } ?? 0
        previousSamples = samples
        lock.unlock()

        onAnalysis?(brightness, motionScore)
    }
}
