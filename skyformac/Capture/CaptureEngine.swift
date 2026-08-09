import Foundation

/// A single captured frame handed off from the capture actor to the rendering layer.
/// Owns its pixel storage (a copy out of the reused poll buffer); no pointer into
/// SDK-owned memory ever escapes `CaptureEngine`.
struct CapturedFrame: Sendable {
    let width: Int
    let height: Int
    let imageType: ASI_IMG_TYPE

    /// Row-major pixel bytes: 1 byte/pixel for RAW8/Y8, 2 bytes/pixel (little-endian) for RAW16,
    /// 3 bytes/pixel for RGB24.
    let data: Data
}

/// Owns the ZWO video-capture polling loop for one connected camera.
///
/// This is a Swift `actor` so that every blocking `ZWOSDK` call it makes (`ASIStartVideoCapture`,
/// the `ASIGetVideoData` poll loop) is structurally isolated off `@MainActor` — per the project's
/// "Strict Threading" rule, there is no code path by which those calls can run on the main thread.
actor CaptureEngine {
    let camera: ZWOCameraInfo

    private var isRunning = false
    private var pollTask: Task<Void, Never>?
    private var frameBuffer: FrameBuffer?
    private var currentFormat: ZWOSDK.ROIFormat?

    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private var onCameraRemoved: (@Sendable () -> Void)?

    init(camera: ZWOCameraInfo) {
        self.camera = camera
    }

    /// Live frame stream for the currently-connected camera. Consuming code (the renderer)
    /// should iterate this with `for await`; frames stop arriving once `stop()` is called.
    /// `onCameraRemoved` fires (off the actor) if a poll reports `ASI_ERROR_CAMERA_REMOVED`.
    func frames(onCameraRemoved: @escaping @Sendable () -> Void) -> AsyncStream<CapturedFrame> {
        self.onCameraRemoved = onCameraRemoved
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Configures the camera for full-resolution, unbinned video capture in `imageType` and
    /// starts the background poll loop. Call `frames(onCameraRemoved:)` first to obtain the
    /// stream. Safe to call again with a different `imageType` after `stop()`.
    func startStreaming(imageType: ASI_IMG_TYPE = ASI_IMG_RAW8) throws {
        guard !isRunning else { return }

        let width = camera.maxWidth
        let height = camera.maxHeight
        try ZWOSDK.setROIFormat(
            cameraID: camera.cameraID,
            width: width,
            height: height,
            binning: 1,
            imageType: imageType
        )
        let format = try ZWOSDK.getROIFormat(cameraID: camera.cameraID)
        currentFormat = format

        let byteCount = format.width * format.height * bytesPerPixel(for: format.imageType)
        if let buffer = frameBuffer {
            buffer.ensureCapacity(byteCount)
        } else {
            frameBuffer = FrameBuffer(byteCount: byteCount)
        }

        try ZWOSDK.startVideoCapture(cameraID: camera.cameraID)
        isRunning = true

        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    /// Single-exposure capture (`ASIStartExposure` / poll `ASIGetExpStatus` / `ASIGetDataAfterExp`)
    /// for longer deep-sky exposures that don't suit the continuous video-poll loop. Stops video
    /// streaming first if it's running — the SDK does not support both modes concurrently.
    /// Entirely on the actor's background execution context, per the "Strict Threading" rule.
    func captureSingleExposure(
        imageType: ASI_IMG_TYPE,
        exposureMicroseconds: Int,
        isDark: Bool = false
    ) async throws -> CapturedFrame {
        if isRunning { stop() }

        let width = camera.maxWidth
        let height = camera.maxHeight
        try ZWOSDK.setROIFormat(
            cameraID: camera.cameraID,
            width: width,
            height: height,
            binning: 1,
            imageType: imageType
        )
        let format = try ZWOSDK.getROIFormat(cameraID: camera.cameraID)

        let exposureCaps = try ZWOSDK.allControlCaps(cameraID: camera.cameraID)
            .first { $0.controlType.rawValue == ASI_EXPOSURE.rawValue }
        if exposureCaps != nil {
            try ZWOSDK.setControlValue(
                cameraID: camera.cameraID,
                controlType: ASI_EXPOSURE,
                value: exposureMicroseconds,
                isAuto: false
            )
        }

        let byteCount = format.width * format.height * bytesPerPixel(for: format.imageType)
        if let buffer = frameBuffer {
            buffer.ensureCapacity(byteCount)
        } else {
            frameBuffer = FrameBuffer(byteCount: byteCount)
        }

        try ZWOSDK.startExposure(cameraID: camera.cameraID, isDark: isDark)

        // Poll status at a cadence proportional to the exposure length, capped at 4x/second,
        // so a 30-minute exposure doesn't get hammered with pointless status queries.
        let pollIntervalNanoseconds = UInt64(min(max(exposureMicroseconds / 20, 50_000), 250_000)) * 1000
        // Real hardware can fail to ever report `ASI_EXP_SUCCESS`/`ASI_EXP_FAILED` (a firmware
        // hiccup, a bad USB link, etc.) — the poll loop's first version had no upper bound on how
        // long it would wait, so that hung forever. Because `CaptureEngine` is a single actor,
        // every other call routed through it (including `resumeLiveView()`'s restart of video
        // streaming) queues behind this one and *also* hangs forever, which is why "the app
        // hangs" and "live view never comes back" were really the same bug, not two. Bounding the
        // wait — generous enough for any real exposure (1.5x the requested length plus a flat
        // 5s of readout/overhead margin) — turns an infinite hang into a normal thrown error, and
        // `ASIStopExposure` puts the camera back in a state `resumeLiveView()` can actually
        // restart from.
        let timeoutNanoseconds = UInt64(Double(max(exposureMicroseconds, 0)) * 1_000 * 1.5) + 5_000_000_000
        var elapsedNanoseconds: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let status = try ZWOSDK.exposureStatus(cameraID: camera.cameraID)
            if status == ASI_EXP_SUCCESS { break }
            if status == ASI_EXP_FAILED {
                try? ZWOSDK.stopExposure(cameraID: camera.cameraID)
                throw ZWOError.generalError
            }
            guard elapsedNanoseconds < timeoutNanoseconds else {
                try? ZWOSDK.stopExposure(cameraID: camera.cameraID)
                throw ZWOError.timeout
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            elapsedNanoseconds += pollIntervalNanoseconds
        }

        guard let buffer = frameBuffer else { throw ZWOError.generalError }
        try ZWOSDK.getDataAfterExposure(cameraID: camera.cameraID, buffer: buffer.pointer)
        return CapturedFrame(
            width: format.width,
            height: format.height,
            imageType: format.imageType,
            data: Data(bytes: buffer.pointer.baseAddress!, count: buffer.byteCount)
        )
    }

    func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        continuation?.finish()
        continuation = nil
        try? ZWOSDK.stopVideoCapture(cameraID: camera.cameraID)
    }

    /// Opens and initializes the camera, then enumerates its control caps/current values.
    /// `ASIOpenCamera`/`ASIInitCamera` do a real USB handshake with the camera's firmware and can
    /// block for a user-perceptible amount of time (worse the more control types the camera
    /// reports, since each one is its own blocking `ASIGetControlValue` round-trip) — like every
    /// other `ZWOSDK` call this actor makes, this must never run on `@MainActor`. Previously
    /// `CameraManager.connect(to:)` called `ZWOSDK.open`/`initCamera`/`allControlCaps` directly
    /// on `@MainActor` before this actor (or its `CaptureEngine`) even existed yet, hanging the
    /// whole app's UI for however long that handshake actually took.
    func openAndEnumerateControls() throws -> (caps: [ZWOControlCaps], values: [Int32: ZWOControlValue]) {
        try ZWOSDK.open(camera.cameraID)
        try ZWOSDK.initCamera(camera.cameraID)
        let caps = try ZWOSDK.allControlCaps(cameraID: camera.cameraID)
        var values: [Int32: ZWOControlValue] = [:]
        for cap in caps {
            values[cap.id] = try? ZWOSDK.getControlValue(cameraID: camera.cameraID, controlType: cap.controlType)
        }
        return (caps, values)
    }

    /// Closes the camera — mirrors `openAndEnumerateControls()`'s off-`@MainActor` requirement.
    func close() {
        try? ZWOSDK.close(camera.cameraID)
    }

    /// Used for the handful of control writes `CameraManager` needs to make itself outside a
    /// per-frame UI binding (e.g. forcing a sane default `ASI_GAIN` right after connecting) —
    /// `CameraManager.setControlValue(_:value:isAuto:)` stays a direct, synchronous `ZWOSDK` call
    /// on `@MainActor` for the live slider/toggle bindings themselves, since `ASISetControlValue`
    /// is a single fast register write (not a firmware handshake like `ASIOpenCamera`/
    /// `ASIInitCamera`) and routing every drag tick through an actor hop would just add latency
    /// for no responsiveness benefit.
    func setControlValue(_ controlType: ASI_CONTROL_TYPE, value: Int, isAuto: Bool = false) throws {
        try ZWOSDK.setControlValue(cameraID: camera.cameraID, controlType: controlType, value: value, isAuto: isAuto)
    }

    private func pollLoop() async {
        while isRunning, !Task.isCancelled {
            guard let buffer = frameBuffer, let format = currentFormat else { break }
            do {
                try ZWOSDK.getVideoData(
                    cameraID: camera.cameraID,
                    buffer: buffer.pointer,
                    waitMilliseconds: 500
                )
                let frame = CapturedFrame(
                    width: format.width,
                    height: format.height,
                    imageType: format.imageType,
                    data: Data(bytes: buffer.pointer.baseAddress!, count: buffer.byteCount)
                )
                continuation?.yield(frame)
            } catch ZWOError.timeout {
                // No frame ready yet within the wait window — normal at low frame rates, retry.
                continue
            } catch ZWOError.cameraRemoved {
                isRunning = false
                onCameraRemoved?()
                break
            } catch {
                // Any other SDK error: stop cleanly rather than spinning on a broken capture.
                isRunning = false
                break
            }
        }
        continuation?.finish()
    }

    private func bytesPerPixel(for imageType: ASI_IMG_TYPE) -> Int {
        switch imageType {
        case ASI_IMG_RAW8, ASI_IMG_Y8: return 1
        case ASI_IMG_RAW16: return 2
        case ASI_IMG_RGB24: return 3
        default: return 1
        }
    }

    deinit {
        pollTask?.cancel()
    }
}
