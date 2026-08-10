import Accelerate
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

    /// Fired if the session stops unexpectedly (device unplugged, runtime error).
    var onDisconnect: (@MainActor () -> Void)?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sampleBufferHandler = WebcamSampleBufferForwarder()
    /// Every touch of `session`/`videoOutput`/`device` (configuration, start, stop) happens here
    /// — including the delegate callback queue — never on the main actor. `AVCaptureSession` and
    /// `AVCaptureDevice` aren't `Sendable`, so this class opts out of automatic checking
    /// (`@unchecked Sendable`) and enforces single-queue access by hand instead.
    private let sessionQueue = DispatchQueue(label: "com.skyformac.webcam.session")
    /// Guarded by `continuationLock`, not `sessionQueue` — `frames()` is called from the main
    /// actor (`CameraManager.connectToWebcam`/`resumeLiveView`) and needs the swap to take effect
    /// immediately, not whenever `sessionQueue` next happens to be free. `sessionQueue` is also
    /// the `AVCaptureVideoDataOutput` delegate queue, so it's continuously busy converting frames
    /// (`WebcamSampleBufferForwarder.captureOutput`'s BGRA->RGB loop) the whole time the session
    /// runs; a `sessionQueue.async` reassignment queued behind that had no guaranteed turnaround
    /// and was observed to never run at all across an entire `resumeLiveView()` session in
    /// practice — `next()` on a `bufferingNewest` stream doesn't pull from `sessionQueue`, so
    /// nothing ever forced it to drain. A lock makes the swap synchronous instead.
    private let continuationLock = NSLock()
    private var continuation: AsyncStream<CapturedFrame>.Continuation?

    init(device: AVCaptureDevice) {
        self.device = device
        sampleBufferHandler.onFrame = { [weak self] frame in
            guard let self else { return }
            let current = continuationLock.withLock { self.continuation }
            current?.yield(frame)
        }
        sampleBufferHandler.onDisconnect = { [weak self] in
            Task { @MainActor in self?.onDisconnect?() }
        }
    }

    /// Live frame stream for the connected webcam. Buffers only the newest frame: if the consumer
    /// (the main-actor `CameraManager.ingest` pipeline, forced onto the slow CPU render path for
    /// webcam frames — see `connectToWebcam`) hasn't picked up the previous frame yet, an
    /// incoming one replaces it instead of queuing behind it.
    ///
    /// This is deliberately unlike the old design, which handed each frame to the main actor via
    /// its own unstructured `Task`. A `.high`-preset webcam delivers frames (30-60fps) far faster
    /// than that CPU path can render them, so those Tasks piled up faster than they drained —
    /// each holding a full converted frame's `Data` — and both memory and CPU grew without bound
    /// until the app stopped responding entirely, including to Cmd-Q, because the main actor
    /// never got a chance to drain the backlog. `bufferingNewest(1)` here gives the same
    /// single-consumer, pull-based shape `CaptureEngine.frames()` already uses for real ZWO
    /// cameras, so a slow renderer just sees the source's effective frame rate drop instead.
    func frames() -> AsyncStream<CapturedFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { [self] continuation in
            continuationLock.withLock { self.continuation = continuation }
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

    /// Locks focus at whatever lens position autofocus currently sits at (`.locked` with no
    /// explicit lens position keeps the current one — real, documented `AVCaptureDevice`
    /// behavior, not a guess), or returns to continuous autofocus. Exists specifically because a
    /// webcam/Continuity Camera device's own continuous autofocus actively fights afocal
    /// projection (phone held to an eyepiece): it keeps hunting for a "normal" subject distance
    /// and refocuses away from the telescope's actual focal plane. Runs on `sessionQueue`, like
    /// every other touch of `device` — `lockForConfiguration()` is explicitly documented as a
    /// hardware-property lock, not something to call from an arbitrary thread.
    func setFocusLocked(_ locked: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [self] in
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    if locked {
                        guard device.isFocusModeSupported(.locked) else {
                            continuation.resume(throwing: WebcamCaptureError.controlUnsupported)
                            return
                        }
                        device.focusMode = .locked
                    } else if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    } else {
                        continuation.resume(throwing: WebcamCaptureError.controlUnsupported)
                        return
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fire-and-forget teardown on `sessionQueue` — callers (`CameraManager.disconnect()`) don't
    /// need to wait for it, and `disconnect()` itself is synchronous.
    func stop() {
        NotificationCenter.default.removeObserver(sampleBufferHandler)
        continuationLock.withLock {
            continuation?.finish()
            continuation = nil
        }
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
        }
    }
}

enum WebcamCaptureError: Error, CustomStringConvertible {
    case deviceUnavailable
    case controlUnsupported

    var description: String {
        switch self {
        case .deviceUnavailable:
            return "This camera is no longer available — it may have been unplugged or claimed by another app."
        case .controlUnsupported:
            // Genuinely possible for a Continuity Camera device specifically: Apple's bridge
            // exposes it as a webcam-shaped `AVCaptureDevice`, but that doesn't guarantee every
            // manual control a built-in camera supports is actually forwarded to the iPhone's
            // own camera hardware. If this fires here, it's `isFocusModeSupported` genuinely
            // reporting `false` for this device, not a bug in how it's called.
            return "This camera doesn't support this control."
        }
    }
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

        // `vImageConvert_BGRA8888toRGB888` — a real Accelerate/vImage function that does exactly
        // this conversion (BGRA source -> packed R,G,B destination, dropping alpha), vectorized.
        // The first version of this did the same conversion with a hand-written scalar Swift
        // loop over every pixel (bounds-checked array subscripts, one iteration per pixel) — for
        // a Continuity Camera `.high`-preset frame (1920x1080 = ~2.07M pixels), that's a real,
        // measurable amount of per-frame CPU work competing with everything else on
        // `sessionQueue`, and the reason iPhone/webcam live view specifically (never a ZWO
        // camera, which hands over already-packed RAW8/RAW16 with no such conversion needed)
        // wasn't fluid.
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        var srcBuffer = vImage_Buffer(
            data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow
        )
        let conversionError = rgb.withUnsafeMutableBytes { destBytes -> vImage_Error in
            var destBuffer = vImage_Buffer(
                data: destBytes.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width * 3
            )
            return vImageConvert_BGRA8888toRGB888(&srcBuffer, &destBuffer, vImage_Flags(kvImageNoFlags))
        }
        guard conversionError == kvImageNoError else { return }

        onFrame?(CapturedFrame(width: width, height: height, imageType: ASI_IMG_RGB24, data: Data(rgb)))
    }

    @objc func handleDisconnectNotification(_ notification: Notification) {
        onDisconnect?()
    }
}
