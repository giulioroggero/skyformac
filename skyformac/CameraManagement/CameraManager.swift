import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications

enum ExportKind {
    case fits
    case png
    case tiff
}

enum PolarAlignmentStage: Equatable {
    case idle
    case firstFrameCaptured
    case complete
}

struct SmartExposureRecommendation: Sendable {
    let readNoiseElectrons: Double
    let skyRateElectronsPerSecond: Double
    let recommendedSubExposureSeconds: Double
}

enum CameraConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case streaming
    case error(String)
}

/// Owns camera discovery, lifecycle (open/init/close), and the dynamic control set for the
/// currently connected camera. Runs on `@MainActor` since it drives SwiftUI state directly,
/// but every ZWO SDK call it makes is dispatched into a background `Task` / the `CaptureEngine`
/// actor — this type itself never blocks the main thread on a `ZWOSDK` call.
@Observable
@MainActor
final class CameraManager {
    private(set) var availableCameras: [ZWOCameraInfo] = []
    /// Non-ZWO video sources — Continuity Camera (iPhone/iPad) or any other AVFoundation webcam —
    /// discovered separately from `availableCameras` since the connect/control surface is
    /// entirely different (see `WebcamCaptureEngine`/`connectToWebcam`).
    private(set) var availableWebcams: [AVCaptureDevice] = []
    private(set) var connectedCamera: ZWOCameraInfo?
    /// `true` while a real `WebcamCaptureEngine` source (iPhone/webcam) is connected — lets the
    /// UI offer a way back to the real "no camera connected" state, since webcam sources never
    /// show up in `availableCameras` for `CameraListView`'s per-row Disconnect button to attach
    /// to (see `ZWOCameraInfo.external`'s cameraID doc comment).
    var isExternalWebcam: Bool { connectedCamera?.cameraID == -2 }
    private(set) var controls: [ZWOControlCaps] = []
    private(set) var controlValues: [Int32: ZWOControlValue] = [:]
    private(set) var connectionState: CameraConnectionState = .disconnected
    private(set) var lastErrorMessage: String?

    private(set) var captureEngine: CaptureEngine?
    private var webcamEngine: WebcamCaptureEngine?
    private(set) var currentImage: CGImage?
    private(set) var currentFrame: CapturedFrame?
    /// Bumped every time `currentFrame` is replaced — lets non-`@Observable` consumers
    /// (like `MetalPreviewView`'s `NSViewRepresentable.updateNSView`) cheaply detect "is this
    /// actually a new frame" without `CapturedFrame` needing identity of its own.
    private(set) var frameID: UInt64 = 0
    private(set) var selectedImageType: ASI_IMG_TYPE = ASI_IMG_RAW8

    var stretch = DisplayStretch.identity {
        didSet { refreshCurrentImage() }
    }

    /// `true` while continuously polling video frames; `false` while showing a still frame
    /// from `captureSingleExposure`.
    private(set) var isLiveViewActive = true
    private(set) var isCapturingExposure = false

    var isFocusAssistEnabled = AppSettings.isFocusAssistEnabled {
        didSet {
            focusAssist = nil
            AppSettings.isFocusAssistEnabled = isFocusAssistEnabled
        }
    }
    private(set) var focusAssist: FocusAssistResult?

    /// Rolling Half-Flux-Diameter history (real-time focus tracking + thermal-drift alerting),
    /// recorded alongside every focus-assist star detection pass.
    let focusTracker = FocusTracker()
    var isFocusDriftDetected: Bool { focusTracker.isDriftDetected() }

    /// Reuses focus assist's star detections — requires `isFocusAssistEnabled` too, since
    /// running a second independent Vision pass just for this would be wasteful.
    var isStarRecognitionEnabled = AppSettings.isStarRecognitionEnabled {
        didSet {
            recognizedObjects = []
            AppSettings.isStarRecognitionEnabled = isStarRecognitionEnabled
        }
    }
    private(set) var recognizedObjects: [StarPatternRecognizer.Match] = []

    // MARK: - Planetary auto-center & crop (Vision)

    private let planetTracker = PlanetTracker()
    var isPlanetaryTrackingEnabled = AppSettings.isPlanetaryTrackingEnabled {
        didSet {
            planetTracker.reset()
            planetROI = nil
            AppSettings.isPlanetaryTrackingEnabled = isPlanetaryTrackingEnabled
        }
    }
    /// Also crop `currentFrame` (and everything downstream: stretch, export, recording, lucky
    /// imaging) to the tracked ROI, not just overlay it — the dynamic bounding-box "auto-crop"
    /// behavior real planetary capture tools offer.
    var isPlanetaryCropEnabled = AppSettings.isPlanetaryCropEnabled {
        didSet { AppSettings.isPlanetaryCropEnabled = isPlanetaryCropEnabled }
    }
    private(set) var planetROI: CGRect?
    private var planetTrackingTask: Task<Void, Never>?

    /// Astrometric calibration for the current field, solved by `LiveWCSSolver` from real
    /// `StarPatternRecognizer.correspondences` (see `scheduleFocusAssistIfNeeded`) — needs
    /// `isStarRecognitionEnabled` (Focus Assist -> Recognize Stars) and enough confidently-matched
    /// stars in frame. `nil` otherwise; `PreviewView` only shows `SkyHUDView` when non-nil.
    private(set) var liveWCS: WCSFrame? {
        didSet { refreshVisibleSkyObjects() }
    }
    private(set) var visibleSkyObjects: [SkyObject] = []
    private var catalogFetchTask: Task<Void, Never>?

    /// Re-queries `CatalogRepository` for whatever falls inside `liveWCS`'s field of view.
    /// Cancels any in-flight fetch first (spec section 6.3) — `liveWCS` can change every focus-
    /// assist pass as the field drifts or the star match improves/degrades, unlike the old
    /// demo-mode WCS which was fixed for a whole session.
    private func refreshVisibleSkyObjects() {
        catalogFetchTask?.cancel()
        guard let liveWCS else {
            visibleSkyObjects = []
            return
        }
        let bounds = liveWCS.boundingBox()
        let fov = liveWCS.fieldOfViewDegrees
        let maxMagnitude = CatalogRepository.magnitudeLimit(forFOVDegrees: max(fov.width, fov.height))
        catalogFetchTask = Task { [weak self] in
            let objects = await CatalogRepository.shared.fetchObjects(in: bounds, maxMagnitude: maxMagnitude)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.visibleSkyObjects = objects }
        }
    }

    /// Populated by `MetalPreviewView`'s renderer callback (GPU histogram compute kernel) when
    /// the Metal preview is active; `HistogramView` prefers this over its own CPU pass when
    /// non-nil. Not written to from anywhere else.
    var gpuHistogramCounts: [Int]?

    /// Which render path `PreviewView`/`HistogramView` use, and which live-stacking accumulator
    /// (`LiveStacker` CPU vs. `MetalFrameRenderer`'s GPU accumulation texture) is authoritative.
    var useMetalRenderer = AppSettings.useMetalRenderer {
        didSet { AppSettings.useMetalRenderer = useMetalRenderer }
    }

    /// Lifted up from being view-local `@State` so both toolbar toggles and menu bar commands
    /// (`SkyformacCommands`) can drive the same source of truth.
    var isNightModeEnabled = AppSettings.isNightModeEnabled {
        didSet { AppSettings.isNightModeEnabled = isNightModeEnabled }
    }
    var isAllSkyMonitorVisible = false

    // MARK: - Real-time denoise & wavelet sharpening
    //
    // Denoise is a classical bilateral filter, not a trained model — seeing "Apple Neural
    // Engine"/Core ML in a feature request doesn't create a shippable trained model out of
    // nothing; this delivers the same real-time noise-suppression *outcome* with a
    // well-understood, verifiable classical technique instead. Wavelet sharpening is a real
    // 2-level à trous decomposition (RegiStax-style multiscale sharpening). Both have a Metal
    // path (`Shaders.metal`, used when `useMetalRenderer`) and a CPU fallback (`ImageEnhancer`).
    var isDenoisingEnabled = AppSettings.isDenoisingEnabled {
        didSet { AppSettings.isDenoisingEnabled = isDenoisingEnabled }
    }
    var isWaveletSharpeningEnabled = AppSettings.isWaveletSharpeningEnabled {
        didSet { AppSettings.isWaveletSharpeningEnabled = isWaveletSharpeningEnabled }
    }
    var waveletSharpenAmount: Double = AppSettings.waveletSharpenAmount {
        didSet { AppSettings.waveletSharpenAmount = waveletSharpenAmount }
    }

    /// "Live GPU Enhancement Controls" (specs/skyformac_GPU_Live_Controls_Spec.md) — a separate,
    /// independent three-stage pipeline (temporal + spatial denoise, then arcsinh stretch) from
    /// the classical `isDenoisingEnabled`/`isWaveletSharpeningEnabled` pair above. Metal-only, per
    /// the spec; there's no CPU fallback (the existing enhancement pair already covers that path).
    let gpuControls = GPUControlSettings()

    // MARK: - AI Suite (specs/skyformac_AI_Features_Pipeline_Spec.md)
    //
    // Features 1 (AI Denoise) and 4 (Super-Resolution) from that spec need a trained Core ML
    // model file this repo doesn't have and can't fabricate from a feature request — see
    // `docs/design-notes.md` for why that's a hard blocker, not a scoping choice, and
    // `isDenoisingEnabled` above for the classical-technique substitute this project already
    // ships for exactly that reason. Feature 2 (lucky-imaging quality scoring) already exists for
    // real below (`SharpnessScorer`/`LuckyImagingSession`) — `currentFrameQualityScore` just
    // surfaces its live value. Features 3 (streak masking) and 5 (cloud sentinel) are genuinely
    // new, real implementations.

    var isCloudSentinelEnabled = AppSettings.isCloudSentinelEnabled {
        didSet {
            AppSettings.isCloudSentinelEnabled = isCloudSentinelEnabled
            if isCloudSentinelEnabled {
                requestNotificationAuthorizationIfNeeded()
            } else {
                cloudSentinel.reset()
                isCloudAlertActive = false
            }
        }
    }
    /// `true` from the moment a brightness-drop/spike is detected until the rolling baseline
    /// catches back up (see `CloudDriftSentinel`'s doc comment on why that's an accepted,
    /// already-shipped tradeoff rather than a sticky flag that needs manual clearing).
    private(set) var isCloudAlertActive = false
    private let cloudSentinel = CloudDriftSentinel()
    private var cloudSentinelFrameCounter = 0

    /// Excludes Vision-detected satellite/aircraft-trail pixels from live-stack accumulation
    /// (both the CPU `LiveStacker` and the GPU accumulate kernel) — see `StreakDetector`.
    var isStreakMaskingEnabled = AppSettings.isStreakMaskingEnabled {
        didSet { AppSettings.isStreakMaskingEnabled = isStreakMaskingEnabled }
    }
    private var streakDetectionTask: Task<Void, Never>?
    private(set) var currentStreakMask: StreakMask?

    /// Live "Lucky Imaging" frame quality (0...100, Laplacian-variance sharpness normalized the
    /// same way `SharpnessScorer`'s existing consumers already do) — `nil` until at least one
    /// frame has been scored. Scored on every frame regardless of whether a lucky-imaging burst
    /// is actively being captured, since it's cheap enough (unlike Vision-based work) and the
    /// live readout is useful for judging seeing conditions even between bursts.
    private(set) var currentFrameQualityScore: Double?

    // MARK: - Calibration (multiple named dark + flat frames)

    let calibrationLibrary = CalibrationLibrary()
    var isDarkSubtractionEnabled = false
    var isFlatCorrectionEnabled = false

    /// Convenience accessor for the currently-active dark frame's pixel data, kept for call
    /// sites that only care about "is there one, and what's in it" rather than its metadata.
    var darkFrame: CapturedFrame? { calibrationLibrary.activeDark?.frame }
    var flatFrame: CapturedFrame? { calibrationLibrary.activeFlat?.frame }

    // MARK: - Live stacking (unaligned running average)
    //
    // Two accumulators, exactly one of which is live at a time depending on `useMetalRenderer`:
    // `LiveStacker` (CPU, feeds the `CGImage` render path) or `MetalFrameRenderer`'s own GPU
    // accumulation texture (feeds the Metal render path — see `MetalPreviewView`). `ingest`
    // only ever runs the CPU one; the GPU one runs entirely inside `MetalFrameRenderer.process`.

    private let liveStacker = LiveStacker()
    /// Bumped on every enable/disable/reset so `MetalPreviewView` knows to clear its GPU
    /// accumulator, mirroring `liveStacker.reset()` for the CPU path.
    private(set) var liveStackGeneration = 0
    var gpuLiveStackFrameCount = 0

    var isLiveStackingEnabled = false {
        didSet {
            liveStacker.reset()
            liveStackGeneration &+= 1
            gpuLiveStackFrameCount = 0
        }
    }
    func resetLiveStack() {
        liveStacker.reset()
        liveStackGeneration &+= 1
        gpuLiveStackFrameCount = 0
    }
    var liveStackedFrameCount: Int { useMetalRenderer ? gpuLiveStackFrameCount : liveStacker.frameCount }

    // MARK: - Plate-solved polar alignment

    private(set) var polarAlignmentStage: PolarAlignmentStage = .idle
    private(set) var polarAlignmentRotationCenter: CGPoint?
    private(set) var polarAlignmentCorrespondenceCount = 0
    private var polarAlignmentFirstFrameStars: [CGPoint]?

    /// Step 1: capture the current live frame as the "near the pole, before rotation" reference.
    /// Detects stars via Vision (`StarDetector`) and stores their pixel positions.
    func capturePolarAlignmentReferenceFrame() async {
        guard let image = currentDisplayImage(), let frame = currentFrame else { return }
        guard let result = try? StarDetector.detectStars(in: image), result.stars.count >= 2 else {
            lastErrorMessage = "Not enough stars detected — point at a star-rich field near the pole."
            return
        }
        polarAlignmentFirstFrameStars = result.stars.map { pixelPosition(of: $0, in: frame) }
        polarAlignmentStage = .firstFrameCaptured
        lastErrorMessage = nil
    }

    /// Step 2 (after the user has physically rotated the mount's RA axis ~90°, alt/az
    /// untouched): capture again, match stars against the reference frame, and solve for the
    /// mount's actual mechanical rotation center.
    func solvePolarAlignment() async {
        guard let beforeStars = polarAlignmentFirstFrameStars,
              let image = currentDisplayImage(), let frame = currentFrame
        else { return }
        guard let result = try? StarDetector.detectStars(in: image), result.stars.count >= 2 else {
            lastErrorMessage = "Not enough stars detected in the second frame."
            return
        }
        let afterStars = result.stars.map { pixelPosition(of: $0, in: frame) }
        let correspondences = PolarAlignmentSolver.matchStars(before: beforeStars, after: afterStars)
        polarAlignmentCorrespondenceCount = correspondences.count

        guard let center = PolarAlignmentSolver.solveRotationCenter(from: correspondences) else {
            lastErrorMessage = "Couldn't solve a rotation center — matched \(correspondences.count) stars; try a richer star field or confirm the mount actually rotated between frames."
            return
        }
        polarAlignmentRotationCenter = center
        polarAlignmentStage = .complete
        lastErrorMessage = nil
    }

    func resetPolarAlignment() {
        polarAlignmentStage = .idle
        polarAlignmentFirstFrameStars = nil
        polarAlignmentRotationCenter = nil
        polarAlignmentCorrespondenceCount = 0
    }

    private func pixelPosition(of star: DetectedStar, in frame: CapturedFrame) -> CGPoint {
        let box = star.boundingBoxNormalized
        return CGPoint(x: box.midX * CGFloat(frame.width), y: (1 - box.midY) * CGFloat(frame.height))
    }

    // MARK: - Continuous recording with a GPU sharpness gate

    private let sharpnessScorer = GPUSharpnessScorer()
    private(set) var isRecordingToDisk = false
    private(set) var recordingDirectory: URL?
    private(set) var recordedFrameCount = 0
    private(set) var discardedFrameCount = 0
    private(set) var recordingBytesWritten: Int64 = 0
    private(set) var recordingLowDiskSpaceStopped = false
    /// Frames scoring below this (GPU mean-squared-Laplacian) are discarded rather than written.
    /// `0` keeps every frame — a pure passthrough recorder with the gate effectively disabled.
    var sharpnessDiscardThreshold: Double = AppSettings.sharpnessDiscardThreshold {
        didSet { AppSettings.sharpnessDiscardThreshold = sharpnessDiscardThreshold }
    }

    /// Below this much free space on the recording volume, recording refuses to start / stops
    /// itself mid-session — an unbounded FITS-per-frame stream can fill a disk fast, and running
    /// a Mac's boot volume out of space has real consequences beyond just losing the recording.
    private static let minimumFreeDiskSpaceBytes: Int64 = 500 * 1024 * 1024 // 500 MB

    var estimatedBytesPerFrame: Int64? {
        recordedFrameCount > 0 ? recordingBytesWritten / Int64(recordedFrameCount) : nil
    }

    /// Starts writing every sufficiently-sharp incoming (dark-subtracted) frame as a FITS file
    /// into `directory`, scored on the GPU via `GPUSharpnessScorer` — real-time quality-gated
    /// recording, the same idea as lucky imaging's burst-and-rank but for a continuous, unbounded
    /// stream written straight to disk instead of held in memory.
    func startRecording(to directory: URL) {
        if let free = DiskSpaceChecker.availableBytes(at: directory), free < Self.minimumFreeDiskSpaceBytes {
            lastErrorMessage = "Only \(formattedBytes(free)) free on that volume — need at least \(formattedBytes(Self.minimumFreeDiskSpaceBytes)) to start recording."
            return
        }
        recordingDirectory = directory
        recordedFrameCount = 0
        discardedFrameCount = 0
        recordingBytesWritten = 0
        recordingLowDiskSpaceStopped = false
        isRecordingToDisk = true
    }

    func stopRecording() {
        isRecordingToDisk = false
    }

    /// - Note: `GPUSharpnessScorer.score` blocks (`waitUntilCompleted`) for a correct per-frame
    ///   keep/discard decision (see its doc comment), and `ingest` runs on `@MainActor` — so
    ///   recording briefly blocks the main thread once per frame for the GPU round-trip. Fine at
    ///   typical planetary/lunar video rates on Apple Silicon (sub-millisecond in practice for a
    ///   modest ROI), but a future pass could move this off-actor if it becomes a bottleneck.
    private func recordIfNeeded(_ frame: CapturedFrame) {
        guard isRecordingToDisk, let directory = recordingDirectory else { return }

        // Checked every frame: `resourceValues` is a cheap stat-like call, and disk space can
        // genuinely run out between any two frames during a long unattended session.
        if let free = DiskSpaceChecker.availableBytes(at: directory), free < Self.minimumFreeDiskSpaceBytes {
            isRecordingToDisk = false
            recordingLowDiskSpaceStopped = true
            lastErrorMessage = "Recording stopped: only \(formattedBytes(free)) free on the recording volume."
            return
        }

        let score = sharpnessScorer?.score(frame: frame) ?? Double.greatestFiniteMagnitude
        guard score >= sharpnessDiscardThreshold else {
            discardedFrameCount += 1
            return
        }
        let url = directory.appendingPathComponent(String(format: "frame_%06d.fits", recordedFrameCount))
        do {
            try FITSWriter.write(frame: frame, instrumentName: connectedCamera?.name ?? "skyformac", to: url)
            recordedFrameCount += 1
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 {
                recordingBytesWritten += size
            }
        } catch {
            lastErrorMessage = String(describing: error)
            isRecordingToDisk = false
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Lucky imaging (burst capture + sharpness-ranked stacking — see `LuckyImagingSession`)

    private(set) var luckyImagingSession: LuckyImagingSession?
    var luckyImagingProgress: (captured: Int, total: Int)? {
        luckyImagingSession.map { ($0.capturedCount, $0.targetFrameCount) }
    }
    var isLuckyImagingBurstComplete: Bool { luckyImagingSession?.isComplete ?? false }

    private var frameConsumerTask: Task<Void, Never>?
    private var focusAssistTask: Task<Void, Never>?
    private var enhancementTask: Task<Void, Never>?

    init() {
        refreshCameraList()
    }

    /// Re-scans for connected ASI cameras. Safe to call with zero cameras attached.
    func refreshCameraList() {
        let count = ZWOSDK.numOfConnectedCameras()
        var cameras: [ZWOCameraInfo] = []
        for index in 0..<count {
            if let info = try? ZWOSDK.cameraProperty(atIndex: index) {
                cameras.append(info)
            }
        }
        availableCameras = cameras
    }

    /// Re-scans for Continuity Camera / USB webcam sources (see `WebcamCaptureEngine`). Separate
    /// from `refreshCameraList()` since it's a distinct, optional-permission AVFoundation API
    /// rather than the always-available ZWO SDK enumeration.
    func refreshWebcams() {
        availableWebcams = WebcamCaptureEngine.discoverDevices()
    }

    /// Connects to an iPhone/iPad (Continuity Camera, wired over USB or wireless) or other
    /// AVFoundation webcam as the live source — same downstream pipeline (`ingest`) as a ZWO
    /// camera, just sourced from `AVCaptureVideoDataOutput` instead of the ZWO SDK poll loop.
    /// Typical use: an iPhone held to a telescope eyepiece (afocal projection) for lunar/
    /// planetary shots.
    func connectToWebcam(_ device: AVCaptureDevice) async {
        disconnect()
        connectionState = .connecting
        lastErrorMessage = nil

        guard await WebcamCaptureEngine.requestAccess() else {
            connectionState = .error("Camera access denied")
            lastErrorMessage = "Camera access was denied — check System Settings > Privacy & Security > Camera."
            return
        }

        let dimensions = Self.activeDimensions(of: device)
        let engine = WebcamCaptureEngine(device: device)
        engine.onDisconnect = { [weak self] in self?.handleWebcamDisconnected() }
        let stream = engine.frames()

        do {
            try await engine.start()
        } catch {
            connectionState = .error(String(describing: error))
            lastErrorMessage = String(describing: error)
            return
        }

        webcamEngine = engine
        connectedCamera = ZWOCameraInfo.external(name: device.localizedName, width: dimensions.width, height: dimensions.height)
        controls = []
        controlValues = [:]
        isLiveViewActive = true
        connectionState = .streaming
        consumeWebcamFrames(stream)
    }

    /// Single pull-based consumer, mirroring `startPreview`'s ZWO frame loop — `frames()` buffers
    /// only the newest frame (see its doc comment), so this naturally paces itself to however
    /// fast `ingest` can actually render instead of racing ahead of it. Shared by the initial
    /// `connectToWebcam` subscription and `resumeLiveView`'s re-subscription after
    /// `captureSingleExposure` cancels the previous consumer to freeze on a single frame.
    private func consumeWebcamFrames(_ stream: AsyncStream<CapturedFrame>) {
        frameConsumerTask = Task { [weak self] in
            for await frame in stream {
                guard let self else { return }
                self.ingest(frame)
            }
        }
    }

    private static func activeDimensions(of device: AVCaptureDevice) -> (width: Int, height: Int) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return (Int(dimensions.width), Int(dimensions.height))
    }

    private func handleWebcamDisconnected() {
        webcamEngine?.stop()
        webcamEngine = nil
        currentImage = nil
        currentFrame = nil
        connectionState = .error("Camera disconnected")
        lastErrorMessage = "The camera was disconnected."
        connectedCamera = nil
        controls = []
        controlValues = [:]
        refreshWebcams()
    }

    func connect(to camera: ZWOCameraInfo) async {
        connectionState = .connecting
        lastErrorMessage = nil
        do {
            try ZWOSDK.open(camera.cameraID)
            try ZWOSDK.initCamera(camera.cameraID)
            let caps = try ZWOSDK.allControlCaps(cameraID: camera.cameraID)
            var values: [Int32: ZWOControlValue] = [:]
            for cap in caps {
                values[cap.id] = try? ZWOSDK.getControlValue(
                    cameraID: camera.cameraID,
                    controlType: cap.controlType
                )
            }
            connectedCamera = camera
            controls = caps
            controlValues = values
            let engine = CaptureEngine(camera: camera)
            captureEngine = engine
            connectionState = .connected
            await startPreview(using: engine)
        } catch {
            connectionState = .error(String(describing: error))
            lastErrorMessage = String(describing: error)
        }
    }

    /// Subscribes to `engine`'s frame stream and starts the video-capture poll loop in
    /// `imageType` (RAW8 by default; Milestone 4 adds RAW16 for higher dynamic range).
    private func startPreview(using engine: CaptureEngine, imageType: ASI_IMG_TYPE = ASI_IMG_RAW8) async {
        isLiveViewActive = true
        let stream = await engine.frames { [weak self] in
            Task { @MainActor in self?.handleCameraRemoved() }
        }
        frameConsumerTask = Task { [weak self] in
            for await frame in stream {
                guard let self else { return }
                self.ingest(frame)
            }
        }
        do {
            try await engine.startStreaming(imageType: imageType)
            selectedImageType = imageType
            connectionState = .streaming
        } catch {
            lastErrorMessage = String(describing: error)
            connectionState = .error(String(describing: error))
        }
    }

    /// Switches the live capture format (e.g. RAW8 <-> RAW16) by restarting the capture
    /// engine's stream. No-op if `imageType` isn't advertised by the connected camera.
    func changeImageType(_ imageType: ASI_IMG_TYPE) {
        guard let engine = captureEngine, let camera = connectedCamera else { return }
        guard camera.supportedVideoFormats.contains(imageType) else { return }
        guard imageType.rawValue != selectedImageType.rawValue else { return }

        frameConsumerTask?.cancel()
        currentFrame = nil
        currentImage = nil
        Task {
            await engine.stop()
            await startPreview(using: engine, imageType: imageType)
        }
    }

    /// The single place a freshly-captured raw frame (real camera or webcam) enters the
    /// display pipeline: dark subtraction, then lucky-imaging burst collection, then live
    /// stacking — all operating on raw sensor data, before `refreshCurrentImage` debayers and
    /// stretches whatever `currentFrame` ends up being for on-screen display.
    private func ingest(_ rawFrame: CapturedFrame) {
        var processed = applyDarkSubtraction(rawFrame)

        // Tracking always runs against the full, uncropped sensor frame — if it ran against an
        // already-cropped previous frame instead, the ROI's pixel coordinates would need
        // re-anchoring every frame and small errors would compound into drift. Only the final
        // `processed` frame handed downstream gets cropped.
        if isPlanetaryTrackingEnabled {
            schedulePlanetTrackingIfNeeded(fullFrame: processed)
        }
        if isPlanetaryCropEnabled, let roi = planetROI {
            let padded = Self.paddedPixelRect(for: roi, frameWidth: processed.width, frameHeight: processed.height)
            if let cropped = FrameCropper.crop(processed, toPixelRect: padded) {
                processed = cropped
            }
        }

        recordIfNeeded(processed)

        if let camera = connectedCamera, let session = luckyImagingSession, !session.isComplete {
            session.add(processed, isColorCamera: camera.isColorCamera, bayerPattern: camera.bayerPattern)
        }
        scheduleQualityScoreIfNeeded(processed)
        scheduleCloudSentinelIfNeeded(processed)

        if isLiveStackingEnabled && !useMetalRenderer {
            // CPU accumulation for the CGImage render path. When the Metal renderer is active,
            // `currentFrame` stays the raw per-frame data — `MetalFrameRenderer` does its own
            // GPU-side running-sum accumulation on each raw frame instead (see `resetLiveStack`).
            // Streak masking (see `currentStreakMask`'s doc comment) only applies here — it's a
            // CPU-`LiveStacker`-only feature, disclosed as such in the Controls UI.
            let mask = isStreakMaskingEnabled ? currentStreakMask : nil
            let maskToApply = (mask?.width == processed.width && mask?.height == processed.height) ? mask : nil
            liveStacker.add(processed, mask: maskToApply)
            currentFrame = liveStacker.currentAverage() ?? processed
        } else {
            currentFrame = processed
        }

        frameID &+= 1
        refreshCurrentImage()
    }

    // MARK: - AI Suite: quality score, cloud sentinel, streak masking

    private var qualityScoreFrameCounter = 0
    private var maxObservedSharpness = 0.0

    /// Throttled to every 5th frame — `SharpnessScorer` does a real per-pixel Laplacian-variance
    /// pass (debayering color frames first), the same cost `LuckyImagingSession.add` already pays
    /// during an active burst; running it on *every* frame just for a live readout even when no
    /// burst is active would double that cost for everyone, for a number that only needs to
    /// update a few times a second to read as "live".
    private func scheduleQualityScoreIfNeeded(_ frame: CapturedFrame) {
        guard let camera = connectedCamera else { return }
        qualityScoreFrameCounter += 1
        guard qualityScoreFrameCounter % 5 == 0 else { return }
        let raw = SharpnessScorer.score(for: frame, isColorCamera: camera.isColorCamera, bayerPattern: camera.bayerPattern)
        // Laplacian variance has no fixed theoretical ceiling, so "out of 100" here is relative to
        // the sharpest frame *this session has actually seen* — a genuinely meaningful "how good
        // is this frame compared to the best seeing we've had" readout, not a fabricated absolute
        // scale. Matches the spirit of Lucky Imaging itself: relative ranking, not calibrated units.
        maxObservedSharpness = max(maxObservedSharpness, raw)
        currentFrameQualityScore = maxObservedSharpness > 0 ? min(raw / maxObservedSharpness * 100, 100) : 0
    }

    /// Runs every ~10th ingested frame — see `scheduleFocusAssistIfNeeded`'s doc comment for the
    /// same "don't do this on every single video-rate frame" rationale.
    private func scheduleCloudSentinelIfNeeded(_ frame: CapturedFrame) {
        guard isCloudSentinelEnabled else { return }
        cloudSentinelFrameCounter += 1
        guard cloudSentinelFrameCounter % 10 == 0 else { return }

        let brightness = HistogramComputer.meanBrightness(of: frame)
        let justAlerted = cloudSentinel.evaluate(brightness: brightness)
        isCloudAlertActive = cloudSentinel.isAlerting
        if justAlerted {
            if isRecordingToDisk { stopRecording() }
            sendCloudAlertNotification()
        }
    }

    private func requestNotificationAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendCloudAlertNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Cloud Interruption"
        content.body = "skyformac detected a sudden sky-brightness change and paused active recording."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Runs Vision streak detection at most a few times a second (same throttling shape as
    /// `scheduleFocusAssistIfNeeded`) against `currentImage` — called from `refreshCurrentImage()`
    /// once that's been (re)rendered for this frame, not from `ingest()` directly, since building
    /// a `CGImage` is exactly what Vision needs and `ingest()` doesn't have one yet.
    private func scheduleStreakDetectionIfNeeded() {
        guard isStreakMaskingEnabled, isLiveStackingEnabled, streakDetectionTask == nil,
              let image = currentImage, let frame = currentFrame
        else { return }
        let width = frame.width
        let height = frame.height
        streakDetectionTask = Task { [weak self] in
            let streaks = (try? StreakDetector.detectStreaks(in: image)) ?? []
            try? await Task.sleep(for: .milliseconds(250)) // simple rate limit, mirrors focus assist
            await MainActor.run {
                self?.currentStreakMask = StreakMask(width: width, height: height, streaks: streaks)
                self?.streakDetectionTask = nil
            }
        }
    }

    /// Applies whichever of dark subtraction / flat correction are enabled and have an active
    /// calibration frame — dark first (removes fixed-pattern noise/hot pixels), then flat
    /// (corrects vignetting/dust shadows), matching the standard real-world calibration order.
    private func applyDarkSubtraction(_ frame: CapturedFrame) -> CapturedFrame {
        var result = frame
        if isDarkSubtractionEnabled, let dark = darkFrame,
           let subtracted = FrameArithmetic.subtract(light: result, dark: dark) {
            result = subtracted
        }
        if isFlatCorrectionEnabled, let flat = flatFrame,
           let corrected = FlatFieldCorrector.correct(light: result, flat: flat) {
            result = corrected
        }
        return result
    }

    /// Captures a dark frame (lens capped / scope covered) the same way `captureSingleExposure`
    /// captures a light frame, and adds it to `calibrationLibrary` (becoming the active dark if
    /// it's the first one). Toggle `isDarkSubtractionEnabled` to start subtracting it.
    func captureDarkFrame(seconds: Double) async {
        guard let camera = connectedCamera else { return }
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        isLiveViewActive = false
        isCapturingExposure = true
        lastErrorMessage = nil
        defer { isCapturingExposure = false }

        let exposureMicroseconds = Int(seconds * 1_000_000)

        guard camera.cameraID >= 0 else {
            lastErrorMessage = "Dark-frame calibration needs a real ASI camera's controllable exposure — not available for iPhone/webcam sources."
            return
        }

        guard let engine = captureEngine else { return }
        do {
            let frame = try await engine.captureSingleExposure(
                imageType: selectedImageType, exposureMicroseconds: exposureMicroseconds, isDark: true
            )
            calibrationLibrary.addDark(frame, exposureMicroseconds: exposureMicroseconds)
            connectionState = .connected
        } catch {
            lastErrorMessage = String(describing: error)
            connectionState = .error(String(describing: error))
        }
    }

    /// Captures a flat frame (evenly-illuminated target — twilight sky, a light panel) and adds
    /// it to `calibrationLibrary`. Toggle `isFlatCorrectionEnabled` to start correcting with it.
    func captureFlatFrame(seconds: Double) async {
        guard let camera = connectedCamera else { return }
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        isLiveViewActive = false
        isCapturingExposure = true
        lastErrorMessage = nil
        defer { isCapturingExposure = false }

        let exposureMicroseconds = Int(seconds * 1_000_000)

        guard camera.cameraID >= 0 else {
            lastErrorMessage = "Flat-frame calibration needs a real ASI camera's controllable exposure — not available for iPhone/webcam sources."
            return
        }

        guard let engine = captureEngine else { return }
        do {
            let frame = try await engine.captureSingleExposure(
                imageType: selectedImageType, exposureMicroseconds: exposureMicroseconds
            )
            calibrationLibrary.addFlat(frame, exposureMicroseconds: exposureMicroseconds)
            connectionState = .connected
        } catch {
            lastErrorMessage = String(describing: error)
            connectionState = .error(String(describing: error))
        }
    }

    func clearDarkFrame() {
        calibrationLibrary.darkFrames.forEach { calibrationLibrary.removeDark(id: $0.id) }
        isDarkSubtractionEnabled = false
    }

    func clearFlatFrame() {
        calibrationLibrary.flatFrames.forEach { calibrationLibrary.removeFlat(id: $0.id) }
        isFlatCorrectionEnabled = false
    }

    // MARK: - Smart Exposure (sub-exposure length optimizer)

    private(set) var smartExposureRecommendation: SmartExposureRecommendation?
    private(set) var isMeasuringSmartExposure = false

    /// Measures read noise (from a minimum-length bias frame's pixel noise) and sky background
    /// brightness (from a short test exposure's median level), then recommends a sub-exposure
    /// length via `ExposureOptimizer`. See `ExposureOptimizer`'s doc comment for why this
    /// measures rather than reads read noise from the SDK (there's no such API).
    func measureSmartExposure(testExposureSeconds: Double = 2.0) async {
        guard let camera = connectedCamera else { return }
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        isLiveViewActive = false
        isMeasuringSmartExposure = true
        lastErrorMessage = nil
        defer { isMeasuringSmartExposure = false }

        guard camera.cameraID >= 0 else {
            lastErrorMessage = "Smart Exposure measures a real ASI sensor's read noise from a controllable bias frame — not available for iPhone/webcam sources."
            return
        }

        let electronsPerADU = Double(camera.electronsPerADU)
        let biasFrame: CapturedFrame
        let skyFrame: CapturedFrame

        guard let engine = captureEngine else { return }
        do {
            let minimumMicroseconds = controls
                .first { $0.controlType.rawValue == ASI_EXPOSURE.rawValue }
                .map { max($0.minValue, 32) } ?? 32
            biasFrame = try await engine.captureSingleExposure(
                imageType: selectedImageType, exposureMicroseconds: minimumMicroseconds
            )
            skyFrame = try await engine.captureSingleExposure(
                imageType: selectedImageType,
                exposureMicroseconds: Int(testExposureSeconds * 1_000_000)
            )
            connectionState = .connected
        } catch {
            lastErrorMessage = String(describing: error)
            connectionState = .error(String(describing: error))
            return
        }

        guard let readNoise = ExposureOptimizer.readNoiseElectrons(biasFrame: biasFrame, electronsPerADU: electronsPerADU),
              let skyRate = ExposureOptimizer.skyBackgroundRate(
                testFrame: skyFrame, exposureSeconds: testExposureSeconds, electronsPerADU: electronsPerADU
              ),
              let recommended = ExposureOptimizer.optimalSubExposureSeconds(
                readNoiseElectrons: readNoise, skyRateElectronsPerSecond: skyRate
              )
        else {
            lastErrorMessage = "Could not compute a recommendation from the measured frames."
            return
        }

        smartExposureRecommendation = SmartExposureRecommendation(
            readNoiseElectrons: readNoise,
            skyRateElectronsPerSecond: skyRate,
            recommendedSubExposureSeconds: recommended
        )

        currentFrame = skyFrame
        frameID &+= 1
        refreshCurrentImage()
    }

    // MARK: - Lucky imaging

    /// Arms a new burst: the next `frameCount` incoming frames (live view or single-exposure
    /// captures don't count — only the continuous `ingest` path does) get scored and held.
    func startLuckyImagingBurst(frameCount: Int) {
        luckyImagingSession = LuckyImagingSession(targetFrameCount: frameCount)
    }

    /// Stacks the sharpest `fraction` of the current burst and shows it as `currentFrame`.
    /// Can be called repeatedly with different fractions without recapturing.
    func stackLuckyImagingBest(fraction: Double) {
        guard let session = luckyImagingSession, let stacked = session.stackBest(fraction: fraction) else { return }
        currentFrame = stacked
        frameID &+= 1
        refreshCurrentImage()
    }

    func discardLuckyImagingSession() {
        luckyImagingSession = nil
    }

    // MARK: - Export

    /// Presents a save panel and writes `currentFrame`/`currentImage` in the requested format:
    /// FITS carries the raw (pre-debayer) sensor data — the standard way capture software
    /// archives what the sensor actually saw; PNG/TIFF export the already-debayered, stretched
    /// display image for quick sharing.
    func exportCurrentFrame(as kind: ExportKind) {
        guard currentFrame != nil else { return }
        let panel = NSSavePanel()
        switch kind {
        case .fits:
            panel.allowedContentTypes = [UTType(filenameExtension: "fits") ?? .data]
            panel.nameFieldStringValue = "capture.fits"
        case .png:
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = "capture.png"
        case .tiff:
            panel.allowedContentTypes = [.tiff]
            panel.nameFieldStringValue = "capture.tiff"
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.finishExport(kind: kind, to: url)
            }
        }
    }

    private func finishExport(kind: ExportKind, to url: URL) {
        do {
            switch kind {
            case .fits:
                guard let frame = currentFrame else { return }
                try FITSWriter.write(frame: frame, instrumentName: connectedCamera?.name ?? "skyformac", to: url)
            case .png:
                guard let image = currentDisplayImage() else { return }
                try ImageExporter.writePNG(image, to: url)
            case .tiff:
                guard let image = currentDisplayImage() else { return }
                try ImageExporter.writeTIFF(image, to: url)
            }
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    private func refreshCurrentImage() {
        guard let frame = currentFrame, let camera = connectedCamera else { return }
        // On the Metal path, `PreviewView` shows `MetalPreviewView` and never reads
        // `currentImage` — so only pay for the CPU debayer/stretch pass here when focus assist or
        // streak detection needs a CGImage for a Vision request. Otherwise it'd be a full CPU
        // render wasted every frame on top of the GPU pipeline already doing the same work.
        // (Export and polar alignment are rare, user-initiated actions that render on demand
        // instead — see `renderedCurrentImage()`.)
        let needsStreakDetectionImage = isStreakMaskingEnabled && isLiveStackingEnabled
        if !useMetalRenderer || isFocusAssistEnabled || needsStreakDetectionImage {
            currentImage = renderedCurrentImage(frame: frame, camera: camera)
        }
        scheduleFocusAssistIfNeeded()
        scheduleCPUEnhancementIfNeeded(frame: frame, camera: camera)
        if needsStreakDetectionImage {
            scheduleStreakDetectionIfNeeded()
        }
    }

    private func renderedCurrentImage(frame: CapturedFrame, camera: ZWOCameraInfo) -> CGImage? {
        CGImageRenderer.makeDisplayImage(
            from: frame,
            isColorCamera: camera.isColorCamera,
            bayerPattern: camera.bayerPattern,
            stretch: stretch
        )
    }

    /// `currentImage` is already fresh in CPU mode (and in GPU mode when focus assist keeps it
    /// updated); this only pays for a fresh render for the rare, user-initiated actions (export,
    /// polar alignment) that need one in GPU mode without focus assist enabled.
    private func currentDisplayImage() -> CGImage? {
        if let currentImage { return currentImage }
        guard let frame = currentFrame, let camera = connectedCamera else { return nil }
        return renderedCurrentImage(frame: frame, camera: camera)
    }

    /// Denoise/wavelet-sharpen are display-only enhancements (exactly like their Metal
    /// counterparts — `MetalFrameRenderer.process` never touches `currentFrame` either, so
    /// export/recording/lucky-imaging always see the untouched data). Unlike the GPU path,
    /// `ImageEnhancer`'s unoptimized Swift loops are nowhere near fast enough to run synchronously
    /// on `@MainActor` per frame — measured at 10+ seconds and 100% CPU on a single 640×480 frame
    /// in a debug build, which would otherwise freeze the whole app. So: compute the plain
    /// (un-enhanced) image immediately above for a responsive UI, then replace it with the
    /// enhanced version in the background once it's ready, throttled and skip-if-busy exactly
    /// like `scheduleFocusAssistIfNeeded`/`schedulePlanetTrackingIfNeeded`.
    private func scheduleCPUEnhancementIfNeeded(frame: CapturedFrame, camera: ZWOCameraInfo) {
        guard !useMetalRenderer, isDenoisingEnabled || isWaveletSharpeningEnabled, enhancementTask == nil else { return }
        let denoiseEnabled = isDenoisingEnabled
        let sharpenEnabled = isWaveletSharpeningEnabled
        let sharpenAmount = waveletSharpenAmount
        let isColorCamera = camera.isColorCamera
        let bayerPattern = camera.bayerPattern
        let currentStretch = stretch
        let frameIDAtSchedule = frameID

        enhancementTask = Task.detached(priority: .userInitiated) { [weak self] in
            var displayFrame = frame
            if denoiseEnabled, let denoised = ImageEnhancer.denoise(displayFrame) {
                displayFrame = denoised
            }
            if sharpenEnabled, let sharpened = ImageEnhancer.waveletSharpen(
                displayFrame, fineGain: sharpenAmount, midGain: sharpenAmount * 0.6
            ) {
                displayFrame = sharpened
            }
            let image = CGImageRenderer.makeDisplayImage(
                from: displayFrame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: currentStretch
            )
            await MainActor.run {
                guard let self else { return }
                // Only apply if a newer frame hasn't already arrived — otherwise this stale,
                // slow-to-compute enhanced image would visibly replace a fresher plain one.
                if self.frameID == frameIDAtSchedule, let image {
                    self.currentImage = image
                }
                self.enhancementTask = nil
            }
        }
    }

    /// Runs `PlanetDetector` (Vision contours, biggest-blob selection) at a throttled rate and
    /// feeds the result through `PlanetTracker`'s smoothing. Takes the full, uncropped frame
    /// explicitly (see `ingest`) rather than reading `currentImage`/`currentFrame`, which may
    /// already be cropped to the previous ROI.
    private func schedulePlanetTrackingIfNeeded(fullFrame: CapturedFrame) {
        guard isPlanetaryTrackingEnabled, planetTrackingTask == nil, let camera = connectedCamera else { return }
        guard let image = CGImageRenderer.makeDisplayImage(
            from: fullFrame, isColorCamera: camera.isColorCamera, bayerPattern: camera.bayerPattern, stretch: stretch
        ) else { return }

        planetTrackingTask = Task { [weak self] in
            let detection = try? PlanetDetector.detectDisk(in: image)
            try? await Task.sleep(for: .milliseconds(200))
            await MainActor.run {
                guard let self else { return }
                self.planetROI = self.planetTracker.update(with: detection ?? nil)
                self.planetTrackingTask = nil
            }
        }
    }

    /// Expands a normalized (Vision bottom-left-origin) ROI by 40% and converts it to a pixel
    /// rect in the frame's coordinate space, so the crop has comfortable margin around the
    /// tracked disk rather than clipping it tight to the raw contour box.
    private static func paddedPixelRect(
        for normalizedROI: CGRect, frameWidth: Int, frameHeight: Int
    ) -> (x: Int, y: Int, width: Int, height: Int) {
        let paddingFactor: CGFloat = 0.4
        let paddedWidth = normalizedROI.width * (1 + paddingFactor)
        let paddedHeight = normalizedROI.height * (1 + paddingFactor)
        let centerX = normalizedROI.midX
        let centerY = 1 - normalizedROI.midY // flip Vision's bottom-left origin to top-left pixel space

        let pixelWidth = Int(paddedWidth * CGFloat(frameWidth))
        let pixelHeight = Int(paddedHeight * CGFloat(frameHeight))
        let pixelX = Int(centerX * CGFloat(frameWidth)) - pixelWidth / 2
        let pixelY = Int(centerY * CGFloat(frameHeight)) - pixelHeight / 2
        return (x: pixelX, y: pixelY, width: max(pixelWidth, 8), height: max(pixelHeight, 8))
    }

    /// Runs `StarDetector` on the current preview image at most a few times a second — a full
    /// Vision contour pass every single incoming frame would be wasteful, especially at video
    /// frame rates. Skips scheduling if a detection pass is already in flight.
    private func scheduleFocusAssistIfNeeded() {
        guard isFocusAssistEnabled, focusAssistTask == nil, let image = currentImage, let frame = currentFrame else { return }
        let width = frame.width
        let height = frame.height
        let recognizeStars = isStarRecognitionEnabled
        focusAssistTask = Task { [weak self] in
            let result = try? StarDetector.detectStars(in: image)
            let matches = (recognizeStars ? result?.stars : nil).map {
                StarPatternRecognizer.recognize(detectedStars: $0, imageWidth: width, imageHeight: height)
            } ?? []
            // Real point-to-point correspondences (not just `matches`' aggregate votes) are what
            // `LiveWCSSolver` needs to fit an actual WCS — see `StarPatternRecognizer.recognize`'s
            // doc comment on why unordered triangle-shape voting alone can't provide those.
            let wcs = (recognizeStars ? result?.stars : nil).flatMap { stars -> WCSFrame? in
                let correspondences = StarPatternRecognizer.correspondences(
                    detectedStars: stars, imageWidth: width, imageHeight: height
                )
                return LiveWCSSolver.solve(correspondences: correspondences, imageWidth: width, imageHeight: height)
            }
            // HFD is measured on the raw (linear, pre-stretch) sensor data, not the debayered/
            // stretched display image the star positions were detected on — a non-linear
            // stretch would distort the flux ratios HFD's centroid/radius math depends on.
            let hfd = result.flatMap { HFDCalculator.medianHFD(frame: frame, stars: $0.stars) }
            try? await Task.sleep(for: .milliseconds(250)) // simple rate limit
            await MainActor.run {
                self?.focusAssist = result
                self?.recognizedObjects = matches
                self?.liveWCS = wcs
                self?.focusAssistTask = nil
                if let hfd {
                    self?.focusTracker.record(medianHFD: hfd, at: Date())
                }
            }
        }
    }

    /// Captures one long exposure via `ASIStartExposure`/`ASIGetDataAfterExp` instead of the
    /// continuous video-poll loop, per the spec's directive to support proper deep-sky exposure
    /// lengths. Stops live streaming for the duration; call `resumeLiveView()` to go back.
    func captureSingleExposure(seconds: Double) async {
        guard let camera = connectedCamera else { return }
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        isLiveViewActive = false
        isCapturingExposure = true
        lastErrorMessage = nil

        defer { isCapturingExposure = false }

        if camera.cameraID == -2 {
            // Webcam: no controllable hardware exposure — `frameConsumerTask?.cancel()` above
            // already stopped the live feed, so `currentFrame` is simply whatever the last
            // incoming frame was (already real, already through `ingest`). "Capturing" here just
            // means freezing on it; `resumeLiveView()` re-subscribes to keep streaming.
            frameID &+= 1
            refreshCurrentImage()
            return
        }

        guard let engine = captureEngine else { return }
        do {
            let frame = try await engine.captureSingleExposure(
                imageType: selectedImageType,
                exposureMicroseconds: Int(seconds * 1_000_000)
            )
            currentFrame = applyDarkSubtraction(frame)
            frameID &+= 1
            refreshCurrentImage()
            connectionState = .connected
        } catch {
            lastErrorMessage = String(describing: error)
            connectionState = .error(String(describing: error))
        }
    }

    /// Returns to continuous video streaming after `captureSingleExposure`.
    func resumeLiveView() {
        isLiveViewActive = true
        if let engine = webcamEngine {
            consumeWebcamFrames(engine.frames())
        } else if let camera = connectedCamera, let engine = captureEngine, camera.cameraID >= 0 {
            Task { await startPreview(using: engine, imageType: selectedImageType) }
        }
    }

    func disconnect() {
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        focusAssistTask?.cancel()
        focusAssistTask = nil
        focusAssist = nil
        enhancementTask?.cancel()
        enhancementTask = nil
        planetTrackingTask?.cancel()
        planetTrackingTask = nil
        planetTracker.reset()
        planetROI = nil
        gpuHistogramCounts = nil
        catalogFetchTask?.cancel()
        catalogFetchTask = nil
        liveWCS = nil
        webcamEngine?.stop()
        webcamEngine = nil
        isLiveViewActive = true
        isCapturingExposure = false
        currentImage = nil
        currentFrame = nil
        liveStacker.reset()
        luckyImagingSession = nil
        focusTracker.reset()
        isRecordingToDisk = false
        resetPolarAlignment()
        cloudSentinel.reset()
        isCloudAlertActive = false
        streakDetectionTask?.cancel()
        streakDetectionTask = nil
        currentStreakMask = nil
        currentFrameQualityScore = nil
        maxObservedSharpness = 0
        // Deliberately NOT clearing darkFrame/isDarkSubtractionEnabled — a captured dark frame
        // is reusable across a reconnect of the same camera/settings.
        if let camera = connectedCamera, camera.cameraID >= 0 {
            let engine = captureEngine
            Task {
                await engine?.stop()
                try? ZWOSDK.close(camera.cameraID)
            }
        }
        captureEngine = nil
        connectedCamera = nil
        controls = []
        controlValues = [:]
        connectionState = .disconnected
    }

    func setControlValue(_ controlType: ASI_CONTROL_TYPE, value: Int, isAuto: Bool = false) {
        guard let camera = connectedCamera, camera.cameraID >= 0 else { return }
        do {
            try ZWOSDK.setControlValue(
                cameraID: camera.cameraID,
                controlType: controlType,
                value: value,
                isAuto: isAuto
            )
            controlValues[Int32(controlType.rawValue)] = ZWOControlValue(value: value, isAuto: isAuto)
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    /// Called by `CaptureEngine` when a background call reports `ASI_ERROR_CAMERA_REMOVED`.
    func handleCameraRemoved() {
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        currentImage = nil
        connectionState = .error(ZWOError.cameraRemoved.description)
        lastErrorMessage = ZWOError.cameraRemoved.description
        captureEngine = nil
        connectedCamera = nil
        controls = []
        controlValues = [:]
        refreshCameraList()
    }
}
