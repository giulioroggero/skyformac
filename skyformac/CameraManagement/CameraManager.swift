import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Metal
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

/// One targeted starting point (ROI, exposure, gain, a recommended max SER video length, and a
/// histogram target to fine-tune against) for a specific bright solar-system target —
/// `CameraManager.applyPlanetaryPreset` applies the concrete numbers; getting the *histogram*
/// itself into the recommended range still needs the operator's own live adjustment, since that
/// depends on the actual night's seeing/transparency, not just which target this is.
///
/// The numbers below assume a modern ~2µm-pixel planetary CMOS camera (e.g. a ZWO ASI678MC)
/// behind a modest f/10-f/12 Maksutov/SCT — that pixel-scale/focal-ratio pairing needs no Barlow
/// to reach a good sampling rate, so these presets don't add one. A different camera/telescope
/// combination may need the exposure/gain starting points nudged, but the ROI sizes and workflow
/// (small ROI for FPS, RAW8 + SER for AutoStakkert!3-style downstream processing) still apply.
enum PlanetaryPreset: String, CaseIterable, Identifiable {
    case saturn = "Saturn"
    case jupiter = "Jupiter"
    case mars = "Mars"
    case venus = "Venus"
    case moon = "Moon (Detail)"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .saturn: return "circle.dotted.and.circle"
        case .jupiter: return "circle.hexagonpath"
        case .mars: return "circle.fill"
        case .venus: return "sun.max"
        case .moon: return "moon.fill"
        }
    }

    /// `nil` means the full sensor — Moon detail work wants the whole frame, not a crop, since
    /// the target itself is much larger in frame than a planet's disk.
    var roi: (width: Int, height: Int)? {
        switch self {
        case .saturn: return (800, 600)
        case .jupiter: return (800, 600)
        case .mars: return (400, 400)
        case .venus: return (640, 480)
        case .moon: return nil
        }
    }

    var exposureRangeSeconds: ClosedRange<Double> {
        switch self {
        case .saturn: return 0.015...0.025
        case .jupiter: return 0.005...0.010
        case .mars: return 0.002...0.006
        case .venus: return 0.001...0.004
        case .moon: return 0.002...0.008
        }
    }

    /// The ASI678MC's High Conversion Gain mode kicks in at 182 — its own real read-noise drop,
    /// not a rule of thumb — which is why Saturn/Jupiter/Mars all start at or above it while
    /// Venus (bright enough not to need it) and Moon detail work don't require reaching it.
    var gainRange: ClosedRange<Int> {
        switch self {
        case .saturn: return 200...280
        case .jupiter: return 182...240
        case .mars: return 182...220
        case .venus: return 100...182
        case .moon: return 100...182
        }
    }

    var recommendedMaxDurationSeconds: Double {
        switch self {
        case .saturn: return 180
        case .jupiter: return 120
        case .mars: return 240
        case .venus: return 180
        case .moon: return 60
        }
    }

    var histogramTargetPercent: ClosedRange<Double> {
        switch self {
        case .saturn: return 50...60
        case .jupiter: return 60...70
        case .mars: return 60...70
        case .venus: return 70...70
        case .moon: return 60...75
        }
    }

    /// What `applyPlanetaryPreset` actually sets — the *low* end of each range (see its own doc
    /// comment for why: safer to start under-exposed and raise while watching the live histogram
    /// than to start already near clipping).
    var startingExposureSeconds: Double { exposureRangeSeconds.lowerBound }
    var startingGain: Int { gainRange.lowerBound }

    var note: String? {
        self == .jupiter
            ? "Jupiter's own rotation blurs fine cloud detail in videos longer than ~2 minutes — keep sessions short."
            : nil
    }
}

/// A common telescope configuration, for scaling `PlanetaryPreset`'s starting exposure to how
/// much light it actually delivers per pixel — see `PlanetaryPreset.startingExposureSeconds
/// (for:)` for the actual relationship. Aperture and focal length are what matter, not telescope
/// "type" as such: a bigger aperture gathers more light for the same exposure, a longer focal
/// length spreads that light over more sensor pixels (higher magnification) instead, and it's
/// the *ratio* of the two — the focal ratio, f/number, exactly the same quantity a camera lens's
/// own f/stop is — that actually determines brightness per pixel.
enum TelescopeProfile: String, CaseIterable, Identifiable {
    case maksutov90 = "Maksutov 90mm f/13.9 (1250mm)"
    case maksutov102 = "Maksutov 102mm f/12.7 (1300mm)"
    case maksutov127 = "Maksutov 127mm f/11.8 (1500mm)"
    case maksutov150 = "Maksutov 150mm f/12 (1800mm)"
    case sct8 = "8\" SCT f/10 (2032mm)"
    case sct925 = "9.25\" SCT f/10 (2350mm)"
    case newtonian130 = "Newtonian 130mm f/5 (650mm)"
    case newtonian200 = "Newtonian 200mm f/5 (1000mm)"
    case refractor80 = "Refractor 80mm f/7.5 (600mm)"
    case refractor102 = "Refractor 102mm f/6.9 (700mm)"

    var id: String { rawValue }

    /// (aperture mm, focal length mm) — real, commonly-sold specs for each listed configuration.
    private var dimensions: (aperture: Double, focalLength: Double) {
        switch self {
        case .maksutov90: return (90, 1250)
        case .maksutov102: return (102, 1300)
        case .maksutov127: return (127, 1500)
        case .maksutov150: return (150, 1800)
        case .sct8: return (203, 2032)
        case .sct925: return (235, 2350)
        case .newtonian130: return (130, 650)
        case .newtonian200: return (200, 1000)
        case .refractor80: return (80, 600)
        case .refractor102: return (102, 700)
        }
    }

    var apertureMillimeters: Double { dimensions.aperture }
    var focalLengthMillimeters: Double { dimensions.focalLength }
    var focalRatio: Double { focalLengthMillimeters / apertureMillimeters }

    /// What `PlanetaryPreset`'s existing numbers are already tuned for — a Maksutov 127mm/1500mm
    /// (f/11.8), squarely inside the "f/10-f/12" range `PlanetaryPreset`'s own doc comment
    /// describes. Scaling by this specific case is a no-op.
    static let reference: TelescopeProfile = .maksutov127
}

extension PlanetaryPreset {
    /// `startingExposureSeconds` scaled for `telescope`'s focal ratio relative to
    /// `TelescopeProfile.reference` — illuminance per pixel scales with `1/focalRatio²` (the same
    /// relationship an ordinary camera's exposure triangle already uses for f/stop), so a faster
    /// (lower f/number) scope needs proportionally less exposure for the same target brightness,
    /// a slower one more. Clamped to a sane absolute range (0.05ms...5s) since an extreme enough
    /// scope could otherwise scale this into a nonsensical starting point.
    ///
    /// Deliberately doesn't also scale `startingGain` — exposure alone already captures the same
    /// physical relationship, and touching gain too would double-compensate for it. Camera
    /// sensitivity (a different sensor's own ADU-per-photon response) is a separate, likely
    /// larger factor this can't account for at all — these are still starting points to fine-tune
    /// against the live histogram, not exact values for any specific telescope/camera pairing.
    func startingExposureSeconds(for telescope: TelescopeProfile) -> Double {
        let scale = pow(telescope.focalRatio / TelescopeProfile.reference.focalRatio, 2)
        return min(max(startingExposureSeconds * scale, 0.00005), 5.0)
    }

    /// `exposureRangeSeconds`, scaled the same way `startingExposureSeconds(for:)` scales the
    /// low end of it — for displaying the actual range a given telescope should expect, not the
    /// reference telescope's own range regardless of which one is actually selected.
    func exposureRangeSeconds(for telescope: TelescopeProfile) -> ClosedRange<Double> {
        let scale = pow(telescope.focalRatio / TelescopeProfile.reference.focalRatio, 2)
        let low = min(max(exposureRangeSeconds.lowerBound * scale, 0.00005), 5.0)
        let high = min(max(exposureRangeSeconds.upperBound * scale, 0.00005), 5.0)
        return low...max(high, low)
    }
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

    // MARK: - iPhone/webcam focus lock

    /// Mirrors whatever `WebcamCaptureEngine.setFocusLocked` last actually applied — not written
    /// optimistically before that call succeeds, same reasoning as `startPreview`'s
    /// `isLiveViewActive` fix (see `docs/design-notes.md`).
    private(set) var isWebcamFocusLocked = false

    /// A webcam/Continuity Camera device's continuous autofocus actively fights afocal
    /// projection — it keeps hunting for a "normal" subject distance and refocuses away from
    /// the telescope's actual focal plane. Locking freezes focus at whatever position it
    /// currently sits at; unlocking returns to continuous autofocus.
    func setWebcamFocusLocked(_ locked: Bool) {
        guard let engine = webcamEngine else { return }
        Task {
            do {
                try await engine.setFocusLocked(locked)
                isWebcamFocusLocked = locked
            } catch {
                lastErrorMessage = String(describing: error)
            }
        }
    }

    // MARK: - iPhone/webcam Night Mode (frame-stacked simulated long exposure)

    private var nightModeAccumulator: LiveStacker?
    private var nightModeTask: Task<Void, Never>?
    private(set) var isCapturingNightMode = false
    private(set) var nightModeTotalSeconds: Double = 0
    private(set) var nightModeRemainingSeconds: Double = 0

    /// "Night Mode" for the iPhone/webcam path — there's no controllable hardware exposure to
    /// speak of (see `captureSingleExposure`'s `cameraID == -2` branch, which just freezes the
    /// current live frame), so a literal single 10-60-second sensor exposure isn't a real thing
    /// a live video pipeline can do — an individual video frame can't be tens of seconds long
    /// and still be a video frame. Instead this accumulates that many seconds of live frames via
    /// the same running-average `LiveStacker` "Live Stack" already uses, then freezes on the
    /// result — the same computational multi-frame-stacking mechanism Apple's own iPhone Night
    /// Mode actually uses internally, not a fabricated stand-in for it. Uses its own
    /// `LiveStacker` instance rather than `liveStacker` so this doesn't interact with the user's
    /// own independent Live Stack toggle/state.
    func startIPhoneNightModeCapture(seconds: Double) {
        guard isExternalWebcam, !isCapturingNightMode else { return }
        nightModeAccumulator = LiveStacker()
        isCapturingNightMode = true
        nightModeTotalSeconds = seconds
        nightModeRemainingSeconds = seconds

        nightModeTask = Task { [weak self] in
            let tickNanoseconds: UInt64 = 200_000_000
            var elapsed = 0.0
            while elapsed < seconds {
                try? await Task.sleep(nanoseconds: tickNanoseconds)
                if Task.isCancelled { return }
                elapsed += Double(tickNanoseconds) / 1_000_000_000
                await MainActor.run { self?.nightModeRemainingSeconds = max(seconds - elapsed, 0) }
            }
            await MainActor.run { self?.finishIPhoneNightModeCapture() }
        }
    }

    /// Discards whatever's accumulated so far and returns to a normal live view — unlike
    /// finishing normally, a cancelled capture has no usable "result" to freeze on (an
    /// average of only a fraction of a second's worth of frames isn't a meaningful long exposure).
    func cancelIPhoneNightModeCapture() {
        nightModeTask?.cancel()
        nightModeTask = nil
        nightModeAccumulator = nil
        isCapturingNightMode = false
        nightModeRemainingSeconds = 0
    }

    private func finishIPhoneNightModeCapture() {
        if let result = nightModeAccumulator?.currentAverage() {
            // Without this, the still-running `frameConsumerTask` (the webcam's `for await frame
            // in stream` loop never actually stopped for Night Mode the way it does for
            // `captureSingleExposure`) would deliver its next live frame within ~33ms and
            // overwrite `currentFrame` right back to a single unstacked frame — the averaged
            // result would flash for one render pass, if that, before vanishing. Same
            // stream-must-actually-stop-to-freeze-a-result fix `captureSingleExposure` already
            // applies for the same reason.
            frameConsumerTask?.cancel()
            frameConsumerTask = nil
            currentFrame = result
            frameID &+= 1
            refreshCurrentImage()
            isLiveViewActive = false
        }
        nightModeAccumulator = nil
        isCapturingNightMode = false
        nightModeRemainingSeconds = 0
        nightModeTask = nil
    }

    private(set) var controls: [ZWOControlCaps] = []
    private(set) var controlValues: [Int32: ZWOControlValue] = [:]
    private(set) var connectionState: CameraConnectionState = .disconnected
    private(set) var lastErrorMessage: String?

    /// ZWO's own recommended gain/offset reference points for the connected camera model — see
    /// `ZWOSDK.GainOffsetPresets`'s doc comment. `nil` when no camera's connected, or the
    /// connected one doesn't support the underlying `ASIGetGainOffset`/`ASIGetLMHGainOffset`
    /// calls (older/simpler sensor models) — either way, the UI should just not show them rather
    /// than treat it as an error.
    private(set) var gainOffsetPresets: ZWOSDK.GainOffsetPresets?
    private(set) var lmhGainOffsetPresets: ZWOSDK.LMHGainOffsetPresets?

    /// Refreshed periodically by `diagnosticsPollTask` while a ZWO camera is connected —
    /// `nil` until the first successful poll. Sensor temperature used to only ever be read once,
    /// at connect time (`ASI_TEMPERATURE`'s `controlRow` reads `controlValues`, which nothing
    /// updated again afterward) — this same poll refreshes that too, so both actually track the
    /// live camera instead of freezing at whatever they were on connect.
    private(set) var droppedFrameCount: Int?
    private var diagnosticsPollTask: Task<Void, Never>?

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
    /// "Independent Channels" mode — three separate black/white points instead of one shared
    /// pair, for compensating a color imbalance (e.g. a light-polluted sky's orange cast)
    /// directly at the stretch stage. Only meaningful for a color source; `HistogramView` only
    /// shows the toggle for one. `channelStretch` itself is left alone when this is off (so
    /// turning it back on later restores whatever was last dialed in) — `effectiveChannelStretch`
    /// is what rendering actually reads, falling back to `stretch` applied uniformly.
    var isIndependentChannelStretchEnabled = false {
        didSet { refreshCurrentImage() }
    }
    var channelStretch = PerChannelStretch.identity {
        didSet { if isIndependentChannelStretchEnabled { refreshCurrentImage() } }
    }
    /// What the render paths (GPU `MetalFrameRenderer`, CPU `CGImageRenderer`) actually read —
    /// `channelStretch` verbatim when independent mode is on, or `stretch` applied uniformly to
    /// all three channels otherwise, so neither render path needs its own branch for the toggle.
    var effectiveChannelStretch: PerChannelStretch {
        isIndependentChannelStretchEnabled ? channelStretch : PerChannelStretch(uniform: stretch)
    }
    /// "Curves" tab — post-stretch tone-curve grading, off by default. `toneCurves` is left alone
    /// when this is off, same reasoning as `channelStretch` above.
    var isToneCurveEnabled = false {
        didSet { refreshCurrentImage() }
    }
    var toneCurves = ChannelToneCurves.identity {
        didSet { if isToneCurveEnabled { refreshCurrentImage() } }
    }
    /// Set on a fresh ZWO connection (see `connect(to:)`) — `.identity` is a safe *interim* value
    /// (better than inheriting an unrelated previous session's black/white point), but it's a bad
    /// permanent default for a real linear sensor: real signal only occupies a small fraction of
    /// the full digital range, so `.identity` alone renders as solid black at any reasonable
    /// gain. `ingest()` consumes this exactly once, auto-stretching from the first real frame's
    /// own histogram (`DisplayStretch.autoStretch`) as soon as one arrives.
    private var pendingAutoStretch = false

    /// `true` while continuously polling video frames; `false` while showing a still frame
    /// from `captureSingleExposure`.
    private(set) var isLiveViewActive = true
    private(set) var isCapturingExposure = false
    /// Wall-clock start time + requested length of whichever exposure is currently running
    /// (`captureSingleExposure`/`captureDarkFrame`/`captureFlatFrame` all set these alongside
    /// `isCapturingExposure`) — lets the UI show a real countdown instead of only an
    /// indeterminate spinner, which gave no sense of how much longer a long exposure had left.
    private(set) var capturingExposureStartDate: Date?
    private(set) var capturingExposureDurationSeconds: Double?

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
    /// Per-channel companion to `gpuHistogramCounts` — `nil` whenever the connected source has no
    /// separate channels to show (a mono ZWO camera; `MetalFrameRenderer` simply never fires this
    /// for one) or the GPU render path isn't active. Powers `HistogramView`'s "By Channel" display.
    var gpuChannelHistogramCounts: (red: [Int], green: [Int], blue: [Int])?

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
    /// Same "lifted up" reasoning as `isNightModeEnabled` above — the preview's own overlay
    /// button for this was reported unclickable (same screen-position issue as the sidebar tab
    /// picker; see `docs/design-notes.md`), so the menu bar (`SkyformacCommands`) and the
    /// sidebar's vertical tab strip (`ControlsPanelView`) both need to drive this too, not just
    /// the overlay button.
    var isPreviewFullScreenEnabled = false
    /// Drives whether the Histogram/Curves tabs live inline (under the preview, the default) or
    /// in a separate floating `NSPanel` (`HistogramCurvesPanelController`) — a real AppKit panel
    /// the app opens/closes itself, not a second SwiftUI `Window` scene, so `SkyformacApp`'s
    /// single-`Scene` constraint holds regardless of whether it's open.
    var isHistogramPanelDetached = false
    /// Drives the Help `.sheet` on `ContentView` — the app is deliberately single-window (see
    /// `SkyformacApp`), so Help lives as a sheet on the one main window rather than its own
    /// `Window` scene.
    var isHelpPresented = false
    /// Drives the Acquisition Wizard `.sheet` on `ContentView` — same single-window reasoning as
    /// `isHelpPresented` above.
    var isAcquisitionWizardPresented = false
    /// Set by `showHelp(topicID:sectionID:)` — read once by `HelpView`'s `init` when
    /// `ContentView`'s sheet constructs it, to open directly to a specific setting's explanation
    /// instead of always landing on the first topic. `sectionID` matches a `HelpSection.id` in
    /// `HelpContent` (the `HelpLinkButton` next to each setting in `ControlsPanelView` passes the
    /// matching one).
    private(set) var helpAnchorTopicID: String?
    private(set) var helpAnchorSectionID: String?

    /// Opens Help scrolled directly to one setting's explanation — every "?" `HelpLinkButton`
    /// next to a control in `ControlsPanelView` calls this instead of just `isHelpPresented =
    /// true`, so "what does this actually do" is one click away from the control itself rather
    /// than a manual hunt through the Help topic list (search helps too, but a direct link is
    /// still faster when you already know which control you're looking at).
    func showHelp(topicID: String, sectionID: String? = nil) {
        helpAnchorTopicID = topicID
        helpAnchorSectionID = sectionID
        isHelpPresented = true
    }
    /// Drives `NavigationSplitView`'s `columnVisibility` in `ContentView` — lifted up (same
    /// reasoning as the properties above) specifically because the native sidebar-toggle button
    /// was reported to have no way back once the sidebar was collapsed: with no binding of our
    /// own, that toggle button was the *only* path to `columnVisibility`, and whatever went
    /// wrong with it left no fallback. This gives the menu bar (`SkyformacCommands`) an
    /// independent path to the same state, the same "when a click path is unreliable, add one
    /// that doesn't depend on it" fix already used for the sidebar tab picker and Full Screen.
    var isCameraListSidebarVisible = true

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

    /// Shared by `scheduleFocusAssistIfNeeded`/`scheduleStreakDetectionIfNeeded` in place of the
    /// CPU `CGImageRenderer.makeDisplayImage` — a debayer+stretch is real GPU-shaped work
    /// (`Debayer`'s bilinear demosaic plus a per-pixel LUT loop), so running it via the same
    /// Metal kernels `MetalFrameRenderer` uses for live display is meaningfully cheaper than the
    /// CPU path, even though that CPU path already runs off `@MainActor`. `nil` (falls back to
    /// the CPU renderer below) only when the machine has no usable Metal device/library, which
    /// shouldn't happen on any Mac this app targets. An `actor`, so it's safe to share between
    /// the two independent background tasks without them racing on its mutable textures.
    @ObservationIgnored private lazy var gpuStillImageRenderer: GPUStillImageRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return GPUStillImageRenderer(device: device)
    }()

    /// Used by `applyDarkSubtraction` in place of `FrameArithmetic.subtract`/
    /// `FlatFieldCorrector.correct` when the Metal renderer is enabled — see
    /// `GPUFrameCalibrator`'s doc comment for why this still reads a result back to CPU-resident
    /// `Data` rather than staying GPU-resident (planetary tracking/lucky imaging/FITS recording
    /// all need the calibrated frame on the CPU side too, not just the live preview).
    @ObservationIgnored private lazy var gpuFrameCalibrator: GPUFrameCalibrator? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        return GPUFrameCalibrator(device: device)
    }()

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

    /// Set by `MetalPreviewView` to `{ [weak renderer] imageType in renderer?
    /// .currentAccumulatedFrame(imageType: imageType) }` once the Metal view exists — lets
    /// `frameForExport()` pull back the GPU live-stack accumulator's current average as a real
    /// `CapturedFrame`. Needed because that accumulator lives entirely inside
    /// `MetalFrameRenderer` (owned by the view's own `Coordinator`), which `CameraManager`
    /// otherwise has no reference to at all — without this, `currentFrame` on the GPU render path
    /// is only ever the latest *raw, unstacked* frame (the accumulation is display-only there),
    /// so exporting "the current frame" while Live Stack was running on the GPU path silently
    /// exported a single frame instead of the stack. `@ObservationIgnored` since a closure
    /// reference isn't UI-observable state.
    @ObservationIgnored var gpuAccumulatedFrameProvider: ((ASI_IMG_TYPE) -> CapturedFrame?)?

    var isLiveStackingEnabled = false {
        didSet {
            liveStacker.reset()
            liveStackGeneration &+= 1
            gpuLiveStackFrameCount = 0
            isLiveStackPaused = false
            smartStackKeptCount = 0
            smartStackRejectedCount = 0
            smartStackLastRejectionReason = nil
            smartStackMaxObservedScore = 0
            if !isLiveStackingEnabled { isSmartLiveStackEnabled = false }
        }
    }
    /// Freezes the running stack — `ingest`/`MetalFrameRenderer.process` both keep displaying
    /// whatever's already accumulated (and exporting it correctly, since `frameForExport` reads
    /// the same frozen `currentFrame`/GPU accumulator either way) but stop folding in new frames,
    /// so a session can be paused to actually look at the current result — check focus, judge
    /// whether alignment is holding up, decide whether to keep going — without losing it the way
    /// `resetLiveStack` would. Resuming just un-pauses; nothing about the accumulator itself
    /// changes across a pause/resume, unlike toggling Live Stack itself off and back on.
    var isLiveStackPaused = false
    func resetLiveStack() {
        liveStacker.reset()
        liveStackGeneration &+= 1
        gpuLiveStackFrameCount = 0
        isLiveStackPaused = false
        smartStackKeptCount = 0
        smartStackRejectedCount = 0
        smartStackLastRejectionReason = nil
        smartStackMaxObservedScore = 0
    }

    // MARK: - Smart Live Stack (autopilot: live-curates which frames actually join the stack)

    /// Turns Live Stack from a plain running average into a self-curating one — each incoming
    /// frame is scored (`GPUSharpnessScorer`, the same scorer `recordIfNeeded`'s quality gate
    /// already uses) and only folded into the accumulator if it clears `smartLiveStackQualityFraction`
    /// of the sharpest frame this session has seen, or if Cloud Sentinel currently reports an
    /// alert. See `SmartLiveStackGate`'s doc comment for the full reasoning — this replaces the
    /// traditional "record everything, curate afterward in another tool" workflow with live,
    /// per-frame curation, so the stack you're watching build is already the curated one. Session
    /// state, not a persisted preference (matches `isLiveStackingEnabled`'s own scoping) — always
    /// starts back off on a fresh launch.
    var isSmartLiveStackEnabled = false {
        didSet {
            guard isSmartLiveStackEnabled else { return }
            isLiveStackingEnabled = true
            smartStackKeptCount = 0
            smartStackRejectedCount = 0
            smartStackLastRejectionReason = nil
            smartStackMaxObservedScore = 0
        }
    }
    /// Keep frames scoring at least this fraction of the best-seen frame this session — a real
    /// preference (unlike `isSmartLiveStackEnabled` itself), so it persists across launches.
    var smartLiveStackQualityFraction: Double = AppSettings.smartLiveStackQualityFraction {
        didSet { AppSettings.smartLiveStackQualityFraction = smartLiveStackQualityFraction }
    }
    private(set) var smartStackKeptCount = 0
    private(set) var smartStackRejectedCount = 0
    private(set) var smartStackLastRejectionReason: SmartLiveStackRejectionReason?
    private var smartStackMaxObservedScore: Double = 0
    /// Whether the frame `ingest` just processed should be excluded from this frame's stack
    /// update — recomputed fresh every `ingest` call, read by `MetalPreviewView` (folded into
    /// `effectiveLiveStackPaused`) so the GPU accumulation path respects the same per-frame
    /// decision the CPU path (`ingest`'s `usesCPUStack` branch) already does.
    private var smartStackSkipsCurrentFrame = false

    /// What `MetalPreviewView`/`ingest` should actually treat as "paused" for this frame — the
    /// user's own Pause button, *or* Smart Live Stack quality-gating this specific frame out.
    /// Both mean the same thing to the accumulator: don't fold this frame in, keep displaying
    /// whatever's already there.
    var effectiveLiveStackPaused: Bool { isLiveStackPaused || smartStackSkipsCurrentFrame }

    /// The percentage SNR improvement stacking `additionalFrames` more frames would give from
    /// here — see `StackSNREstimator`'s doc comment for the math and how to read a falling trend
    /// as "diminishing returns, might be worth wrapping up soon." `nil` before any frame has been
    /// kept yet.
    func smartStackEstimatedSNRGainPercent(forAdditionalFrames additionalFrames: Int) -> Double? {
        StackSNREstimator.relativeSNRGainPercent(currentFrameCount: liveStackedFrameCount, additionalFrames: additionalFrames)
    }

    /// Scores `frame` (the same GPU sharpness scorer `recordIfNeeded` uses) and decides whether
    /// this frame should join the stack — called once per frame from `ingest`, ahead of the
    /// CPU-accumulation branch, so `smartStackSkipsCurrentFrame` is up to date before either the
    /// CPU path reads it directly or `MetalPreviewView` reads it (via `effectiveLiveStackPaused`)
    /// for the GPU path.
    private func updateSmartLiveStackGate(_ frame: CapturedFrame) {
        guard isSmartLiveStackEnabled, isLiveStackingEnabled else {
            smartStackSkipsCurrentFrame = false
            return
        }
        let score = sharpnessScorer?.score(frame: frame)
        if let score {
            smartStackMaxObservedScore = max(smartStackMaxObservedScore, score)
        }
        let decision = SmartLiveStackGate.decide(
            sharpnessScore: score,
            maxObservedScore: smartStackMaxObservedScore,
            qualityFraction: smartLiveStackQualityFraction,
            isCloudAlertActive: isCloudSentinelEnabled && isCloudAlertActive
        )
        switch decision {
        case .keep:
            smartStackSkipsCurrentFrame = false
            smartStackKeptCount += 1
        case .reject(let reason):
            smartStackSkipsCurrentFrame = true
            smartStackRejectedCount += 1
            smartStackLastRejectionReason = reason
        }
    }
    /// Webcam/iPhone sources always accumulate on the CPU `LiveStacker` even when the GPU render
    /// path is active (see `ingest`'s `shouldAccumulateOnCPU`) — `gpuLiveStackFrameCount` never
    /// advances for them, so reading it here would show a stuck-at-0 counter for a Live Stack
    /// that's actually running.
    var liveStackedFrameCount: Int { (useMetalRenderer && !isExternalWebcam) ? gpuLiveStackFrameCount : liveStacker.frameCount }

    /// GPU-only (see `MetalFrameRenderer`'s "Drift reduction" section) — locks onto the
    /// brightest star in the first stacked frame and shifts every subsequent frame back to that
    /// position (sub-pixel, bilinear-sampled) before adding it into the running sum, so a
    /// drifting (not perfectly tracking — e.g. alt-az) mount doesn't smear stars into short
    /// trails across the stack. No effect on the CPU `LiveStacker` path; the UI disables this
    /// toggle whenever `useMetalRenderer` is off, rather than silently ignoring it.
    var isLiveStackDriftReductionEnabled = false

    /// "Experimental" mesh-based drift correction — an alternative to the single-star lock above,
    /// not a combination with it (`MetalFrameRenderer.process` picks one or the other when both
    /// would otherwise apply, mesh taking priority). See `MeshDriftField`'s doc comment for the
    /// full rationale: an NxN grid of independently-tracked points, blended with bilinear
    /// interpolation, instead of one rigid shift for the whole frame — covers field rotation and
    /// differential drift a single global shift can't, at the cost of a rougher (single-pass,
    /// no background-subtraction) per-vertex measurement than the single-star lock's.
    /// GPU-only, same as the single-star lock.
    var isMeshDriftCorrectionEnabled = false
    var meshDriftConfig = MeshDriftConfig.default
    /// The mesh's current (already-blended) vertex displacements, as last reported by
    /// `MetalFrameRenderer.onMeshDriftUpdate` — purely for `MeshDriftOverlayView`'s "see the
    /// vector overlap" visualization on the live preview; rendering itself never reads this back,
    /// it only ever flows the other direction (`CameraManager` → `MetalFrameRenderer`, via
    /// `meshDriftConfig`). `nil` whenever mesh correction hasn't produced a result yet (just
    /// turned on, or not currently live-stacking).
    var meshDriftVisualization: [SIMD2<Float>]?
    /// Drives `MeshDriftOverlayView` on the live preview — "see the vector overlap" made
    /// concrete: each cell's search window and its current displacement arrow, drawn directly
    /// over the frame it's actually measuring.
    var isMeshDriftOverlayVisible = false

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
        recordExport(url: directory, kind: .recordingFolder)
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
            try FITSWriter.write(
                frame: frame, instrumentName: connectedCamera?.name ?? "skyformac",
                isColorCamera: connectedCamera?.isColorCamera ?? false, bayerPattern: connectedCamera?.bayerPattern ?? ASI_BAYER_RG,
                to: url
            )
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

    // MARK: - SER video recording (planetary/lunar "small ROI, high FPS" lucky-imaging workflow)

    /// Deliberately separate from "Record to Disk" above: that one gates on a sharpness
    /// threshold and writes individual FITS files, because it's meant to run unattended and
    /// self-curate. This one writes *every* frame, undiscarded, into a single `.ser` video — the
    /// classic planetary/lunar capture workflow hands the entire raw video to a dedicated
    /// alignment/stacking tool (AutoStakkert!3, PIPP) that does its own, better-informed frame
    /// selection; pre-discarding frames here would just take that choice away from it.
    @ObservationIgnored private var serWriter: SERWriter?
    private(set) var isRecordingSERVideo = false
    private(set) var serRecordedFrameCount = 0
    /// Frames that arrived while recording but weren't written — see `SERWriter.write`'s
    /// `SERError.blankFrame` doc comment for why a frame can genuinely deserve this instead of
    /// being written (it isn't a sign anything else is wrong; a real blank frame just never
    /// makes it into a file every downstream stacking tool can rely on being free of them).
    private(set) var serSkippedFrameCount = 0
    private(set) var serRecordingElapsedSeconds: Double = 0
    private var serRecordingStartDate: Date?
    private var serRecordingTargetSeconds: Double = 0

    /// Starts writing every incoming (dark-subtracted) frame to `url` as a single SER video,
    /// stopping automatically after `durationSeconds` (or sooner, via `stopSERRecording()`) — the
    /// classic "record N minutes at a small ROI/high frame rate" planetary capture workflow.
    func startSERRecording(to url: URL, durationSeconds: Double) {
        guard let frame = currentFrame, let camera = connectedCamera else { return }
        if let free = DiskSpaceChecker.availableBytes(at: url.deletingLastPathComponent()),
           free < Self.minimumFreeDiskSpaceBytes {
            lastErrorMessage = "Only \(formattedBytes(free)) free on that volume — need at least \(formattedBytes(Self.minimumFreeDiskSpaceBytes)) to start recording."
            return
        }
        do {
            serWriter = try SERWriter(
                firstFrame: frame, isColorCamera: camera.isColorCamera, bayerPattern: camera.bayerPattern,
                instrumentName: camera.name, url: url
            )
        } catch {
            lastErrorMessage = String(describing: error)
            return
        }
        serRecordedFrameCount = 0
        serSkippedFrameCount = 0
        serRecordingElapsedSeconds = 0
        serRecordingTargetSeconds = durationSeconds
        serRecordingStartDate = Date()
        isRecordingSERVideo = true
        recordExport(url: url, kind: .serVideo)
    }

    /// Finalizes the SER file (writes its timestamp trailer and patches the frame count into the
    /// header — see `SERWriter.close()`) and stops recording. Safe to call whether recording
    /// stopped on its own (`durationSeconds` elapsed) or the user is stopping it early.
    func stopSERRecording() {
        guard isRecordingSERVideo else { return }
        isRecordingSERVideo = false
        do {
            try serWriter?.close()
        } catch {
            lastErrorMessage = String(describing: error)
        }
        serWriter = nil
    }

    private func recordSERFrameIfNeeded(_ frame: CapturedFrame) {
        guard isRecordingSERVideo, let serWriter, let startDate = serRecordingStartDate else { return }
        serRecordingElapsedSeconds = Date().timeIntervalSince(startDate)
        guard serRecordingElapsedSeconds < serRecordingTargetSeconds else {
            stopSERRecording()
            return
        }
        do {
            try serWriter.write(frame)
            serRecordedFrameCount += 1
        } catch SERWriter.SERError.blankFrame {
            // Not a real failure — see `SERWriter.write`'s doc comment. Recording continues;
            // this frame just never makes it into the file.
            serSkippedFrameCount += 1
        } catch {
            lastErrorMessage = String(describing: error)
            stopSERRecording()
        }
    }

    // MARK: - Lucky imaging (burst capture + sharpness-ranked stacking — see `LuckyImagingSession`)

    private(set) var luckyImagingSession: LuckyImagingSession?
    var luckyImagingProgress: (captured: Int, total: Int)? {
        luckyImagingSession.map { ($0.capturedCount, $0.targetFrameCount) }
    }
    var isLuckyImagingBurstComplete: Bool { luckyImagingSession?.isComplete ?? false }
    /// Pauses adding new frames to the current burst without losing what's already captured —
    /// the same "freeze without discarding" idea `isLiveStackPaused` already gives Live Stack.
    /// Reset to `false` whenever a new burst starts (`startLuckyImagingBurst`).
    var isLuckyImagingPaused = false

    private var frameConsumerTask: Task<Void, Never>?
    private var focusAssistTask: Task<Void, Never>?
    private var enhancementTask: Task<Void, Never>?
    private var qualityScoreTask: Task<Void, Never>?

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
        // Same leftover-`stretch`-from-a-previous-session concern as `connect(to:)`'s doc
        // comment (a real ZWO camera's 16-bit RAW black/white point carrying over onto this
        // 8-bit RGB24 feed, or vice versa on the next connect, is equally wrong either way).
        stretch = .identity
        channelStretch = .identity
        toneCurves = .identity
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
                await self.ingest(frame)
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
        let engine = CaptureEngine(camera: camera)
        do {
            // `openAndEnumerateControls()` runs entirely on `CaptureEngine`'s actor executor, off
            // `@MainActor` — see its doc comment for why this used to hang the whole app's UI.
            let (caps, initialValues) = try await engine.openAndEnumerateControls()
            var values = initialValues

            // `stretch` and `gpuControls` are plain in-memory session state, not reset on
            // disconnect/reconnect — so whatever a previous webcam/iPhone session (8-bit RGB24,
            // typically indoor/well-lit) last left them at otherwise carries straight over onto a
            // real ZWO sensor's very different (16-bit RAW, often much dimmer/night-sky) signal,
            // rendering as solid white or solid black depending on which side of the leftover
            // black/white point the real data happens to fall on. Reset both to a sane starting
            // point on every fresh ZWO connection — `.identity` only as a placeholder until the
            // first frame arrives and `pendingAutoStretch` replaces it with something that
            // actually shows this camera's real signal (see its doc comment: `.identity` itself
            // renders real 16-bit sensor data as solid black). Gain defaults to whatever the
            // camera's own `ASI_CONTROL_CAPS.DefaultValue` says, which is frequently near the top
            // of its range (tuned by ZWO for bright test conditions) — 5 is a much safer starting
            // point for a real night-sky target than that default.
            stretch = .identity
            channelStretch = .identity
            toneCurves = .identity
            pendingAutoStretch = true
            gpuControls.isEnabled = false
            if let gainCap = caps.first(where: { $0.controlType.rawValue == ASI_GAIN.rawValue }), gainCap.isWritable {
                let gain = min(max(5, gainCap.minValue), gainCap.maxValue)
                try? await engine.setControlValue(ASI_GAIN, value: gain)
                values[gainCap.id] = ZWOControlValue(value: gain, isAuto: false)
            }

            connectedCamera = camera
            controls = caps
            controlValues = values
            captureEngine = engine
            connectionState = .connected
            refreshGainOffsetPresets()
            startDiagnosticsPolling()
            await startPreview(using: engine)
        } catch {
            connectionState = .error(String(describing: error))
            lastErrorMessage = String(describing: error)
        }
    }

    /// One-time fetch (gain/offset presets are a fixed camera-model characteristic, not something
    /// that changes during a session) of ZWO's own recommended gain/offset reference points —
    /// see `gainOffsetPresets`'s doc comment. Direct `ZWOSDK` calls on `@MainActor`, not routed
    /// through `CaptureEngine`'s actor — safe specifically because this runs once, synchronously,
    /// *before* `startPreview` starts the video poll loop (see `connect(to:)`), so there's no
    /// concurrent `ASIGetVideoData` call for the same camera to contend with yet. `refreshDiagnostics`
    /// (`CaptureEngine`) is the cautionary counter-example: an earlier version of *that* repeating
    /// poll made these same direct-`ZWOSDK`-from-`@MainActor` calls every 2 seconds while streaming
    /// was very much active, and blocked the main thread doing it — see its doc comment.
    private func refreshGainOffsetPresets() {
        guard let camera = connectedCamera, camera.cameraID >= 0 else {
            gainOffsetPresets = nil
            lmhGainOffsetPresets = nil
            return
        }
        gainOffsetPresets = try? ZWOSDK.gainOffsetPresets(cameraID: camera.cameraID)
        lmhGainOffsetPresets = try? ZWOSDK.lmhGainOffsetPresets(cameraID: camera.cameraID)
    }

    /// Applies one of ZWO's own recommended gain/offset reference points directly to
    /// `ASI_GAIN`/`ASI_OFFSET` — a one-tap alternative to typing the numbers `gainOffsetPresets`
    /// itself already surfaces into the generic sliders by hand.
    enum GainOffsetPreset {
        /// Gain 0 (dynamic range is always best at the lowest gain — see `ZWOSDK
        /// .GainOffsetPresets.offsetHighestDynamicRange`'s doc comment), at the recommended offset.
        case highestDynamicRange
        /// Offset only — the SDK doesn't report a specific gain value for Unity Gain, so this
        /// deliberately leaves gain untouched rather than guessing at one.
        case unityGain
        case lowestReadNoise
        case lmhLow
        case lmhMiddle
        case lmhHigh
    }

    func applyGainOffsetPreset(_ preset: GainOffsetPreset) {
        switch preset {
        case .highestDynamicRange:
            guard let presets = gainOffsetPresets else { return }
            setControlValue(ASI_GAIN, value: 0)
            setControlValue(ASI_OFFSET, value: presets.offsetHighestDynamicRange)
        case .unityGain:
            guard let presets = gainOffsetPresets else { return }
            setControlValue(ASI_OFFSET, value: presets.offsetUnityGain)
        case .lowestReadNoise:
            guard let presets = gainOffsetPresets else { return }
            setControlValue(ASI_GAIN, value: presets.gainLowestReadNoise)
            setControlValue(ASI_OFFSET, value: presets.offsetLowestReadNoise)
        case .lmhLow:
            guard let lmh = lmhGainOffsetPresets else { return }
            setControlValue(ASI_GAIN, value: lmh.lowGain)
        case .lmhMiddle:
            guard let lmh = lmhGainOffsetPresets else { return }
            setControlValue(ASI_GAIN, value: lmh.middleGain)
        case .lmhHigh:
            guard let lmh = lmhGainOffsetPresets else { return }
            setControlValue(ASI_GAIN, value: lmh.highGain)
            setControlValue(ASI_OFFSET, value: lmh.highOffset)
        }
    }

    /// Periodically re-reads sensor temperature and the dropped-frame count while a ZWO camera is
    /// connected — both are otherwise frozen at whatever they were the moment `connect(to:)` ran.
    /// Direct `ZWOSDK` calls on `@MainActor` (see `refreshGainOffsetPresets`'s doc comment for why
    /// that's fine here); every 2 seconds is plenty for values that only matter as a slow trend,
    /// not a live per-frame readout.
    private func startDiagnosticsPolling() {
        diagnosticsPollTask?.cancel()
        guard let engine = captureEngine, let camera = connectedCamera, camera.cameraID >= 0 else { return }
        diagnosticsPollTask = Task { [weak self, weak engine] in
            while !Task.isCancelled {
                guard let engine else { return }
                let (temperature, dropped) = await engine.refreshDiagnostics()
                await MainActor.run {
                    if let temperature {
                        self?.controlValues[Int32(ASI_TEMPERATURE.rawValue)] = temperature
                    }
                    self?.droppedFrameCount = dropped
                }
                try? await Task.sleep(for: .seconds(2))
            }
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
                await self.ingest(frame)
            }
        }
        do {
            try await engine.startStreaming(imageType: imageType)
            selectedImageType = imageType
            connectionState = .streaming
        } catch {
            // `isLiveViewActive` was optimistically set to `true` above (before we knew
            // `startStreaming` would actually succeed) so `frameConsumerTask`'s `for await` loop
            // could be wired up first — but leaving it `true` on failure hid the "Resume Live
            // View" button (only shown when `!isLiveViewActive`) behind a live view that wasn't
            // actually live, with no way to retry short of disconnecting/reconnecting.
            isLiveViewActive = false
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

    /// What `CaptureEngine.setROI` last actually applied — `nil` means the full sensor. Surfaced
    /// here (rather than only living inside the actor) purely so the UI can show what's currently
    /// active without an `await` round-trip on every render.
    private(set) var captureROIWidth: Int?
    private(set) var captureROIHeight: Int?
    /// Where the ROI is centered, in full-sensor pixel coordinates — `nil` (the default) means
    /// centered on the sensor itself. Only meaningful alongside a non-`nil` `captureROIWidth`/
    /// `captureROIHeight`; reset to `nil` whenever the ROI resets to the full sensor.
    private(set) var captureROICenterX: Int?
    private(set) var captureROICenterY: Int?
    /// The ROI's top-left position the camera actually confirms it applied (`CaptureEngine
    /// .currentStartPosition`, an `ASIGetStartPos` read-back) — `nil` for the full sensor, or if
    /// the read-back itself failed. Distinct from `captureROICenterX/Y` above (what was
    /// *requested*) so a discrepancy — the camera clamping the request somewhere the app didn't
    /// expect — is actually visible instead of just trusted away.
    private(set) var captureROIAppliedStartX: Int?
    private(set) var captureROIAppliedStartY: Int?

    /// Requests a smaller-than-full-sensor capture region — ZWO cameras only (see `CaptureEngine
    /// .setROI`'s doc comment for why this is worth doing at all: a smaller ROI genuinely
    /// increases achievable frame rate, since less data has to be read off the sensor per frame,
    /// the same "small ROI, high FPS" technique real planetary/lunar lucky-imaging workflows
    /// (FireCapture, SharpCap) rely on). `width`/`height` `nil` resets to the full sensor.
    /// `centerX`/`centerY` (full-sensor pixel coordinates) place the ROI anywhere on the sensor —
    /// `nil` means centered on the sensor, which is what every caller except the Controls panel's
    /// own custom-ROI fields uses. Without this, a ROI always landed at the sensor's top-left
    /// corner (`ASISetStartPos` was never called at all) regardless of where the actual target
    /// sat — see `ROIGeometry.startPosition`'s doc comment. No-op for a webcam/iPhone source,
    /// where there's no `ASISetROIFormat` equivalent — frame size there is whatever the selected
    /// `AVCaptureDevice.Format` already is.
    func changeCaptureROI(width: Int?, height: Int?, centerX: Int? = nil, centerY: Int? = nil) {
        guard let engine = captureEngine, connectedCamera != nil else { return }
        frameConsumerTask?.cancel()
        currentFrame = nil
        currentImage = nil
        captureROIWidth = width
        captureROIHeight = height
        captureROICenterX = width != nil ? centerX : nil
        captureROICenterY = height != nil ? centerY : nil
        captureROIAppliedStartX = nil
        captureROIAppliedStartY = nil
        Task {
            await engine.stop()
            await engine.setROI(width: width, height: height, centerX: centerX, centerY: centerY)
            await startPreview(using: engine, imageType: selectedImageType)
            if width != nil, height != nil, let applied = try? await engine.currentStartPosition() {
                captureROIAppliedStartX = applied.x
                captureROIAppliedStartY = applied.y
            }
        }
    }

    // MARK: - ST4 guide port (pulse guiding)

    /// Sends a single ST4 pulse-guide command in `direction` for `durationMilliseconds`, then
    /// turns it back off — ZWO cameras with a real ST4 port wired to a mount only
    /// (`connectedCamera?.hasST4Port`); a no-op otherwise, matching the SDK's own documented
    /// behavior ("this function only work on the module which have ST4 port").
    ///
    /// - Important: **Untested against real guiding hardware.** Wired up faithfully per
    ///   `ASICamera2.h`'s documented usage (`ASIPulseGuideOn` immediately followed, after the
    ///   requested duration, by `ASIPulseGuideOff` for the same direction) — but this project has
    ///   never had an actual ST4 cable/mount available to confirm a real guide correction happens.
    ///   Treat this as plumbing ready for verification, not a proven feature, until confirmed
    ///   against real hardware.
    func pulseGuide(direction: ASI_GUIDE_DIRECTION, durationMilliseconds: Int) {
        guard let camera = connectedCamera, camera.cameraID >= 0, camera.hasST4Port else { return }
        let cameraID = camera.cameraID
        Task { [weak self] in
            do {
                try ZWOSDK.pulseGuideOn(cameraID: cameraID, direction: direction)
                try await Task.sleep(for: .milliseconds(durationMilliseconds))
                try ZWOSDK.pulseGuideOff(cameraID: cameraID, direction: direction)
            } catch {
                await MainActor.run { self?.lastErrorMessage = String(describing: error) }
            }
        }
    }

    /// Which telescope `applyPlanetaryPreset`/`AcquisitionTarget.recommendedPreset()` scale their
    /// starting exposure for — see `PlanetaryPreset.startingExposureSeconds(for:)`. A preference,
    /// not session state (unlike e.g. `polarAlignmentStage`) — the telescope behind the camera
    /// doesn't change between sessions nearly as often as anything else this app tracks, so it's
    /// worth remembering across a relaunch the same way the render path or Focus Assist are.
    var telescopeProfile = AppSettings.telescopeProfile {
        didSet { AppSettings.telescopeProfile = telescopeProfile }
    }

    /// Applies one bright solar-system target's starting ROI/exposure/gain in a single step, and
    /// switches to RAW8 if the camera supports it (the recommended format for this workflow —
    /// undebayered means more frames/second, and color reconstruction is AutoStakkert!3's job,
    /// not something worth paying a live-capture debayer cost for). ZWO cameras only; a no-op for
    /// a webcam/iPhone source, which has none of the ROI/exposure/gain hardware controls this
    /// touches. Doesn't itself set a SER recording duration — `ControlsPanelView` reads
    /// `preset.recommendedMaxDurationSeconds` itself, since recording duration is that view's own
    /// `@AppStorage` state, not `CameraManager`'s.
    ///
    /// Deliberately starts exposure/gain at the *low* end of each preset's recommended range,
    /// not the middle or high end — getting the live histogram into the actual target percentage
    /// still depends on the night's real seeing/transparency, which this can't know in advance,
    /// so starting low and raising while watching the histogram is safer than starting high and
    /// risking a blown-out (clipped) capture from the first frame.
    func applyPlanetaryPreset(_ preset: PlanetaryPreset) {
        guard let camera = connectedCamera, camera.cameraID >= 0 else { return }
        if camera.supportedVideoFormats.contains(ASI_IMG_RAW8) {
            changeImageType(ASI_IMG_RAW8)
        }
        changeCaptureROI(width: preset.roi?.width, height: preset.roi?.height)

        if let exposureCap = controls.first(where: { $0.controlType.rawValue == ASI_EXPOSURE.rawValue }), exposureCap.isWritable {
            let microseconds = Int(preset.startingExposureSeconds(for: telescopeProfile) * 1_000_000)
            setControlValue(ASI_EXPOSURE, value: min(max(microseconds, exposureCap.minValue), exposureCap.maxValue))
        }
        if let gainCap = controls.first(where: { $0.controlType.rawValue == ASI_GAIN.rawValue }), gainCap.isWritable {
            setControlValue(ASI_GAIN, value: min(max(preset.startingGain, gainCap.minValue), gainCap.maxValue))
        }
    }

    // MARK: - Acquisition Wizard

    /// Applies an `AcquisitionPreset` end to end — ROI, gain, exposure, and which of Live
    /// Stack/Reduce Drift/Smart Live Stack are on. ZWO cameras only, same as `applyPlanetaryPreset`
    /// (a webcam/iPhone source has none of the ROI/exposure/gain hardware controls this touches).
    ///
    /// Doesn't itself start a Lucky Imaging burst or SER recording — both stay a deliberate manual
    /// step (framing/focus should be confirmed against the *actual* target first; auto-starting a
    /// burst against whatever happened to be in frame when the wizard closed would often just
    /// waste a burst on an unfocused or unframed capture). `luckyBurstCount`/`serDurationSeconds`
    /// are recommendations the wizard UI surfaces for those manual steps, not applied here.
    /// Applies to a webcam/iPhone source too, not just ZWO — `changeImageType`/`changeCaptureROI`/
    /// `setControlValue`'s own ROI/gain/exposure hardware calls all already no-op gracefully for
    /// one (no `captureEngine`, no `ASI_CONTROL_CAPS` in `controls` to match against), so the only
    /// thing that actually needed relaxing was this method's own guard, which used to require a
    /// real ZWO camera outright. What *does* apply to a webcam/iPhone source: `mode` (Live Stack
    /// and/or Lucky Imaging both already work for RGB24 — see `LiveStacker`/`SharpnessScorer`'s
    /// own RGB24 cases) and Smart Live Stack (its GPU sharpness gate can't score an RGB24 frame,
    /// so it just never rejects one — harmless, not broken). Reduce Drift is the one setting that
    /// gets set but produces no visible difference on that source, since the GPU drift-reduction
    /// accumulator is mono-only; `AcquisitionWizardView` notes this explicitly when a webcam is
    /// the connected source, rather than silently implying it does something it doesn't.
    func applyAcquisitionPreset(_ preset: AcquisitionPreset) {
        guard let camera = connectedCamera else { return }
        if camera.cameraID >= 0 {
            if camera.supportedVideoFormats.contains(ASI_IMG_RAW8) {
                changeImageType(ASI_IMG_RAW8)
            }
            changeCaptureROI(width: preset.roiWidth, height: preset.roiHeight)

            if let exposureSeconds = preset.exposureSeconds,
               let exposureCap = controls.first(where: { $0.controlType.rawValue == ASI_EXPOSURE.rawValue }), exposureCap.isWritable {
                let microseconds = Int(exposureSeconds * 1_000_000)
                setControlValue(ASI_EXPOSURE, value: min(max(microseconds, exposureCap.minValue), exposureCap.maxValue))
            }
            if let gain = preset.gain,
               let gainCap = controls.first(where: { $0.controlType.rawValue == ASI_GAIN.rawValue }), gainCap.isWritable {
                setControlValue(ASI_GAIN, value: min(max(gain, gainCap.minValue), gainCap.maxValue))
            }
        }

        isLiveStackingEnabled = preset.mode.usesLiveStack
        if preset.mode.usesLiveStack {
            isLiveStackDriftReductionEnabled = preset.isDriftReductionEnabled
            isSmartLiveStackEnabled = preset.isSmartLiveStackEnabled
            // `?? false` covers a preset file saved before this field existed — an older preset
            // simply never turned this "Experimental" feature on, same reasoning as any other
            // newly-added optional preset field.
            isMeshDriftCorrectionEnabled = preset.isMeshDriftCorrectionEnabled ?? false
        }
    }

    /// Writes `preset` as its own JSON file — one file per preset, via a save panel, matching
    /// `exportCurrentFrame`'s own panel-then-write shape.
    func saveAcquisitionPreset(_ preset: AcquisitionPreset) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(preset.name).acquisitionpreset.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try JSONEncoder().encode(preset)
                try data.write(to: url, options: .atomic)
            } catch {
                Task { @MainActor in self?.lastErrorMessage = String(describing: error) }
            }
        }
    }

    /// Reads a previously-saved preset back via an open panel — `onLoad` receives it (and the
    /// `AcquisitionTarget` it resolves to, `nil` if `targetID` doesn't match anything this build
    /// knows about) so the wizard view can populate its own state; failures surface through
    /// `lastErrorMessage` the same way every other file operation here does, rather than a second,
    /// separate error-reporting path just for this one feature.
    func loadAcquisitionPreset(onLoad: @escaping (AcquisitionPreset, AcquisitionTarget?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let preset = try JSONDecoder().decode(AcquisitionPreset.self, from: data)
                Task { @MainActor in onLoad(preset, AcquisitionTarget.resolve(id: preset.targetID)) }
            } catch {
                Task { @MainActor in self?.lastErrorMessage = String(describing: error) }
            }
        }
    }

    /// A snapshot of *whatever's currently configured* as an `AcquisitionPreset` — not a target's
    /// recommendation, so this works without ever having opened the Wizard at all. `targetID` is
    /// left empty (matches nothing `AcquisitionTarget.resolve(id:)` can find), since there's no
    /// single target this snapshot is "for" — it's just today's actual live settings.
    /// `luckyBurstCount`/`serDurationSeconds` are `nil`: both live as `@AppStorage` inside
    /// `ControlsPanelView`, not here, so a preset saved this way doesn't carry a recommendation
    /// for either — loading it back still restores everything this class itself tracks.
    func currentAcquisitionPreset(name: String) -> AcquisitionPreset {
        let gain = controls.first { $0.controlType.rawValue == ASI_GAIN.rawValue }
            .flatMap { controlValues[$0.id]?.value }
        let exposureMicroseconds = controls.first { $0.controlType.rawValue == ASI_EXPOSURE.rawValue }
            .flatMap { controlValues[$0.id]?.value }
        let mode = AcquisitionMode.current(
            isLiveStackingEnabled: isLiveStackingEnabled, hasLuckyImagingSession: luckyImagingSession != nil
        )
        return AcquisitionPreset(
            name: name,
            targetID: "",
            mode: mode,
            gain: gain,
            exposureSeconds: exposureMicroseconds.map { Double($0) / 1_000_000 },
            roiWidth: captureROIWidth,
            roiHeight: captureROIHeight,
            isDriftReductionEnabled: isLiveStackDriftReductionEnabled,
            isSmartLiveStackEnabled: isSmartLiveStackEnabled,
            luckyBurstCount: nil,
            serDurationSeconds: nil
        )
    }

    /// Saves whatever's currently configured, without needing the Wizard sheet open at all — the
    /// save panel itself is where the user actually names it (pre-filled from `name` below, but
    /// freely editable, same as `saveAcquisitionPreset`'s own file-naming already works).
    func saveCurrentSetupAsPreset() {
        saveAcquisitionPreset(currentAcquisitionPreset(name: "Custom Setup"))
    }

    /// Loads a preset and applies it immediately — the quick path for "I already know which
    /// preset I want," without the Wizard's own review-then-Apply step in between.
    func loadAndApplyAcquisitionPreset() {
        loadAcquisitionPreset { [weak self] preset, _ in
            self?.applyAcquisitionPreset(preset)
        }
    }

    /// Undoes every Wizard/preset/manual adjustment in one action — full sensor ROI, a safe
    /// starting gain (matching `connect(to:)`'s own "5 is a much safer starting point for a real
    /// night-sky target than the camera's own default" reasoning), and every capture-affecting
    /// toggle (Live Stack, Smart Live Stack, Reduce Drift, Lucky Imaging, Dark/Flat correction,
    /// Planetary tracking/crop, Image Enhancement, the AI Suite, any active recording) back off.
    /// Applies to a webcam/iPhone source too, same as `applyAcquisitionPreset` — the ROI/gain/
    /// exposure calls already no-op gracefully for one (no `captureEngine`, no `controls` to
    /// match against), and every toggle below is genuinely meaningful there regardless.
    func resetToDefaultConfiguration() {
        guard connectedCamera != nil else { return }
        changeCaptureROI(width: nil, height: nil)
        if let gainCap = controls.first(where: { $0.controlType.rawValue == ASI_GAIN.rawValue }), gainCap.isWritable {
            setControlValue(ASI_GAIN, value: min(max(5, gainCap.minValue), gainCap.maxValue))
        }
        if let exposureCap = controls.first(where: { $0.controlType.rawValue == ASI_EXPOSURE.rawValue }), exposureCap.isWritable {
            setControlValue(ASI_EXPOSURE, value: exposureCap.defaultValue)
        }

        isLiveStackingEnabled = false // also clears isSmartLiveStackEnabled via its own didSet
        isLiveStackDriftReductionEnabled = false
        discardLuckyImagingSession()
        isDarkSubtractionEnabled = false
        isFlatCorrectionEnabled = false
        isFocusAssistEnabled = false
        isPlanetaryTrackingEnabled = false
        isPlanetaryCropEnabled = false
        isDenoisingEnabled = false
        isWaveletSharpeningEnabled = false
        gpuControls.isEnabled = false
        isStreakMaskingEnabled = false
        isCloudSentinelEnabled = false
        if isRecordingToDisk { stopRecording() }
        if isRecordingSERVideo { stopSERRecording() }

        stretch = .identity
        channelStretch = .identity
        toneCurves = .identity
        pendingAutoStretch = true
    }

    /// The single place a freshly-captured raw frame (real camera or webcam) enters the
    /// display pipeline: dark subtraction, then lucky-imaging burst collection, then live
    /// stacking — all operating on raw sensor data, before `refreshCurrentImage` debayers and
    /// stretches whatever `currentFrame` ends up being for on-screen display.
    private func ingest(_ rawFrame: CapturedFrame) async {
        var processed = await applyDarkSubtraction(rawFrame)

        if pendingAutoStretch {
            pendingAutoStretch = false
            if let auto = DisplayStretch.autoStretch(histogram: HistogramComputer.histogram(for: processed)) {
                stretch = auto
            }
        }

        // Unconditional — independent of the user's own Live Stack toggle, see
        // `startIPhoneNightModeCapture`'s doc comment.
        nightModeAccumulator?.add(processed)

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
        recordSERFrameIfNeeded(processed)

        if let camera = connectedCamera, let session = luckyImagingSession, !session.isComplete, !isLuckyImagingPaused {
            session.add(processed, isColorCamera: camera.isColorCamera, bayerPattern: camera.bayerPattern)
        }
        scheduleQualityScoreIfNeeded(processed)
        scheduleCloudSentinelIfNeeded(processed)
        updateSmartLiveStackGate(processed)

        // GPU live-stack accumulation (`MetalFrameRenderer.accumulationTexture`) is mono-only —
        // it never runs for RGB24 (webcam/iPhone) frames, see `MetalFrameRenderer.process`'s doc
        // comment. Without this, enabling Live Stack for an iPhone/webcam source while the GPU
        // render path was active (the default) did nothing at all: no CPU accumulation because
        // `useMetalRenderer` was true, no GPU accumulation because RGB24 isn't supported there —
        // `currentFrame` just stayed the latest raw frame every time. Falling back to the CPU
        // `LiveStacker` specifically for RGB24 regardless of the render-path toggle fixes both the
        // live preview (GPU still does its own stretch/denoise/sharpen of this already-averaged
        // frame each time, via `processRGB24`) and export (`frameForExport` falls through to
        // `currentFrame` once `gpuAccumulatedFrameProvider` comes back `nil` for RGB24).
        let usesCPUStack = isLiveStackingEnabled && (!useMetalRenderer || processed.imageType == ASI_IMG_RGB24)
        if usesCPUStack {
            // Paused (manually, or Smart Live Stack quality-gating this one out — see
            // `effectiveLiveStackPaused`'s doc comment): skip folding this frame in, but still
            // display whatever `liveStacker` already has — a frozen, not reset, stack.
            if !effectiveLiveStackPaused {
                // Streak masking (see `currentStreakMask`'s doc comment) only applies here — it's a
                // CPU-`LiveStacker`-only feature, disclosed as such in the Controls UI.
                let mask = isStreakMaskingEnabled ? currentStreakMask : nil
                let maskToApply = (mask?.width == processed.width && mask?.height == processed.height) ? mask : nil
                liveStacker.add(processed, mask: maskToApply)
            }
            currentFrame = liveStacker.currentAverage() ?? processed
        } else {
            currentFrame = processed
        }

        // Rate-limits the *visible* refresh (this is what drives `MetalPreviewView`'s per-frame
        // Metal dispatch via `frameID`, and `refreshCurrentImage`'s CPU-path CGImage render) —
        // not the underlying capture rate itself. Everything above this point (dark subtraction,
        // `recordIfNeeded`/`recordSERFrameIfNeeded`, Lucky Imaging, CPU `LiveStacker` accumulation)
        // already ran for *this* real frame and stays fully lossless regardless.
        //
        // Without this, a small Capture ROI (real cameras can comfortably exceed 100-200fps at,
        // say, 400×400) fed every single incoming frame straight into a full display refresh —
        // `frameID` bump, GPU dispatch, SwiftUI observation — with no throttle at all. At that
        // rate the previous frame's display work often hadn't finished before the next one
        // arrived, so frames piled up waiting their turn on `@MainActor`; the visible result was
        // exactly "slows down a lot and flickers" — a growing backlog of stale frames being drawn
        // in bursts, not a live view. Capping the *display* refresh to ~30fps (already far more
        // than a human eye needs from a preview, and unrelated to the camera's own real frame
        // rate) keeps that backlog from ever building up, regardless of how small the ROI is.
        let now = Date()
        if let lastDisplayRefreshDate, now.timeIntervalSince(lastDisplayRefreshDate) < Self.minimumDisplayRefreshInterval {
            return
        }
        lastDisplayRefreshDate = now
        frameID &+= 1
        refreshCurrentImage()
    }

    /// ~30fps — see the doc comment where this is used in `ingest` for why a live *preview*
    /// refresh rate is capped independently of the camera's own real capture rate.
    private static let minimumDisplayRefreshInterval: TimeInterval = 1.0 / 30.0
    private var lastDisplayRefreshDate: Date?

    // MARK: - AI Suite: quality score, cloud sentinel, streak masking

    private var qualityScoreFrameCounter = 0
    private var maxObservedSharpness = 0.0

    /// Throttled to every 5th frame — `SharpnessScorer` does a real per-pixel Laplacian-variance
    /// pass (debayering color frames first), the same cost `LuckyImagingSession.add` already pays
    /// during an active burst; running it on *every* frame just for a live readout even when no
    /// burst is active would double that cost for everyone, for a number that only needs to
    /// update a few times a second to read as "live".
    ///
    /// - Important: This ran *inline*, synchronously, directly on `@MainActor` in its first
    ///   version — unlike every other per-frame AI Suite feature here, it has no enable/disable
    ///   toggle gating it, so it was unconditionally scoring every 5th frame of a *real* ZWO
    ///   camera's (much higher-resolution, higher-frame-rate than the webcam this was mostly
    ///   tested against) live feed on the main thread, stuttering the whole UI. Moved to
    ///   `Task.detached`, matching `enhancementTask`'s existing fix shape for the same mistake.
    private func scheduleQualityScoreIfNeeded(_ frame: CapturedFrame) {
        guard let camera = connectedCamera, qualityScoreTask == nil else { return }
        qualityScoreFrameCounter += 1
        guard qualityScoreFrameCounter % 5 == 0 else { return }
        qualityScoreTask = Task.detached(priority: .utility) { [weak self] in
            let raw = SharpnessScorer.score(for: frame, isColorCamera: camera.isColorCamera, bayerPattern: camera.bayerPattern)
            await self?.applyQualityScore(raw)
        }
    }

    /// A plain `@MainActor` method (inherited from the class itself) called via `await self?
    /// .method(...)` from inside `scheduleQualityScoreIfNeeded`'s detached task, rather than a
    /// nested `await MainActor.run { ... }` closure — the latter makes Swift 6's strict
    /// concurrency checker flag "sending 'self' risks causing data races" on some toolchains
    /// (confirmed on Xcode 16.4/CI, not reproduced on the newer Xcode used for local development)
    /// even though the underlying access pattern (a `weak self` captured once, resolved once,
    /// touched only on the actor it's isolated to) is safe; calling an isolated method directly
    /// avoids the diagnostic entirely instead of arguing with it. Applies to every other
    /// `Task.detached` in this file with the same shape, not just this one.
    private func applyQualityScore(_ raw: Double) {
        // Laplacian variance has no fixed theoretical ceiling, so "out of 100" here is relative
        // to the sharpest frame *this session has actually seen* — a genuinely meaningful "how
        // good is this frame compared to the best seeing we've had" readout, not a fabricated
        // absolute scale. Matches the spirit of Lucky Imaging itself: relative ranking, not
        // calibrated units.
        maxObservedSharpness = max(maxObservedSharpness, raw)
        currentFrameQualityScore = maxObservedSharpness > 0 ? min(raw / maxObservedSharpness * 100, 100) : 0
        qualityScoreTask = nil
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
    /// `scheduleFocusAssistIfNeeded`) — called from `refreshCurrentImage()`, not `ingest()`
    /// directly, just to key off the same "a new frame arrived" signal; it renders its own
    /// CGImage from the raw frame inside the detached task below rather than depending on
    /// `currentImage` having already been rendered synchronously for it (see
    /// `refreshCurrentImage`'s doc comment for why that used to matter and doesn't anymore).
    private func scheduleStreakDetectionIfNeeded() {
        guard isStreakMaskingEnabled, isLiveStackingEnabled, streakDetectionTask == nil,
              let frame = currentFrame, let camera = connectedCamera
        else { return }
        let width = frame.width
        let height = frame.height
        let isColorCamera = camera.isColorCamera
        let bayerPattern = camera.bayerPattern
        let currentStretch = stretch
        let gpuRenderer = gpuStillImageRenderer
        // Same `Task` (inherits `@MainActor`) -> `Task.detached` fix as `scheduleFocusAssistIfNeeded`.
        streakDetectionTask = Task.detached(priority: .utility) { [weak self] in
            let gpuImage = await gpuRenderer?.makeDisplayImage(
                from: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: currentStretch
            )
            guard let image = gpuImage ?? CGImageRenderer.makeDisplayImage(
                from: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: currentStretch
            ) else {
                await self?.clearStreakDetectionTask()
                return
            }
            let streaks = (try? StreakDetector.detectStreaks(in: image)) ?? []
            try? await Task.sleep(for: .milliseconds(250)) // simple rate limit, mirrors focus assist
            await self?.applyStreakDetection(width: width, height: height, streaks: streaks)
        }
    }

    private func clearStreakDetectionTask() {
        streakDetectionTask = nil
    }

    private func applyStreakDetection(width: Int, height: Int, streaks: [DetectedStreak]) {
        currentStreakMask = StreakMask(width: width, height: height, streaks: streaks)
        streakDetectionTask = nil
    }

    /// Applies whichever of dark subtraction / flat correction are enabled and have an active
    /// calibration frame — dark first (removes fixed-pattern noise/hot pixels), then flat
    /// (corrects vignetting/dust shadows), matching the standard real-world calibration order.
    ///
    /// Prefers `GPUFrameCalibrator` (one combined GPU dispatch) over the CPU
    /// `FrameArithmetic`/`FlatFieldCorrector` scalar loops when the Metal renderer is enabled —
    /// see that type's doc comment for why the result still comes back as CPU-resident `Data`
    /// either way (planetary tracking, lucky imaging, and FITS recording all need the calibrated
    /// frame on the CPU side, not just the live preview, so this can't just stay GPU-resident the
    /// way debayer/stretch does). Falls back to the CPU path if GPU calibration isn't available
    /// or declines the frame (dimension/type mismatch, no Metal device).
    private func applyDarkSubtraction(_ frame: CapturedFrame) async -> CapturedFrame {
        let dark = isDarkSubtractionEnabled ? darkFrame : nil
        let activeFlat = isFlatCorrectionEnabled ? calibrationLibrary.activeFlat : nil
        guard dark != nil || activeFlat != nil else { return frame }

        if useMetalRenderer, let gpuCalibrator = gpuFrameCalibrator,
           let calibrated = await gpuCalibrator.calibrate(
               light: frame, dark: dark, flat: activeFlat?.frame, flatMean: activeFlat?.meanBrightness
           ) {
            return calibrated
        }

        var result = frame
        if let dark, let subtracted = FrameArithmetic.subtract(light: result, dark: dark) {
            result = subtracted
        }
        if let activeFlat, let corrected = FlatFieldCorrector.correct(
            light: result, flat: activeFlat.frame, precomputedFlatMean: activeFlat.meanBrightness
        ) {
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
        capturingExposureStartDate = Date()
        capturingExposureDurationSeconds = seconds
        lastErrorMessage = nil
        defer {
            isCapturingExposure = false
            capturingExposureStartDate = nil
            capturingExposureDurationSeconds = nil
        }

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
        capturingExposureStartDate = Date()
        capturingExposureDurationSeconds = seconds
        lastErrorMessage = nil
        defer {
            isCapturingExposure = false
            capturingExposureStartDate = nil
            capturingExposureDurationSeconds = nil
        }

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

    /// "Clear All" for the Dark Frames list — `calibrationSubsection`'s per-frame trash button
    /// already covers removing one at a time; this is the bulk equivalent, next to it.
    func clearDarkFrame() {
        calibrationLibrary.darkFrames.forEach { calibrationLibrary.removeDark(id: $0.id) }
        isDarkSubtractionEnabled = false
    }

    /// "Clear All" for the Flat Frames list — see `clearDarkFrame`'s doc comment.
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
        isLuckyImagingPaused = false
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
        isLuckyImagingPaused = false
    }

    /// Shows one specific captured frame from the current burst (by its rank when sorted
    /// sharpest first, matching `LuckyImagingFrameBrowserView`'s own list order) as
    /// `currentFrame`, for inspecting or saving it directly instead of only ever seeing
    /// `stackLuckyImagingBest`'s averaged result. Doesn't end or otherwise change the burst
    /// itself — it keeps capturing new frames in the background if it isn't complete yet.
    func showLuckyImagingFrame(atSortedIndex index: Int) {
        guard let session = luckyImagingSession else { return }
        let sorted = session.framesSortedByScore
        guard sorted.indices.contains(index) else { return }
        currentFrame = sorted[index].frame
        frameID &+= 1
        refreshCurrentImage()
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
                guard let frame = frameForExport() else { return }
                try FITSWriter.write(
                    frame: frame, instrumentName: connectedCamera?.name ?? "skyformac",
                    isColorCamera: connectedCamera?.isColorCamera ?? false, bayerPattern: connectedCamera?.bayerPattern ?? ASI_BAYER_RG,
                    to: url
                )
                recordExport(url: url, kind: .fits)
            case .png:
                guard let image = imageForExport() else { return }
                try ImageExporter.writePNG(image, to: url)
                recordExport(url: url, kind: .png)
            case .tiff:
                guard let image = imageForExport() else { return }
                try ImageExporter.writeTIFF(image, to: url)
                recordExport(url: url, kind: .tiff)
            }
        } catch {
            lastErrorMessage = String(describing: error)
        }
    }

    /// The frame `exportCurrentFrame` should actually write out — the GPU live-stack accumulator's
    /// current average when one is active and reachable, otherwise whatever `currentFrame`
    /// already is (a plain single frame, or the CPU `LiveStacker`'s own average when Live Stack
    /// is on and the CPU render path is active — `currentFrame` already holds *that* correctly,
    /// see `ingest`). This is the fix for exporting "the current frame" while GPU Live Stack was
    /// running previously exporting a raw single frame instead of the stack — see
    /// `MetalFrameRenderer.currentAccumulatedFrame`'s doc comment for exactly why that gap existed.
    private func frameForExport() -> CapturedFrame? {
        if useMetalRenderer, isLiveStackingEnabled,
           let stacked = gpuAccumulatedFrameProvider?(selectedImageType) {
            return stacked
        }
        return currentFrame
    }

    /// `imageForExport`'s frame source (`frameForExport()`) debayered/stretched for PNG/TIFF —
    /// deliberately a fresh on-demand render rather than reusing `currentImage` (which, even
    /// when non-`nil`, reflects whatever `currentFrame` was at the time it was last computed, not
    /// necessarily the GPU stack `frameForExport()` may now be substituting in instead).
    private func imageForExport() -> CGImage? {
        guard let frame = frameForExport(), let camera = connectedCamera else { return currentDisplayImage() }
        return renderedCurrentImage(frame: frame, camera: camera)
    }

    // MARK: - Exported Files: history + opening a file back up for viewing

    private(set) var exportHistory: [ExportHistoryEntry] = AppSettings.exportHistory

    private func recordExport(url: URL, kind: ExportHistoryEntry.Kind) {
        exportHistory.append(ExportHistoryEntry(url: url, kind: kind))
        AppSettings.exportHistory = exportHistory
    }

    func clearExportHistory() {
        exportHistory = []
        AppSettings.exportHistory = []
    }

    /// What `ExportedFileViewerView` actually displays — a raw FITS frame (still needs this
    /// app's own debayer/stretch pipeline to become a picture) vs. an already-displayable
    /// PNG/TIFF, vs. a reason opening it failed.
    enum ExportedFileContent {
        case rawFrame(FITSReader.ParsedFITS, sourceURL: URL)
        case image(NSImage, sourceURL: URL)
        case error(String)
    }

    var viewingExportedFile: ExportedFileContent?

    /// Opens a FITS/PNG/TIFF file — one just exported this session, one from `exportHistory`
    /// (which can span previous sessions), or any arbitrary file the user picks via "Open File…"
    /// — for in-app viewing (`ExportedFileViewerView`). `.ser` and other formats aren't something
    /// this app's own viewer can render (see `ExportHistoryEntry.Kind.isViewableInApp`'s doc
    /// comment for why that's a deliberate scope line, not a missing feature) — callers should
    /// check that first and offer "Reveal in Finder"/"Open with default app" instead.
    func openExportedFile(_ url: URL) {
        let extensionLowercased = url.pathExtension.lowercased()
        switch extensionLowercased {
        case "fits", "fit":
            do {
                let parsed = try FITSReader.read(from: url)
                viewingExportedFile = .rawFrame(parsed, sourceURL: url)
            } catch {
                viewingExportedFile = .error(String(describing: error))
            }
        case "png", "tif", "tiff", "jpg", "jpeg":
            if let image = NSImage(contentsOf: url) {
                viewingExportedFile = .image(image, sourceURL: url)
            } else {
                viewingExportedFile = .error("Couldn't load image data from \"\(url.lastPathComponent)\".")
            }
        default:
            viewingExportedFile = .error("skyformac can only view FITS, PNG, TIFF, and JPEG files directly — \"\(url.lastPathComponent)\" needs another tool (Reveal in Finder, then open it with whatever handles that format).")
        }
    }

    private func refreshCurrentImage() {
        guard let frame = currentFrame, let camera = connectedCamera else { return }
        // On the Metal path, `PreviewView` shows `MetalPreviewView` and never reads
        // `currentImage` at all — so this synchronous render is only actually needed for the CPU
        // display path. It used to *also* run whenever Focus Assist (hence Recognize Stars) or
        // streak detection was on, regardless of the GPU/CPU toggle, to have a CGImage ready for
        // their Vision requests — a full CPU debayer+stretch pass, synchronously, on
        // `@MainActor`, every single incoming frame. That unconditional per-frame cost was the
        // actual cause of "the app isn't responsive when Recognize Stars is on": both of those
        // features now render their own CGImage inside their own background task instead (see
        // `scheduleFocusAssistIfNeeded`/`scheduleStreakDetectionIfNeeded`), the same way
        // `schedulePlanetTrackingIfNeeded` already did. Export and polar alignment (rare,
        // user-initiated actions) still render on demand via `currentDisplayImage()`'s fallback.
        if !useMetalRenderer {
            currentImage = renderedCurrentImage(frame: frame, camera: camera)
        }
        scheduleFocusAssistIfNeeded()
        scheduleCPUEnhancementIfNeeded(frame: frame, camera: camera)
        if isStreakMaskingEnabled && isLiveStackingEnabled {
            scheduleStreakDetectionIfNeeded()
        }
    }

    private func renderedCurrentImage(frame: CapturedFrame, camera: ZWOCameraInfo) -> CGImage? {
        CGImageRenderer.makeDisplayImage(
            from: frame,
            isColorCamera: camera.isColorCamera,
            bayerPattern: camera.bayerPattern,
            stretch: stretch,
            channelStretch: effectiveChannelStretch,
            toneCurves: isToneCurveEnabled ? toneCurves : nil
        )
    }

    /// `currentImage` is already fresh in CPU mode. In GPU mode it's `nil` (Focus Assist/streak
    /// detection each render their own CGImage in their own background task now, rather than
    /// keeping this one around — see `refreshCurrentImage`'s doc comment), so this always falls
    /// through to a fresh on-demand render there — fine for the rare, user-initiated actions
    /// (export, polar alignment) that call this, unlike doing the same render every frame.
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
        let currentChannelStretch = effectiveChannelStretch
        let currentToneCurves = isToneCurveEnabled ? toneCurves : nil
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
                from: displayFrame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: currentStretch,
                channelStretch: currentChannelStretch, toneCurves: currentToneCurves
            )
            await self?.applyEnhancedImage(image, ifStillOnFrame: frameIDAtSchedule)
        }
    }

    private func applyEnhancedImage(_ image: CGImage?, ifStillOnFrame frameIDAtSchedule: UInt64) {
        // Only apply if a newer frame hasn't already arrived — otherwise this stale, slow-to-
        // compute enhanced image would visibly replace a fresher plain one.
        if frameID == frameIDAtSchedule, let image {
            currentImage = image
        }
        enhancementTask = nil
    }

    /// Runs `PlanetDetector` (Vision contours, biggest-blob selection) at a throttled rate and
    /// feeds the result through `PlanetTracker`'s smoothing. Takes the full, uncropped frame
    /// explicitly (see `ingest`) rather than reading `currentImage`/`currentFrame`, which may
    /// already be cropped to the previous ROI.
    private func schedulePlanetTrackingIfNeeded(fullFrame: CapturedFrame) {
        guard isPlanetaryTrackingEnabled, planetTrackingTask == nil, let camera = connectedCamera else { return }
        let isColorCamera = camera.isColorCamera
        let bayerPattern = camera.bayerPattern
        let currentStretch = stretch

        // Both the debayer/stretch render (real CPU work over the full frame) and
        // `PlanetDetector`'s Vision contour pass used to run synchronously on `@MainActor` — the
        // render happened inline before this function even got to `Task { }`, and that `Task`
        // wasn't `.detached`, so it inherited `@MainActor` too. Same mistake as
        // `scheduleFocusAssistIfNeeded`; both the render and the detection now happen inside the
        // detached task, off the main thread entirely.
        planetTrackingTask = Task.detached(priority: .utility) { [weak self] in
            guard let image = CGImageRenderer.makeDisplayImage(
                from: fullFrame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: currentStretch
            ) else {
                await self?.clearPlanetTrackingTask()
                return
            }
            let detection = try? PlanetDetector.detectDisk(in: image)
            try? await Task.sleep(for: .milliseconds(200))
            await self?.applyPlanetTracking(detection: detection ?? nil)
        }
    }

    private func clearPlanetTrackingTask() {
        planetTrackingTask = nil
    }

    private func applyPlanetTracking(detection: CGRect?) {
        planetROI = planetTracker.update(with: detection)
        planetTrackingTask = nil
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
        guard isFocusAssistEnabled, focusAssistTask == nil,
              let frame = currentFrame, let camera = connectedCamera
        else { return }
        let width = frame.width
        let height = frame.height
        let recognizeStars = isStarRecognitionEnabled
        let isColorCamera = camera.isColorCamera
        let bayerPattern = camera.bayerPattern
        let currentStretch = stretch
        let gpuRenderer = gpuStillImageRenderer
        // `Task { }` (not `.detached`) inherits the caller's actor — since this is `@MainActor`
        // code, that meant `StarDetector.detectStars` (a real, potentially slow Vision contour
        // pass) ran synchronously on the main thread inside what looked like a background task,
        // same mistake `enhancementTask`'s doc comment already documents fixing elsewhere. Also
        // renders its own CGImage from the raw frame here (rather than reading the `currentImage`
        // a caller used to render synchronously just for this) — see `refreshCurrentImage`'s doc
        // comment for why that was actually the main-thread-blocking part. Prefers the GPU
        // (`GPUStillImageRenderer`) over the CPU `CGImageRenderer` for this render — see that
        // type's doc comment for why the debayer+stretch itself is worth moving to Metal.
        focusAssistTask = Task.detached(priority: .utility) { [weak self] in
            let gpuImage = await gpuRenderer?.makeDisplayImage(
                from: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: currentStretch
            )
            guard let image = gpuImage ?? CGImageRenderer.makeDisplayImage(
                from: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: currentStretch
            ) else {
                await self?.clearFocusAssistTask()
                return
            }
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
            await self?.applyFocusAssist(result: result, matches: matches, wcs: wcs, hfd: hfd)
        }
    }

    private func clearFocusAssistTask() {
        focusAssistTask = nil
    }

    private func applyFocusAssist(
        result: FocusAssistResult?, matches: [StarPatternRecognizer.Match], wcs: WCSFrame?, hfd: Double?
    ) {
        focusAssist = result
        recognizedObjects = matches
        liveWCS = wcs
        focusAssistTask = nil
        if let hfd {
            focusTracker.record(medianHFD: hfd, at: Date())
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
        capturingExposureStartDate = Date()
        capturingExposureDurationSeconds = seconds
        lastErrorMessage = nil

        defer {
            isCapturingExposure = false
            capturingExposureStartDate = nil
            capturingExposureDurationSeconds = nil
        }

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
            currentFrame = await applyDarkSubtraction(frame)
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
        captureROIWidth = nil
        captureROIHeight = nil
        captureROICenterX = nil
        captureROICenterY = nil
        captureROIAppliedStartX = nil
        captureROIAppliedStartY = nil
        diagnosticsPollTask?.cancel()
        diagnosticsPollTask = nil
        droppedFrameCount = nil
        gainOffsetPresets = nil
        lmhGainOffsetPresets = nil
        if isRecordingSERVideo { stopSERRecording() }
        cancelIPhoneNightModeCapture()
        isWebcamFocusLocked = false
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
        gpuChannelHistogramCounts = nil
        meshDriftVisualization = nil
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
        isLiveStackPaused = false
        isSmartLiveStackEnabled = false
        smartStackKeptCount = 0
        smartStackRejectedCount = 0
        smartStackLastRejectionReason = nil
        smartStackMaxObservedScore = 0
        luckyImagingSession = nil
        focusTracker.reset()
        isRecordingToDisk = false
        resetPolarAlignment()
        cloudSentinel.reset()
        isCloudAlertActive = false
        streakDetectionTask?.cancel()
        streakDetectionTask = nil
        currentStreakMask = nil
        qualityScoreTask?.cancel()
        qualityScoreTask = nil
        currentFrameQualityScore = nil
        maxObservedSharpness = 0
        // Deliberately NOT clearing darkFrame/isDarkSubtractionEnabled — a captured dark frame
        // is reusable across a reconnect of the same camera/settings.
        if connectedCamera?.cameraID ?? -1 >= 0 {
            let engine = captureEngine
            Task {
                await engine?.stop()
                await engine?.close()
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
        diagnosticsPollTask?.cancel()
        diagnosticsPollTask = nil
        droppedFrameCount = nil
        gainOffsetPresets = nil
        lmhGainOffsetPresets = nil
        refreshCameraList()
    }
}
