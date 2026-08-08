import CoreGraphics
import Foundation
import Observation

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
    private(set) var connectedCamera: ZWOCameraInfo?
    private(set) var controls: [ZWOControlCaps] = []
    private(set) var controlValues: [Int32: ZWOControlValue] = [:]
    private(set) var connectionState: CameraConnectionState = .disconnected
    private(set) var lastErrorMessage: String?

    private(set) var captureEngine: CaptureEngine?
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

    var isFocusAssistEnabled = false {
        didSet { focusAssist = nil }
    }
    private(set) var focusAssist: FocusAssistResult?

    private var frameConsumerTask: Task<Void, Never>?
    private var simulationTask: Task<Void, Never>?
    private var focusAssistTask: Task<Void, Never>?

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
                self.currentFrame = frame
                self.frameID &+= 1
                self.refreshCurrentImage()
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

    /// Feeds synthetic frames through the exact same debayer/histogram/render pipeline as a
    /// real camera, with no hardware attached — used by the "Simulate Test Pattern" debug
    /// action (see `CameraListView`) to exercise and visually verify the rendering pipeline.
    func simulateTestPattern(color: Bool) {
        disconnect()
        let camera = color ? ZWOCameraInfo.simulatedColor() : ZWOCameraInfo.simulatedMono()
        connectedCamera = camera
        controls = []
        controlValues = [:]
        connectionState = .streaming
        lastErrorMessage = nil

        simulationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let frame = color
                    ? TestPatternGenerator.bayerRAW8(width: camera.maxWidth, height: camera.maxHeight)
                    : TestPatternGenerator.mono8(width: camera.maxWidth, height: camera.maxHeight)
                self.currentFrame = frame
                self.frameID &+= 1
                self.refreshCurrentImage()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func refreshCurrentImage() {
        guard let frame = currentFrame, let camera = connectedCamera else { return }
        currentImage = CGImageRenderer.makeDisplayImage(
            from: frame,
            isColorCamera: camera.isColorCamera,
            bayerPattern: camera.bayerPattern,
            stretch: stretch
        )
        scheduleFocusAssistIfNeeded()
    }

    /// Runs `StarDetector` on the current preview image at most a few times a second — a full
    /// Vision contour pass every single incoming frame would be wasteful, especially at video
    /// frame rates. Skips scheduling if a detection pass is already in flight.
    private func scheduleFocusAssistIfNeeded() {
        guard isFocusAssistEnabled, focusAssistTask == nil, let image = currentImage else { return }
        focusAssistTask = Task { [weak self] in
            let result = try? StarDetector.detectStars(in: image)
            try? await Task.sleep(for: .milliseconds(250)) // simple rate limit
            await MainActor.run {
                self?.focusAssist = result
                self?.focusAssistTask = nil
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

        if camera.cameraID < 0 {
            // Simulated camera: no hardware exposure to wait on, just synthesize a frame.
            try? await Task.sleep(for: .seconds(min(seconds, 2))) // still feels like "capturing"
            let isColor = camera.isColorCamera
            currentFrame = isColor
                ? TestPatternGenerator.bayerRAW8(width: camera.maxWidth, height: camera.maxHeight)
                : TestPatternGenerator.mono8(width: camera.maxWidth, height: camera.maxHeight)
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
            currentFrame = frame
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
        guard let camera = connectedCamera, let engine = captureEngine, camera.cameraID >= 0 else {
            isLiveViewActive = true
            return
        }
        isLiveViewActive = true
        Task { await startPreview(using: engine, imageType: selectedImageType) }
    }

    func disconnect() {
        simulationTask?.cancel()
        simulationTask = nil
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        focusAssistTask?.cancel()
        focusAssistTask = nil
        focusAssist = nil
        isLiveViewActive = true
        isCapturingExposure = false
        currentImage = nil
        currentFrame = nil
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
