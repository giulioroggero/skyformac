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

/// `UnsafeMutableRawBufferPointer` isn't `Sendable` — raw pointers can alias arbitrary shared
/// mutable memory in general, so the compiler can't verify sending one across an `async` call
/// boundary is safe. This wrapper asserts it *is* safe here specifically: `pollLoop` awaits each
/// `fetchVideoData` call before starting the next one, and `CaptureEngine.stop()` awaits the poll
/// task's actual completion before anything reallocates/deallocates the buffer being pointed to
/// (see `stop()`'s doc comment) — so exactly one reader/writer ever touches it at a time.
private struct UnsafeSendableBuffer: @unchecked Sendable {
    let pointer: UnsafeMutableRawBufferPointer
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

    /// What `startStreaming`/`captureSingleExposure` request via `ASISetROIFormat` — defaults to
    /// the full sensor, settable via `setROI(width:height:)`. Centralized here (rather than
    /// threaded as a parameter through every call site) so a smaller ROI, once set, persists
    /// automatically across live streaming, single exposures, and dark/flat calibration captures
    /// alike — exactly the "smaller ROI -> faster FPS" workflow real planetary/lunar capture tools
    /// (FireCapture, SharpCap) support, without every future capture path needing to remember to
    /// pass it along.
    private var desiredWidth: Int
    private var desiredHeight: Int
    /// Where a smaller-than-full-sensor ROI should be *centered*, in full-sensor pixel
    /// coordinates — defaults to the sensor's own center. `nil` `centerX`/`centerY` in `setROI`
    /// means "keep it centered on the sensor," not "reuse whatever was there before," so
    /// switching to a smaller ROI without explicitly requesting an off-center position doesn't
    /// require the caller to already know the sensor's dimensions.
    private var desiredCenterX: Int
    private var desiredCenterY: Int
    /// `ASISetROIFormat`'s 4th parameter — pixel binning (1 = off, 2 = 2×2). Per the ASI SDK's own
    /// doc comment on that call ("the width and height is the value after binning... at bin2 or
    /// bin3 mode, the position is relative to the image after binning"), width/height/center here
    /// are always in *binned*-image space once this is &gt; 1 — `camera.maxWidth`/`maxHeight` (raw,
    /// unbinned sensor size) alone would be wrong as a "full frame" bound or a start-position
    /// sensor size the moment binning is on, hence every use of them below divides by this first.
    private var desiredBinning: Int = 1

    private var continuation: AsyncStream<CapturedFrame>.Continuation?
    private var onCameraRemoved: (@Sendable () -> Void)?
    /// Fires for any `pollLoop` error that isn't `.timeout` (expected, retried silently) or
    /// `.cameraRemoved` (its own callback, which also forgets the camera) — e.g. a flaky USB link
    /// returning a general SDK error mid-stream. Without this, `pollLoop` used to just quietly end
    /// the stream: the caller's `for await` loop exited with nothing after it, `isLiveViewActive`
    /// stayed `true`, and no error ever surfaced — the app looked like it was still streaming while
    /// producing nothing, with no way to recover short of a full disconnect/reconnect.
    private var onStreamError: (@Sendable (Error) -> Void)?

    init(camera: ZWOCameraInfo) {
        self.camera = camera
        self.desiredWidth = camera.maxWidth
        self.desiredHeight = camera.maxHeight
        self.desiredCenterX = camera.maxWidth / 2
        self.desiredCenterY = camera.maxHeight / 2
    }

    /// Sets the ROI width/height/center/binning future `startStreaming`/`captureSingleExposure`
    /// calls will request — `nil` width/height resets to the full (binned) sensor. `binning`
    /// (1 or 2 — 2×2 pixel binning, the deep-sky "trade resolution for SNR/frame-rate" toggle)
    /// changes what "full sensor"/the clamp ceiling/`centerX`/`centerY` actually mean, per the ASI
    /// SDK's own doc comment on `ASISetROIFormat`: width/height/position are always in *binned*-
    /// image-space pixels once binning is on, not raw sensor pixels — see `desiredBinning`'s own
    /// doc comment. Width/height are validated/clamped to the ASI SDK's own hard constraints
    /// (`ASISetROIFormat`: width a multiple of 8, height a multiple of 2) and to the sensor's real
    /// (binned) dimensions, rather than trusting the caller to have already done that;
    /// `centerX`/`centerY` (binned-sensor pixel coordinates), if given, are resolved to a top-left
    /// start position at request time (see `ROIGeometry.startPosition`) — `nil` means centered on
    /// the sensor. Doesn't itself restart
    /// any in-progress stream — the caller (`CameraManager`) is responsible for stopping and
    /// restarting streaming for a new ROI to actually take effect, the same way switching
    /// RAW8/RAW16 format already works.
    func setROI(width: Int?, height: Int?, centerX: Int? = nil, centerY: Int? = nil, binning: Int = 1) {
        desiredBinning = binning
        let maxWidth = camera.maxWidth / binning
        let maxHeight = camera.maxHeight / binning
        guard let width, let height else {
            desiredWidth = maxWidth
            desiredHeight = maxHeight
            desiredCenterX = maxWidth / 2
            desiredCenterY = maxHeight / 2
            return
        }
        desiredWidth = ROIGeometry.clampedDimension(width, maximum: maxWidth, multipleOf: 8)
        desiredHeight = ROIGeometry.clampedDimension(height, maximum: maxHeight, multipleOf: 2)
        desiredCenterX = centerX ?? maxWidth / 2
        desiredCenterY = centerY ?? maxHeight / 2
    }

    /// `ASISetStartPos(cameraID:startX:startY:)` for whatever `desiredWidth`/`desiredHeight`
    /// were just handed to `ASISetROIFormat` — must run right after it (both `startStreaming` and
    /// `captureSingleExposure` call this immediately following their own `setROIFormat` call), per
    /// `ROIGeometry.startPosition`'s doc comment on why this can't just be skipped.
    private func applyStartPosition(width: Int, height: Int) throws {
        let start = ROIGeometry.startPosition(
            width: width, height: height, centerX: desiredCenterX, centerY: desiredCenterY,
            sensorWidth: camera.maxWidth / desiredBinning, sensorHeight: camera.maxHeight / desiredBinning
        )
        try ZWOSDK.setStartPos(cameraID: camera.cameraID, startX: start.x, startY: start.y)
    }

    /// Reads back the top-left position `ASISetStartPos` actually applied — lets a caller confirm
    /// the camera really did land where `applyStartPosition` last asked, rather than only trusting
    /// that the SDK call didn't throw. Mainly useful for surfacing that confirmation in the UI
    /// right after a Capture ROI change, the same "verify the fix actually took effect" spirit
    /// that found the original always-top-left-corner bug this whole `centerX`/`centerY` machinery
    /// exists to fix (see `ROIGeometry.startPosition`'s doc comment).
    func currentStartPosition() throws -> (x: Int, y: Int) {
        try ZWOSDK.getStartPos(cameraID: camera.cameraID)
    }

    /// Live frame stream for the currently-connected camera. Consuming code (the renderer)
    /// should iterate this with `for await`; frames stop arriving once `stop()` is called.
    /// `onCameraRemoved` fires (off the actor) if a poll reports `ASI_ERROR_CAMERA_REMOVED`.
    /// `onStreamError` fires for any other real error the poll loop hits (not a `.timeout`, which
    /// is expected and retried silently) — see its own doc comment for why this exists separately.
    func frames(
        onCameraRemoved: @escaping @Sendable () -> Void,
        onStreamError: @escaping @Sendable (Error) -> Void
    ) -> AsyncStream<CapturedFrame> {
        self.onCameraRemoved = onCameraRemoved
        self.onStreamError = onStreamError
        return AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    /// Configures the camera for video capture in `imageType`, at whatever ROI/binning
    /// `setROI(width:height:binning:)` last requested (the full sensor, unbinned, by default), and
    /// starts the background poll loop. Call `frames(onCameraRemoved:)` first to obtain the
    /// stream. Safe to call again with a different `imageType` after `stop()`.
    func startStreaming(imageType: ASI_IMG_TYPE = ASI_IMG_RAW8) throws {
        guard !isRunning else { return }

        let width = desiredWidth
        let height = desiredHeight
        try ZWOSDK.setROIFormat(
            cameraID: camera.cameraID,
            width: width,
            height: height,
            binning: desiredBinning,
            imageType: imageType
        )
        try applyStartPosition(width: width, height: height)
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
        if isRunning { await stop() }

        let width = desiredWidth
        let height = desiredHeight
        try ZWOSDK.setROIFormat(
            cameraID: camera.cameraID,
            width: width,
            height: height,
            binning: desiredBinning,
            imageType: imageType
        )
        try applyStartPosition(width: width, height: height)
        let format = try ZWOSDK.getROIFormat(cameraID: camera.cameraID)

        let exposureCaps = try ZWOSDK.allControlCaps(cameraID: camera.cameraID)
            .first { $0.controlType.rawValue == ASI_EXPOSURE.rawValue }
        // `ASI_EXPOSURE` is a single shared hardware register — also the one live-view video
        // streaming reads every frame. Setting it below for a (typically much longer) single
        // still capture and never restoring it left live view, after `resumeLiveView()`, silently
        // running at *this* exposure length instead of whatever it was streaming at before — a
        // multi-second-per-frame live view looks indistinguishable from a frozen black screen.
        // Captured and restored here, at function scope, so the `defer` fires on *every* exit
        // path (success, thrown error, or cancellation), not just falling off the end of the
        // `if exposureCaps != nil` block below.
        let previousExposure = exposureCaps != nil
            ? try? ZWOSDK.getControlValue(cameraID: camera.cameraID, controlType: ASI_EXPOSURE)
            : nil
        defer {
            if let previousExposure {
                try? ZWOSDK.setControlValue(
                    cameraID: camera.cameraID,
                    controlType: ASI_EXPOSURE,
                    value: previousExposure.value,
                    isAuto: previousExposure.isAuto
                )
            }
        }
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

    /// `async` specifically so this can `await pollTask?.value` — without that, a caller (like
    /// `captureSingleExposure`, which reuses/reallocates `frameBuffer` right after calling this)
    /// could start touching that buffer while `pollLoop`'s last in-flight `ASIGetVideoData` call
    /// (up to 500ms, per `pollLoop`'s own doc comment) is still writing into it on a background
    /// queue — `FrameBuffer.ensureCapacity` deallocates the old pointer outright, so that race
    /// is a real use-after-free, not just a torn frame.
    func stop() async {
        isRunning = false
        let task = pollTask
        pollTask = nil
        continuation?.finish()
        continuation = nil
        task?.cancel()
        await task?.value
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

    /// Sensor temperature + dropped-frame count, for `CameraManager`'s periodic diagnostics poll.
    /// Routed through this actor rather than called directly from `@MainActor` (an earlier version
    /// did exactly that) — per the "Strict Threading" rule every other blocking `ZWOSDK` call in
    /// this file already follows: while live streaming, `pollLoop` is continuously calling
    /// `ASIGetVideoData` for this same camera ID on its own background queue, so a *second*,
    /// unrelated blocking SDK call for the same camera arriving from `@MainActor` every 2 seconds
    /// could contend with it at the USB/firmware level, and — since a plain (non-`.detached`)
    /// `Task` created from a `@MainActor` method inherits that isolation for its whole body —
    /// would literally block the main thread for however long that contention took to resolve.
    /// That's exactly what "small Capture ROI + live view slows down and flickers" turned out to
    /// still be happening from, even after throttling the display refresh separately: a periodic
    /// main-thread stall from this poll, worse the higher the real frame rate (more frames back
    /// up during each stall). Routing it through the actor instead means it's just one more call
    /// queued behind whatever `pollLoop` is doing, on the actor's own background execution
    /// context — never blocking the main thread, and never racing the video poll for the SDK
    /// itself since both now go through the same serializing actor.
    func refreshDiagnostics() -> (temperature: ZWOControlValue?, droppedFrames: Int?) {
        let temperature = try? ZWOSDK.getControlValue(cameraID: camera.cameraID, controlType: ASI_TEMPERATURE)
        let droppedFrames = try? ZWOSDK.getDroppedFrames(cameraID: camera.cameraID)
        return (temperature, droppedFrames)
    }

    /// - Important: Every iteration's blocking `ASIGetVideoData` call (up to 500ms, per its
    ///   `waitMilliseconds`) runs via `fetchVideoData`'s continuation, on a background queue —
    ///   *not* inline on the actor. `CaptureEngine` is a single actor: an `await`-free `while`
    ///   loop calling a blocking function directly would run to completion (or until `isRunning`
    ///   goes false) without ever hitting a suspension point, meaning the actor could never
    ///   schedule any *other* call routed through it — `captureSingleExposure`, `stop()`,
    ///   anything — for as long as this loop kept looping, i.e. for as long as live view was
    ///   streaming. That's exactly what made "press Capture while live view is running" hang
    ///   forever: the call to `captureSingleExposure` genuinely never got to start. Routing the
    ///   blocking call through a real suspension point lets the actor interleave other work
    ///   between iterations, the same way any other actor is expected to behave.
    private func pollLoop() async {
        while isRunning, !Task.isCancelled {
            guard let buffer = frameBuffer, let format = currentFormat else { break }
            do {
                try await Self.fetchVideoData(
                    cameraID: camera.cameraID,
                    buffer: UnsafeSendableBuffer(pointer: buffer.pointer),
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
                // Any other SDK error: stop cleanly rather than spinning on a broken capture, but
                // tell the caller *why* — see `onStreamError`'s own doc comment.
                isRunning = false
                onStreamError?(error)
                break
            }
        }
        continuation?.finish()
    }

    /// Runs the blocking `ASIGetVideoData` call on a background queue and resumes via a
    /// continuation — a real `await` suspension point for `pollLoop`'s caller (the actor), unlike
    /// calling the blocking SDK function directly inline. `static`/`nonisolated` on purpose: it
    /// must not touch actor-isolated state itself, since the whole point is that it runs *while*
    /// the actor is free to do other work.
    private static func fetchVideoData(
        cameraID: Int32, buffer: UnsafeSendableBuffer, waitMilliseconds: Int32
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try ZWOSDK.getVideoData(cameraID: cameraID, buffer: buffer.pointer, waitMilliseconds: waitMilliseconds)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
