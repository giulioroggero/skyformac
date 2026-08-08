import AVFoundation
import CoreVideo
import Foundation

/// Lets an iPhone/iPad (Continuity Camera, wired over USB or wireless) or any other AVFoundation
/// webcam act as a full alternative to a ZWO ASI camera: same `CapturedFrame` stream, same
/// `CameraManager.ingest` pipeline (debayer/stretch, histogram, live stacking, HUD, export) — just
/// sourced from `AVCaptureVideoDataOutput` instead of the ZWO SDK's poll loop. Typical use: an
/// iPhone held to a telescope eyepiece (afocal projection) for lunar/planetary shots.
///
/// Structured like `AllSkyMonitor` (same discovery, same `NSCameraUseContinuityCameraDeviceType`
/// opt-in) but produces full-resolution frames for the main capture pipeline instead of a
/// downsampled brightness/motion signal.
///
/// - Important: NOT `@MainActor`, unlike `AllSkyMonitor`. Apple's docs are explicit that
///   `AVCaptureSession.startRunning()` blocks the calling thread, and for Continuity Camera that
///   can mean several seconds of pairing/negotiation (worse the first time, or over a fresh USB
///   connection) — long enough that calling it on the main actor freezes the whole app, not just
///   this feature, for that entire duration. `AllSkyMonitor` accepts that tradeoff for its
///   secondary, lower-stakes PiP monitor; it's not acceptable for the primary capture path this
///   engine serves, so all session work happens on `sessionQueue` instead, and `start()` is
///   `async` — it resumes once configuration finishes and `startRunning()` has been issued, not
///   once frames are actually flowing.
///
/// - Important: Frames arrive already debayered/color-processed by the device's own ISP, so they
///   carry no raw Bayer data the way an actual ASI sensor's output does — see
///   `ZWOCameraInfo.external`'s doc comment for why they're always handed off as `ASI_IMG_RGB24`.
final class WebcamCaptureEngine: @unchecked Sendable {
    let device: AVCaptureDevice

    /// Fired on the main actor with each converted frame.
    var onFrame: (@MainActor (CapturedFrame) -> Void)?
    /// Fired if the session stops unexpectedly (device unplugged, runtime error).
    var onDisconnect: (@MainActor () -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleBufferHandler = WebcamSampleBufferForwarder()
    /// Every touch of `session`/`videoOutput`/`device` (configuration, start, stop) happens here
    /// — including the delegate callback queue — never on the main actor. `AVCaptureSession` and
    /// `AVCaptureDevice` aren't `Sendable`, so this class opts out of automatic checking
    /// (`@unchecked Sendable`) and enforces single-queue access by hand instead.
    private let sessionQueue = DispatchQueue(label: "com.maczwo.webcam.session")

    init(device: AVCaptureDevice) {
        self.device = device
        sampleBufferHandler.onFrame = { [weak self] frame in
            Task { @MainActor in self?.onFrame?(frame) }
        }
        sampleBufferHandler.onDisconnect = { [weak self] in
            Task { @MainActor in self?.onDisconnect?() }
        }
    }

    /// Discovers cameras beyond the display's own camera: Continuity Camera (iPhone/iPad, wired
    /// or wireless) and any other external/USB webcam.
    static func discoverDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Configures and starts streaming, entirely on `sessionQueue`. Throws if the device can no
    /// longer be added as an input/output (e.g. it was unplugged between discovery and connect,
    /// or is already claimed by another app).
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try configureAndStartLocked()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Must only run on `sessionQueue`.
    private func configureAndStartLocked() throws {
        session.beginConfiguration()
        // `.high` rather than `AllSkyMonitor`'s `.medium` — this is the primary capture source
        // for actual astrophotography, not a low-stakes safety monitor.
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw WebcamCaptureError.deviceUnavailable
        }
        session.addInput(input)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(sampleBufferHandler, queue: sessionQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw WebcamCaptureError.deviceUnavailable
        }
        session.addOutput(videoOutput)
        session.commitConfiguration()

        NotificationCenter.default.addObserver(
            sampleBufferHandler, selector: #selector(WebcamSampleBufferForwarder.handleDisconnectNotification),
            name: AVCaptureSession.runtimeErrorNotification, object: session
        )
        NotificationCenter.default.addObserver(
            sampleBufferHandler, selector: #selector(WebcamSampleBufferForwarder.handleDisconnectNotification),
            name: .AVCaptureDeviceWasDisconnected, object: device
        )

        session.startRunning() // blocking (per Apple's docs), but off the main actor/thread now
    }

    /// Fire-and-forget teardown on `sessionQueue` — callers (`CameraManager.disconnect()`) don't
    /// need to wait for it, and `disconnect()` itself is synchronous.
    func stop() {
        NotificationCenter.default.removeObserver(sampleBufferHandler)
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
        }
    }
}

enum WebcamCaptureError: Error {
    case deviceUnavailable
}

/// `AVCaptureVideoDataOutputSampleBufferDelegate` runs on an arbitrary (non-main-actor) queue —
/// this converts each frame (BGRA -> RGB24, matching `CapturedFrame`'s documented RGB24 byte
/// order) and hands it back to `WebcamCaptureEngine` via a closure hop, mirroring
/// `AllSkyMonitor.SampleBufferHandler`.
private final class WebcamSampleBufferForwarder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (CapturedFrame) -> Void)?
    var onDisconnect: (@Sendable () -> Void)?

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
        let source = base.assumingMemoryBound(to: UInt8.self)

        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgb.withUnsafeMutableBufferPointer { dest in
            for y in 0..<height {
                let rowStart = y * bytesPerRow
                var destOffset = y * width * 3
                for x in 0..<width {
                    let pixelOffset = rowStart + x * 4 // BGRA
                    dest[destOffset] = source[pixelOffset + 2]     // R
                    dest[destOffset + 1] = source[pixelOffset + 1] // G
                    dest[destOffset + 2] = source[pixelOffset]     // B
                    destOffset += 3
                }
            }
        }

        onFrame?(CapturedFrame(width: width, height: height, imageType: ASI_IMG_RGB24, data: Data(rgb)))
    }

    @objc func handleDisconnectNotification(_ notification: Notification) {
        onDisconnect?()
    }
}
