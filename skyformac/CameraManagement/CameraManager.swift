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
    /// Every non-`nil` assignment also logs to `AppLog` — since this is already the one property
    /// nearly every failure path in this class sets, that single hook captures most real errors
    /// for the log viewer for free, without instrumenting every individual call site.
    private(set) var lastErrorMessage: String? {
        didSet {
            if let lastErrorMessage {
                AppLog.shared.log("Error: \(lastErrorMessage)")
            }
        }
    }
    /// Clears whatever `lastErrorMessage` currently holds — the Camera Error alert's "OK" button
    /// calls this so a dismissed alert actually stays dismissed. Without it, the next unrelated
    /// re-render of `ContentView` would find `lastErrorMessage` still non-`nil` and show the exact
    /// same alert again.
    func dismissError() {
        lastErrorMessage = nil
    }

    var isLogViewerPresented = false
    var isRecallParametersPresented = false
    var isSettingsPresented = false

    // MARK: - Sidebar assistant

    /// Shown by default — "a chat on the right bar of all pages," not something buried behind a
    /// menu item the user has to discover first. `RootView` reads this (alongside `isAssistant
    /// Minimized`/`isAssistantDetached`) to decide whether/how to show `AssistantChatPanel`.
    ///
    /// The `didSet` re-forces `isAssistantDetached = true` when the panel becomes visible again
    /// while a camera session is active — `syncAssistantDockStateForCameraMode()` only forces
    /// that on the `activeSession` nil↔non-nil *transition*, so closing the detached panel during
    /// camera mode (which resets `isAssistantDetached` to `false` via the floating window's own
    /// `windowWillClose` callback — see `RootView`) and then reopening it from the menu bar's own
    /// "AI" toggle, still in camera mode, left neither the embedded-sidebar condition nor the
    /// detached-panel condition true — the panel silently failed to reappear at all.
    var isAssistantPanelVisible = AppSettings.isAssistantPanelVisible {
        didSet {
            AppSettings.isAssistantPanelVisible = isAssistantPanelVisible
            guard isAssistantPanelVisible, !oldValue, activeSession != nil else { return }
            isAssistantDetached = true
        }
    }
    var isAssistantMinimized = AppSettings.isAssistantMinimized {
        didSet { AppSettings.isAssistantMinimized = isAssistantMinimized }
    }
    /// When `true`, `RootView` hosts the panel in a floating `AssistantChatPanelController`
    /// (an `NSPanel`, the same "detach" mechanism `HistogramCurvesPanelController` already uses)
    /// instead of embedding it in the main window.
    var isAssistantDetached = AppSettings.isAssistantDetached {
        didSet { AppSettings.isAssistantDetached = isAssistantDetached }
    }
    /// When `true` (docked mode only — meaningless while detached into its own floating window),
    /// `RootView` shows the assistant panel filling the *entire* main content area instead of a
    /// narrow sidebar strip, hiding whatever page was showing underneath — "enlarge" as a real
    /// full-window mode, like Claude Code's own chat panel expand button, rather than opening a
    /// second OS window (`isAssistantDetached`'s own floating `NSPanel`, a `nonactivatingPanel`
    /// with a fixed off-center screen position — confirmed live, easy to mistake for the chat
    /// having just closed, since the sidebar copy vanishes and the replacement panel doesn't
    /// visibly take over anywhere obvious). Deliberately not persisted (`AppSettings`) — a
    /// transient view state, not a preference, the same "starts fresh every launch" treatment
    /// `isLiveStackingEnabled` gets for the identical reason.
    var isAssistantFullScreen = false
    /// A snapshot of whatever's currently on screen — set by whichever page is actually showing
    /// an image (`CaptureDetailPage`, for now) so "what is that?" can be answered by actually
    /// looking at it, the same vision-grounding `SingleImagePostProcessingView`'s own AI Assistant
    /// already does for Edit Image. `nil` on any page with nothing relevant to show (Home,
    /// Equipment, a `.recording`/`.serVideo` capture with no single representative frame).
    var assistantContextImage: CGImage?
    var isAssistantThinking = false
    let aiChatLibrary: AIChatLibrary
    /// The chat currently shown in `assistantMessages` — `nil` means "not saved yet," which is
    /// true for a brand-new blank conversation until its first message actually gets persisted.
    /// Not `private(set)`: `startNewChatSession()`/`switchToChatSession(_:)`/`deleteChatSession(_:)`
    /// are the only things that should change it, but tests construct chats through those same
    /// entry points already, so there's no need for a separate internal setter.
    private(set) var currentChatSessionID: AIChatSession.ID?
    /// Suppresses `assistantMessages`' own persist-on-change while `switchToChatSession(_:)`/
    /// `startNewChatSession()` assign a whole new array wholesale — without this, loading a saved
    /// chat back in would immediately "persist" it again, bumping its `updatedDate` and reshuffling
    /// the history list even though nothing actually changed.
    private var isLoadingChatSession = false
    /// Remembers whether the panel was docked in the sidebar right before the camera view took
    /// over — "in camera mode the AI is only detached" (enforced by `AssistantChatPanel` hiding
    /// its own Dock button whenever a session is active, not just by this flag) — so
    /// `syncAssistantDockStateForCameraMode()` knows whether to put it back once the user returns
    /// to browsing, versus leaving it wherever they explicitly moved/closed it meanwhile.
    private var wasAssistantDockedBeforeCameraMode = false
    var assistantMessages: [AssistantMessage] = [] {
        didSet { persistCurrentChatMessages() }
    }
    /// Set by `sendAssistantMessage(_:)` when the model proposes an action instead of just
    /// answering — shown with Approve/Reject; never applied until `confirmAssistantAction()` is
    /// called explicitly, per "if the chat change something ask before act." A plain `var`, not
    /// `private(set)`, so tests can drive `confirmAssistantAction()`/`rejectAssistantAction()`
    /// directly without a real Ollama round trip through `sendAssistantMessage`.
    var assistantPendingAction: AssistantPendingAction?
    /// The in-flight `sendAssistantMessage` call, if any — kept so `stopAssistantMessage()` has
    /// something to cancel. Only ever set by `startAssistantMessage(_:)`, the UI's own entry
    /// point; `sendAssistantMessage` itself stays a plain `async` function so tests can `await`
    /// it directly without needing a cancellable wrapper.
    private var assistantTask: Task<Void, Never>?

    /// The AI panel's actual entry point — runs `sendAssistantMessage(_:)` as a task the user can
    /// interrupt via `stopAssistantMessage()` (the panel's own Stop button, shown alongside
    /// "Thinking…"). Cancelling the returned task cooperatively cancels whatever's still
    /// in-flight underneath it — a `URLSession` request awaited inside the very same task tree
    /// throws `URLError.cancelled` the moment its task is cancelled, no extra plumbing needed.
    func startAssistantMessage(_ text: String) {
        assistantTask = Task { [weak self] in
            await self?.sendAssistantMessage(text)
        }
    }

    /// Cancels whatever `startAssistantMessage(_:)` is currently waiting on — "the AI session can
    /// be stopped." A no-op if nothing's in flight.
    func stopAssistantMessage() {
        assistantTask?.cancel()
    }

    /// Sends `text` to the sidebar assistant and appends both sides of the exchange to
    /// `assistantMessages` — a plain reply becomes an assistant message by itself; a proposed
    /// action becomes one (its own `message` explaining the proposal) plus `assistantPending
    /// Action` for the confirmation card to pick up.
    func sendAssistantMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        assistantMessages.append(AssistantMessage(role: .user, text: trimmed))
        isAssistantThinking = true
        defer { isAssistantThinking = false }
        do {
            let image = assistantContextImage.flatMap { AIVisionImageEncoder.jpegData(from: $0) }
            let response = try await ollamaPlanner.respond(to: trimmed, context: assistantContext(), history: assistantMessages, image: image)
            switch response {
            case .reply(let replyText):
                assistantMessages.append(AssistantMessage(role: .assistant, text: replyText))
            case .action(let action, let message):
                assistantMessages.append(AssistantMessage(role: .assistant, text: message))
                assistantPendingAction = AssistantPendingAction(action: action, message: message)
            }
        } catch is CancellationError {
            assistantMessages.append(AssistantMessage(role: .assistant, text: "Stopped."))
        } catch let error as OllamaError {
            AppLog.shared.log("AI panel: \(error.userFacingMessage)")
            assistantMessages.append(AssistantMessage(role: .assistant, text: error.userFacingMessage))
        } catch {
            if (error as? URLError)?.code == .cancelled {
                assistantMessages.append(AssistantMessage(role: .assistant, text: "Stopped."))
            } else {
                AppLog.shared.log("AI panel: couldn't reach Ollama.")
                assistantMessages.append(AssistantMessage(role: .assistant, text: "Couldn't reach Ollama — make sure it's running locally."))
            }
        }
    }

    /// Actually performs `assistantPendingAction`, then clears it — the one place any of the
    /// three `AssistantAction` cases actually mutates anything, strictly after explicit user
    /// approval (never from `sendAssistantMessage` itself).
    func confirmAssistantAction() {
        guard let pending = assistantPendingAction else { return }
        assistantPendingAction = nil
        switch pending.action {
        case .createProject(let name, let goal):
            do {
                try projectsLibrary.save(Project.newProject(name: name, goal: goal))
                assistantMessages.append(AssistantMessage(role: .assistant, text: "Created project \"\(name)\"."))
            } catch {
                AppLog.shared.log("AI panel: couldn't create project \"\(name)\" — \(error.localizedDescription)")
                assistantMessages.append(AssistantMessage(role: .assistant, text: "Couldn't create \"\(name)\" — \(error.localizedDescription)"))
            }

        case .createSession(let projectName, let sessionName, let goal, let plannedObjects):
            let matchedProject = projectsLibrary.projects.first { $0.name.caseInsensitiveCompare(projectName) == .orderedSame }
            let targetProject = matchedProject ?? Project.newProject(name: projectName, goal: "")
            do {
                if matchedProject == nil { try projectsLibrary.save(targetProject) }
                let session = Session.newSession(name: sessionName, goal: goal, plannedObjects: plannedObjects)
                try projectsLibrary.addSession(session, to: targetProject)
                assistantMessages.append(AssistantMessage(role: .assistant, text: "Created session \"\(sessionName)\" in \"\(targetProject.name)\"."))
            } catch {
                AppLog.shared.log("AI panel: couldn't create session \"\(sessionName)\" — \(error.localizedDescription)")
                assistantMessages.append(AssistantMessage(role: .assistant, text: "Couldn't create \"\(sessionName)\" — \(error.localizedDescription)"))
            }

        case .applyCameraSettings(let gain, let exposureSeconds, let mode):
            guard connectedCamera != nil else {
                assistantMessages.append(AssistantMessage(role: .assistant, text: "No camera is connected, so I couldn't apply that."))
                return
            }
            var preset = currentAcquisitionPreset(name: "Assistant Suggestion")
            if let gain { preset.gain = gain }
            if let exposureSeconds { preset.exposureSeconds = exposureSeconds }
            if let mode { preset.mode = mode }
            applyAcquisitionPreset(preset)
            assistantMessages.append(AssistantMessage(role: .assistant, text: "Applied the suggested camera settings."))

        case .setLiveStacking(let enabled):
            guard connectedCamera != nil else {
                assistantMessages.append(AssistantMessage(role: .assistant, text: "No camera is connected, so I couldn't apply that."))
                return
            }
            isLiveStackingEnabled = enabled
            assistantMessages.append(AssistantMessage(role: .assistant, text: enabled ? "Started Live Stack." : "Stopped Live Stack."))

        case .startLuckyImagingBurst(let frameCount):
            guard connectedCamera != nil else {
                assistantMessages.append(AssistantMessage(role: .assistant, text: "No camera is connected, so I couldn't apply that."))
                return
            }
            startLuckyImagingBurst(frameCount: frameCount)
            assistantMessages.append(AssistantMessage(role: .assistant, text: "Started a Lucky Imaging burst of \(frameCount) frames."))

        case .stackLuckyImagingBest(let fraction):
            guard luckyImagingSession != nil else {
                assistantMessages.append(AssistantMessage(role: .assistant, text: "There's no Lucky Imaging burst to stack right now."))
                return
            }
            stackLuckyImagingBest(fraction: fraction)
            assistantMessages.append(AssistantMessage(role: .assistant, text: "Stacked the sharpest \(Int(fraction * 100))% of the burst."))

        case .createEquipmentSystem(let name):
            equipmentLibrary.createSystem(name: name)
            assistantMessages.append(AssistantMessage(role: .assistant, text: "Created equipment system \"\(name)\"."))
        }
    }

    /// Declines `assistantPendingAction` without doing anything — the chat records that
    /// explicitly rather than the action just silently vanishing.
    func rejectAssistantAction() {
        guard assistantPendingAction != nil else { return }
        assistantPendingAction = nil
        assistantMessages.append(AssistantMessage(role: .assistant, text: "Okay, I won't do that."))
    }

    /// Saves `assistantMessages` into `currentChatSessionID`'s file, creating that chat's own
    /// saved session on its very first message rather than up front — a chat abandoned after
    /// zero messages never becomes a stray empty entry in the history list. Auto-titled from the
    /// first user message; see `AIChatSession.autoTitle(from:)`.
    private func persistCurrentChatMessages() {
        guard !isLoadingChatSession, !assistantMessages.isEmpty else { return }
        if let id = currentChatSessionID, var session = aiChatLibrary.session(withID: id) {
            session.messages = assistantMessages
            session.updatedDate = Date()
            aiChatLibrary.save(session)
        } else {
            let firstUserText = assistantMessages.first { $0.role == .user }?.text
            var session = aiChatLibrary.createSession(firstMessageText: firstUserText)
            session.messages = assistantMessages
            aiChatLibrary.save(session)
            currentChatSessionID = session.id
        }
    }

    /// Every saved chat, most-recently-updated first — what the AI panel's history menu lists.
    var chatSessions: [AIChatSession] { aiChatLibrary.sessions }

    /// "The user can create a new AI session" — starts a blank conversation. The previous one (if
    /// it had any messages) is already saved on disk from its own last message, so nothing is
    /// lost; this just stops appending to it.
    func startNewChatSession() {
        stopAssistantMessage()
        assistantPendingAction = nil
        isAssistantThinking = false
        currentChatSessionID = nil
        isLoadingChatSession = true
        assistantMessages = []
        isLoadingChatSession = false
    }

    /// "See the history recalling and continue a conversation" — reloads a previously saved chat
    /// exactly where it left off, so sending a new message appends to that same saved file instead
    /// of starting a fresh one.
    func switchToChatSession(_ id: AIChatSession.ID) {
        guard let session = aiChatLibrary.session(withID: id) else { return }
        stopAssistantMessage()
        assistantPendingAction = nil
        isAssistantThinking = false
        currentChatSessionID = session.id
        isLoadingChatSession = true
        assistantMessages = session.messages
        isLoadingChatSession = false
    }

    /// Deletes a saved chat outright. Falls back to a blank new chat if it was the one currently
    /// open, rather than leaving messages on screen for a conversation that no longer exists on
    /// disk.
    func deleteChatSession(_ id: AIChatSession.ID) {
        aiChatLibrary.delete(id)
        if currentChatSessionID == id {
            startNewChatSession()
        }
    }

    /// Renames a saved chat — the history list's own "Rename" action; doesn't require that chat to
    /// be the one currently open.
    func renameChatSession(_ id: AIChatSession.ID, to title: String) {
        aiChatLibrary.rename(id, to: title)
    }

    /// "Delete all chats" — wipes every saved conversation and starts a blank one, since the
    /// currently-open chat (if any) no longer exists on disk afterward either.
    func deleteAllChatSessions() {
        aiChatLibrary.deleteAll()
        startNewChatSession()
    }

    /// The assistant's approximation of "the current page's content" — this app's pages are a
    /// `NavigationStack` owned privately by `ProjectsBrowserView`, not something `CameraManager`
    /// can introspect directly, so this uses the same state every other cross-cutting feature
    /// (the breadcrumb, "Go Home") already keys off instead: the active project/session if any,
    /// the connected camera, and an `InsightsData` snapshot for "what have I actually been doing"
    /// / "what haven't I captured yet" questions.
    private func assistantContext() -> String {
        var lines: [String] = []
        // "When an AI session starts, add info [about] the current datetime and location" — a
        // question like "what can I see tonight" is meaningless without knowing *when* "tonight"
        // is and *where* the observer actually is. Rebuilt fresh on every message (this function
        // isn't cached), so the date/time is always genuinely current, not stale from whenever the
        // chat was first opened.
        lines.append("Current date/time: \(Self.assistantContextDateFormatter.string(from: Date())).")
        if let location = activeSession?.location ?? activeProject?.location ?? locationProvider.lastLocation {
            lines.append("Observer location: \(location.displayName) (latitude \(location.latitude), longitude \(location.longitude)).")
        } else {
            lines.append("Observer location: unknown — if the user names a place, use it; otherwise ask, or answer in general seasonal terms.")
        }
        if let project = activeProject {
            lines.append("Currently viewing project: \(project.name.isEmpty ? "(untitled)" : project.name). Goal: \(project.goal). Rating: \(ratingDescription(project.rating)).\(project.isFavorite ? " Marked as a favorite." : "")")
            if let session = activeSession {
                lines.append("Currently in session: \(session.name). Planned objects: \(session.plannedObjects.joined(separator: ", ")). Rating: \(ratingDescription(session.rating)).\(session.isFavorite ? " Marked as a favorite." : "")")
            }
        }
        if let camera = connectedCamera {
            lines.append("Connected camera: \(camera.name).")
            // "Extend AI context to Capture Live (with all kinds of capture and stacking/lucky
            // imaging)" — a question or proposed settings change while actually watching the live
            // view needs to know what's running right now, not just that a camera exists.
            let preset = currentAcquisitionPreset(name: "")
            var liveState = "Current acquisition mode: \(preset.mode.rawValue)."
            if let gain = preset.gain { liveState += " Gain: \(gain)." }
            if let exposureSeconds = preset.exposureSeconds { liveState += " Exposure: \(exposureSeconds)s." }
            liveState += " Render path: \(useMetalRenderer ? "GPU (Metal)" : "CPU")."
            if isLiveStackingEnabled {
                liveState += " Live Stack is running (\(liveStackMethod.label) method), \(liveStackedFrameCount) frame(s) accumulated so far\(effectiveLiveStackPaused ? ", currently paused" : "")."
            }
            if let session = luckyImagingSession {
                let progress = luckyImagingProgress ?? (captured: session.capturedCount, total: session.targetFrameCount)
                liveState += " Lucky Imaging burst in progress: \(progress.captured)/\(progress.total) frames captured\(isLuckyImagingBurstComplete ? " (complete, ready to stack)" : "")\(isLuckyImagingPaused ? ", currently paused" : "")."
            }
            lines.append(liveState)
        } else {
            lines.append("No camera is currently connected.")
        }
        let activeProjects = projectsLibrary.activeProjects
        lines.append("Total projects: \(activeProjects.count).")
        let insights = InsightsData.build(
            projects: activeProjects, equipmentSystems: equipmentLibrary.systems,
            knownObjects: ObservedObjectCatalog.allKnownObjectNames(projects: activeProjects), now: Date()
        )
        if !insights.byObject.isEmpty {
            let topObjects = insights.byObject.prefix(3).map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
            lines.append("Most captured objects so far: \(topObjects).")
        }
        if !insights.suggestedNextObjects.isEmpty {
            lines.append("Objects not yet captured — candidates for \"what to see next\": \(insights.suggestedNextObjects.joined(separator: ", ")).")
        }
        // "The AI chat … is able to analyze info about user behaviour and provide guidance
        // depending on the user score and activities" — favorites and highly-rated past actions
        // are exactly that: what the user themselves has already judged good, grounding any
        // "what worked" or "best settings for X" answer in their own history instead of guessing.
        let favoriteProjectNames = activeProjects.filter(\.isFavorite).map(\.name).filter { !$0.isEmpty }
        if !favoriteProjectNames.isEmpty {
            lines.append("Favorite projects: \(favoriteProjectNames.joined(separator: ", ")).")
        }
        let favoriteSessionNames = activeProjects.flatMap(\.sessions).filter(\.isFavorite).map(\.name)
        if !favoriteSessionNames.isEmpty {
            lines.append("Favorite sessions: \(favoriteSessionNames.joined(separator: ", ")).")
        }
        if !insights.topRatedActions.isEmpty {
            let summaries = insights.topRatedActions.prefix(5).map { action in
                "\(action.object): \(action.presetSummary) (rated \(action.rating)/5)"
            }
            lines.append("Highly rated past actions and the settings used — the best evidence for \"what settings work well\":\n" + summaries.joined(separator: "\n"))
        }
        // "Extend AI context to Gallery" — a question like "what's my best image of M31" needs to
        // know what's actually in the gallery, not just capture counts.
        let elaboratedImages = activeProjects.flatMap(\.elaboratedImages)
        if !elaboratedImages.isEmpty {
            lines.append("Total elaborated/gallery images across all projects: \(elaboratedImages.count).")
            let recentTitles = elaboratedImages.sorted { $0.date > $1.date }.prefix(5).map(\.displayLabel)
            lines.append("Most recent gallery images: \(recentTitles.joined(separator: ", ")).")
        }
        // "Extend AI context to Equipment" — which rig is assigned to the project currently being
        // viewed, plus what other rigs exist to propose switching to/creating.
        if !equipmentLibrary.systems.isEmpty {
            let systemNames = equipmentLibrary.systems.map(\.name).joined(separator: ", ")
            lines.append("Equipment systems set up: \(systemNames).")
            if let project = activeProject, let systemID = project.equipmentSystemID,
               let system = equipmentLibrary.system(withID: systemID) {
                lines.append("Equipment assigned to the current project: \(system.name) (\(system.items.map(\.displayName).joined(separator: ", "))).")
            }
        }
        // Grounds a small local model in general astronomy facts it doesn't reliably know on its
        // own (season a Messier object is best placed, that Venus is only ever visible near dawn/
        // dusk) — see `AstronomyKnowledgeBase`'s own doc comment for why this still isn't a
        // substitute for real position calculation, which this app doesn't do.
        let knowledgeBase = AstronomyKnowledgeBase.contextText()
        if !knowledgeBase.isEmpty {
            lines.append("Astronomy reference notes (general facts, not live positions — use judgment):\(knowledgeBase)")
        }
        return lines.joined(separator: "\n")
    }

    private func ratingDescription(_ rating: Rating) -> String {
        rating == .unrated ? "not rated" : "\(rating)/5"
    }

    private static let assistantContextDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' HH:mm"
        return formatter
    }()

    /// "Add the skill for the AI that suggests project sessions" — unlike `fetchSuggestedNextObjects`
    /// (a bare object name), this proposes a whole session: name, goal, target objects, and which
    /// project to attach it to. Driven by the user-editable `AppSettings.sessionSuggestionSkill`
    /// text. `nil` when Ollama isn't reachable or the model's reply isn't usable — there's no
    /// wizard-list equivalent to fall back to for a full session plan, so the caller (the Dashboard)
    /// simply doesn't show the card rather than showing something synthesized.
    func fetchSuggestedNextSession() async -> OllamaPlanner.SuggestedSessionPlan? {
        guard await ollamaPlanner.isAvailable() else { return nil }
        return try? await ollamaPlanner.suggestNextSession(context: assistantContext(), skill: AppSettings.sessionSuggestionSkill)
    }

    /// Applies a `fetchSuggestedNextSession()` result exactly the way `confirmAssistantAction()`'s
    /// own `.createSession` case does — case-insensitively matching an existing project by name, or
    /// creating a new one — so accepting a suggested session behaves identically to the AI panel
    /// proposing (and the user approving) the same action.
    func acceptSuggestedSession(_ plan: OllamaPlanner.SuggestedSessionPlan) {
        let matchedProject = projectsLibrary.projects.first { $0.name.caseInsensitiveCompare(plan.projectName) == .orderedSame }
        let targetProject = matchedProject ?? Project.newProject(name: plan.projectName, goal: "")
        do {
            if matchedProject == nil { try projectsLibrary.save(targetProject) }
            let session = Session.newSession(name: plan.name, goal: plan.goal, plannedObjects: plan.plannedObjects)
            try projectsLibrary.addSession(session, to: targetProject)
        } catch {
            lastErrorMessage = "Couldn't create the suggested session — \(error.localizedDescription)"
        }
    }

    /// "In camera mode the AI is only detached" — called by `activeSession`'s own `didSet`
    /// whenever it actually crosses the nil ↔ non-nil boundary (browser ↔ camera view).
    /// Entering camera mode force-detaches a currently-docked panel, remembering that it was
    /// docked; leaving camera mode puts it back in the sidebar, but only if it was actually docked
    /// before *and* the user hasn't closed the panel entirely in the meantime — closing always
    /// wins over restoring. A panel the user had already detached (or never opened) before
    /// entering camera mode is left exactly where it was.
    private func syncAssistantDockStateForCameraMode() {
        if activeSession != nil {
            if isAssistantPanelVisible && !isAssistantDetached {
                wasAssistantDockedBeforeCameraMode = true
                isAssistantDetached = true
            }
        } else {
            if wasAssistantDockedBeforeCameraMode && isAssistantPanelVisible {
                isAssistantDetached = false
            }
            wasAssistantDockedBeforeCameraMode = false
        }
    }

    /// Applies (and persists) a new Ollama server URL/model — "allow to choose the ai model in
    /// both settings and ai assistant. allow to change ollama server url." Takes effect
    /// immediately, unlike the Projects/Equipment folder settings: there's no destructive side
    /// effect to redirecting where the next network request goes, unlike relocating files a
    /// `ProjectStore`/`EquipmentLibrary` already has open.
    /// Unconditional — always rebuilds `ollamaPlanner` against Ollama, regardless of
    /// `AppSettings.aiProvider`. Safe: `SettingsView`'s own "AI (Ollama)" section (the only real
    /// caller) is only ever shown at all when `aiProvider == .ollama` already, so in practice this
    /// never fires while a cloud provider is the active selection.
    func updateOllamaConfiguration(serverURL: URL, model: String?) {
        AppSettings.ollamaServerURL = serverURL
        AppSettings.ollamaModel = model
        ollamaPlanner = OllamaPlanner(baseURL: serverURL, model: model)
    }

    /// "Configure AI with Ollama, or with an Anthropic/Gemini API key" — swaps `ollamaPlanner`'s
    /// own transport (see `AnthropicTransport`/`GeminiTransport`'s own doc comment for why routing
    /// through `OllamaPlanner` unchanged, rather than a parallel planner type, is the right call
    /// here) and rebuilds it immediately, the same "takes effect right away, no destructive side
    /// effect" reasoning `updateOllamaConfiguration` already documents.
    func updateAIProviderConfiguration(provider: AppSettings.AIProvider, anthropicAPIKey: String?, geminiAPIKey: String?) {
        AppSettings.aiProvider = provider
        AppSettings.anthropicAPIKey = anthropicAPIKey
        AppSettings.geminiAPIKey = geminiAPIKey
        ollamaPlanner = Self.makePlanner()
    }

    /// The one place that decides which transport `ollamaPlanner` actually talks over — read at
    /// `init` and again by `updateAIProviderConfiguration`/`updateOllamaConfiguration`, so both
    /// starting the app and changing Settings mid-session stay consistent with each other.
    static func makePlanner() -> OllamaPlanner {
        switch AppSettings.aiProvider {
        case .ollama:
            return OllamaPlanner(baseURL: AppSettings.ollamaServerURL, model: AppSettings.ollamaModel)
        case .anthropic:
            let model = AppSettings.anthropicModel ?? "claude-sonnet-5"
            let transport = AnthropicTransport(apiKey: AppSettings.anthropicAPIKey ?? "", model: model)
            // `model:` set explicitly (never `nil`) — `OllamaPlanner.resolveModel()`'s own
            // "nil means auto-detect via Ollama's /api/tags" fallback has no equivalent for a
            // cloud provider; this transport only ever reads `prompt` back out of the request
            // body (see its own doc comment), so a `GET /api/tags` auto-detect call would just
            // fail against it rather than doing anything useful.
            return OllamaPlanner(model: model, transport: transport)
        case .gemini:
            let model = AppSettings.geminiModel ?? "gemini-2.5-flash"
            let transport = GeminiTransport(apiKey: AppSettings.geminiAPIKey ?? "", model: model)
            return OllamaPlanner(model: model, transport: transport)
        }
    }

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
    /// "Filters" tab — a live-preview color emphasis stylized after common astronomy filters (see
    /// `AstronomyFilterType`'s doc comment: a stylistic aid, not an optical simulation of a real
    /// filter). Session state, not a persisted preference — always starts empty on launch; which
    /// filters were active for a given capture is recorded per-capture instead, via
    /// `AcquisitionPreset.selectedFilters`, the same "recall it like any other setting" treatment
    /// gain/exposure/ROI already get.
    var activeFilterSelections: [FilterSelection] = [] {
        didSet { refreshCurrentImage() }
    }

    /// What the render pipeline (GPU `MetalFrameRenderer`, CPU `CGImageRenderer`, and the export
    /// path via `renderedCurrentImage`) actually reads — `(1, 1, 1)`, a true no-op, when nothing's
    /// selected, so every stage can skip itself entirely rather than doing a wasted identity pass.
    var combinedFilterGain: SIMD3<Float> {
        FilterSelection.combinedGain(for: activeFilterSelections)
    }

    func filterIntensity(for filter: AstronomyFilterType) -> Double {
        activeFilterSelections.first { $0.filter == filter }?.intensity ?? 0
    }

    /// Sets `filter`'s intensity directly (the "Filters" tab's per-filter slider) — `0` removes it
    /// from `activeFilterSelections` entirely rather than leaving a lingering zero-strength entry,
    /// so "how many filters are active" (used for the tab's badge/summary) stays accurate.
    func setFilterIntensity(_ filter: AstronomyFilterType, intensity: Double) {
        let clamped = max(0, min(1, intensity))
        if let index = activeFilterSelections.firstIndex(where: { $0.filter == filter }) {
            if clamped <= 0 {
                activeFilterSelections.remove(at: index)
            } else {
                activeFilterSelections[index].intensity = clamped
            }
        } else if clamped > 0 {
            activeFilterSelections.append(FilterSelection(filter: filter, intensity: clamped))
        }
    }

    /// Selecting a filter with no intensity specified yet (the tab's own checkbox/swatch) starts
    /// it at a visible-but-not-overwhelming `0.75` — "pick one, see it live" shouldn't also require
    /// dragging a slider up from zero just to see anything happen.
    func toggleFilter(_ filter: AstronomyFilterType) {
        if activeFilterSelections.contains(where: { $0.filter == filter }) {
            activeFilterSelections.removeAll { $0.filter == filter }
        } else {
            activeFilterSelections.append(FilterSelection(filter: filter, intensity: 0.75))
        }
    }

    func disableAllFilters() {
        activeFilterSelections.removeAll()
    }
    /// Set on a fresh ZWO connection (see `connect(to:)`) — `.identity` is a safe *interim* value
    /// (better than inheriting an unrelated previous session's black/white point), but it's a bad
    /// permanent default for a real linear sensor: real signal only occupies a small fraction of
    /// the full digital range, so `.identity` alone renders as solid black at any reasonable
    /// gain. `ingest()` consumes this exactly once, auto-stretching from the first real frame's
    /// own histogram (`DisplayStretch.autoStretch`) as soon as one arrives.
    private var pendingAutoStretch = false
    /// Throttles the periodic Live Stack re-stretch below — `nil` right after (re)starting a
    /// stack, so the very first check re-stretches immediately rather than waiting a full
    /// interval.
    private var lastLiveStackAutoStretchDate: Date?
    /// How often `ingest()` re-derives the display stretch from the *accumulated* (averaged)
    /// frame while Live Stack is running, rather than the once-per-connection stretch computed
    /// from a single noisy frame at `pendingAutoStretch` time. "I don't see the image become
    /// bright" during Live Stack: averaging genuinely doesn't change mean brightness (only noise),
    /// but a stretch frozen at the very first frame's histogram also never lets the *now-cleaner*
    /// accumulated image's own black/white points adapt — so it can look static even as SNR
    /// actually improves underneath. Every 5s is fast enough to feel responsive without recomputing
    /// a histogram (and, on the GPU path, reading the accumulator back to the CPU) every frame.
    private static let liveStackAutoStretchInterval: TimeInterval = 5
    /// Guards against overlapping restretch work — the histogram/channel-histogram passes below
    /// run detached (see the doc comment where this is used), so a slow one still running when
    /// the next 5-second interval elapses just gets skipped rather than queuing up a second one.
    private var liveStackAutoStretchTask: Task<Void, Never>?

    /// `true` while continuously polling video frames; `false` while showing a still frame
    /// from `captureSingleExposure`.
    private(set) var isLiveViewActive = true
    private(set) var isCapturingExposure = false
    /// When the live-view frame currently exposing started — `nil` whenever there's nothing
    /// worth counting down (no camera, a blocking single/dark/flat capture is running instead,
    /// or the exposure is short enough that a countdown would just flicker uselessly). Reset to
    /// "now" every time a real frame actually arrives (`ingest(_:)`), since in continuous
    /// streaming mode that's also the moment the camera's own internal exposure/readout cycle
    /// starts again for the next one — `ASIGetVideoData` blocks until the *current* exposure
    /// finishes, so "time since the last frame arrived" is exactly "time into the next exposure."
    private(set) var liveViewFrameStartDate: Date?
    /// How long the just-started live-view exposure is expected to take — a snapshot of
    /// `currentLiveExposureSeconds` taken alongside `liveViewFrameStartDate`, not read live by the
    /// UI each tick, so a mid-exposure change to the exposure control doesn't retroactively
    /// misdate a countdown already in progress.
    private(set) var liveViewFrameExpectedDuration: Double?
    /// Below this, a countdown would tick faster than it's readable and just adds visual noise at
    /// normal fast live-view frame rates — the whole point is surfacing a wait actually worth
    /// knowing about.
    private static let liveViewCountdownMinimumDuration: Double = 0.75
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
    /// Independent of `isNightModeEnabled` — the live image itself is exempt from the red tint
    /// by default (true star colors are the point of the app), but this lets it be tinted too
    /// ("dark mode" for the video, matching the rest of the UI) or switched back to true color
    /// ("normal") on demand, both without touching the master Night Mode switch. Meaningless
    /// while `isNightModeEnabled` is off — `PreviewView` only reads it when that's also on.
    var isNightModePreviewTinted = AppSettings.isNightModePreviewTinted {
        didSet { AppSettings.isNightModePreviewTinted = isNightModePreviewTinted }
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
    /// Drives the Calibration Wizard `.sheet` on `ContentView` — same single-window reasoning as
    /// `isHelpPresented` above.
    var isCalibrationWizardPresented = false
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

    /// Bumped by `revealCaptureROISettings()` — `ControlsPanelView` observes this via
    /// `.onChange` and reacts by switching itself to the Planetary tab and expanding the
    /// Advanced/Capture ROI disclosure groups down to that control. A counter, not a `Bool`,
    /// so asking for the same reveal twice in a row (e.g. the header's ROI shortcut clicked
    /// again while already on that tab) still fires the `.onChange` each time.
    private(set) var captureROIRevealRequestID: Int = 0

    /// Called from the live-session header's ROI shortcut — jumps straight to the Capture ROI
    /// control in the sidebar instead of making the user hunt for it under Planetary → Advanced.
    func revealCaptureROISettings() {
        captureROIRevealRequestID += 1
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
    // The `refreshCurrentImage()` call in each of these three `didSet`s is the CPU-render-path
    // fix for "enhancement applied to the next frame, not the last visible one": `scheduleCPU
    // EnhancementIfNeeded` was previously only ever invoked from `refreshCurrentImage()`, which
    // itself only ran when a brand-new frame arrived via `ingest` — so toggling/adjusting denoise
    // or sharpening had no visible effect on the frame already on screen until the next capture
    // happened to arrive. Re-running it here re-processes the same `currentFrame` immediately.
    // A no-op with no camera connected/no frame yet (`refreshCurrentImage` guards on both).
    var isDenoisingEnabled = AppSettings.isDenoisingEnabled {
        didSet {
            AppSettings.isDenoisingEnabled = isDenoisingEnabled
            refreshCurrentImage()
        }
    }
    var isWaveletSharpeningEnabled = AppSettings.isWaveletSharpeningEnabled {
        didSet {
            AppSettings.isWaveletSharpeningEnabled = isWaveletSharpeningEnabled
            refreshCurrentImage()
        }
    }
    var waveletSharpenAmount: Double = AppSettings.waveletSharpenAmount {
        didSet {
            AppSettings.waveletSharpenAmount = waveletSharpenAmount
            refreshCurrentImage()
        }
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

    /// `nil` when dark subtraction is off, no dark is active, or the active dark's own
    /// exposure/gain both match the camera's current live `ASI_EXPOSURE`/`ASI_GAIN` values (the
    /// ones actually driving the continuous video stream live stacking accumulates — not the
    /// separate "Single Exposure" field). Non-`nil` explains exactly what differs. Purely
    /// informational — `applyDarkSubtraction` still subtracts the active dark either way (a
    /// same-dimension dark captured at the wrong gain/exposure still removes *some* fixed-pattern
    /// noise, just not all of it) — but a mismatch was previously silent: dial in a fresh gain
    /// for tonight's target after capturing darks yesterday at a different one, and the app would
    /// keep subtracting the stale dark with no indication it no longer fully cancels the sensor's
    /// current thermal/read noise.
    /// The live `ASI_EXPOSURE` control's current value, in seconds — `nil` for a webcam/iPhone
    /// source or before it's ever been read. What "Match Live" (next to the dark-frame capture
    /// field) copies into the capture-exposure field, since that's the value a dark actually
    /// needs to match — not the separate "Single Exposure" field, which drives a different,
    /// independent blocking capture.
    var currentLiveExposureSeconds: Double? {
        guard let exposureCap = controlCap(ASI_EXPOSURE, in: controls), let microseconds = controlValues[exposureCap.id]?.value
        else { return nil }
        return Double(microseconds) / 1_000_000
    }

    var darkFrameMismatchWarning: String? {
        guard isDarkSubtractionEnabled, let dark = calibrationLibrary.activeDark else { return nil }
        var mismatches: [String] = []
        if let exposureCap = controlCap(ASI_EXPOSURE, in: controls), let liveMicroseconds = controlValues[exposureCap.id]?.value,
           liveMicroseconds != dark.exposureMicroseconds {
            let darkSeconds = String(format: "%.2f", Double(dark.exposureMicroseconds) / 1_000_000)
            let liveSeconds = String(format: "%.2f", Double(liveMicroseconds) / 1_000_000)
            mismatches.append("exposure (dark: \(darkSeconds)s, live: \(liveSeconds)s)")
        }
        if let gainCap = controlCap(ASI_GAIN, in: controls), let liveGain = controlValues[gainCap.id]?.value,
           let darkGain = dark.gain, liveGain != darkGain {
            mismatches.append("gain (dark: \(darkGain), live: \(liveGain))")
        }
        guard !mismatches.isEmpty else { return nil }
        return "Active dark doesn't match current live settings — \(mismatches.joined(separator: ", ")). It'll still be subtracted, but won't fully cancel sensor noise until you capture a new one at these settings."
    }

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
            lastLiveStackAutoStretchDate = nil
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
        lastLiveStackAutoStretchDate = nil
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
    /// The bucket-index-of-the-max-count, as a 0...1 fraction — `nonisolated` so
    /// `applyLiveStackAutoStretch`'s detached task (see `ingest()`) can call it without hopping
    /// back to the main actor; it's a pure function over a plain `[Int]`, nothing about it needs
    /// `CameraManager`'s own state.
    nonisolated private static func peakFraction(_ histogram: [Int]) -> Float {
        let bucket = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 0
        return Float(bucket) / Float(histogram.count - 1)
    }

    /// "Dynamic Auto-Stretching" (spec step 5) — the actual fix for "stacking doesn't visibly
    /// brighten": re-derives `gpuControls`' non-linear arcsinh stretch from the *stack's own*
    /// current histogram, on the same rate-limited cadence as the base linear `stretch`'s own
    /// auto-restretch. Requires `gpuControls.isEnabled` (the arcsinh stage only runs at all when
    /// Live GPU Controls are on) — this only ever adjusts its *parameters*, never flips that
    /// switch on by itself, matching every other feature here that stops at "adjust a setting the
    /// user already opted into" rather than silently enabling a whole other panel.
    ///
    /// Called from `ingest()`'s detached restretch task with results already computed off the
    /// main actor (the histogram passes are the expensive part — see that call site's doc
    /// comment) — this just applies them. `channelPeaks` mirrors "Auto Color Balance: Aligns the
    /// peaks of the R, G, and B histograms," shifting each channel's own black point (in the base
    /// per-channel stretch, not the single-channel arcsinh stage above) so their backgrounds line
    /// up instead of, say, a light-polluted sky's characteristic orange cast leaving red's peak
    /// well right of blue's. Green is the reference channel (a Bayer sensor has twice as many
    /// green photosites, so it's already the least noisy estimate) — red/blue's black points
    /// shift by however far their own peak sits from green's.
    private func applyLiveStackAutoStretch(
        auto: DisplayStretch?, dynamicResult: LiveStackDynamicStretch.Result?, channelPeaks: (red: Float, green: Float, blue: Float)?
    ) {
        if let auto {
            stretch = auto
        }
        if let dynamicResult {
            gpuControls.blackPoint = dynamicResult.blackPoint
            gpuControls.whitePoint = dynamicResult.whitePoint
            gpuControls.stretchIntensity = dynamicResult.stretchIntensity
        }
        if let channelPeaks {
            let current = effectiveChannelStretch
            // `effectiveChannelStretch` ignores `channelStretch` entirely while independent-
            // channel mode is off, which would make writing it below silently do nothing — this
            // is the one deliberate case where Auto Color Balance turns that mode on by itself,
            // since there's no other way to actually apply a per-channel correction.
            isIndependentChannelStretchEnabled = true
            channelStretch = PerChannelStretch(
                red: DisplayStretch(
                    blackPoint: Double(max(current.red.blackPoint + Double(channelPeaks.red - channelPeaks.green), 0)),
                    whitePoint: current.red.whitePoint
                ),
                green: current.green,
                blue: DisplayStretch(
                    blackPoint: Double(max(current.blue.blackPoint + Double(channelPeaks.blue - channelPeaks.green), 0)),
                    whitePoint: current.blue.whitePoint
                )
            )
        }
        liveStackAutoStretchTask = nil
    }

    /// Throttles `updateLiveStackSigmaClippingKappaSigma`'s full-frame histogram scan to once
    /// every `sigmaClippingKappaUpdateInterval` frames — background noise doesn't meaningfully
    /// change frame-to-frame, so re-deriving it on every single incoming frame (this was a real
    /// contributor to live stacking feeling unresponsive: a full histogram pass on the main
    /// actor, once per frame, only while sigma-clipping was active) bought accuracy nobody could
    /// actually see for a real per-frame cost.
    private var sigmaClippingKappaFrameCounter = 0
    private let sigmaClippingKappaUpdateInterval = 5

    /// Refreshes `liveStackSigmaClippingKappaSigma` from `frame`'s own histogram — only while
    /// sigma-clipping is actually the active stacking method, since this is an extra full-frame
    /// histogram scan `.average` (the default) never needs to pay for. Computed from the raw
    /// incoming frame, not the smoothed stack, so it reflects real per-frame sensor noise rather
    /// than the (deliberately lower) noise already averaged into the accumulator so far.
    private func updateLiveStackSigmaClippingKappaSigma(_ frame: CapturedFrame) {
        guard isLiveStackingEnabled, liveStackMethod == .sigmaClipping else {
            liveStackSigmaClippingKappaSigma = 0
            sigmaClippingKappaFrameCounter = 0
            return
        }
        defer { sigmaClippingKappaFrameCounter += 1 }
        guard sigmaClippingKappaFrameCounter % sigmaClippingKappaUpdateInterval == 0 else { return }
        let sigma = LiveStackDynamicStretch.standardDeviation(histogram: HistogramComputer.histogram(for: frame))
        liveStackSigmaClippingKappaSigma = liveStackSigmaClippingKappa * sigma
    }

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

    // MARK: - Live Stack fix (specs/live-stackig-fix-spec.md)

    /// "Stacking Method: [Average, Sigma Clipping]" — a real preference, persisted like
    /// `smartLiveStackQualityFraction`. GPU-only; the CPU `LiveStacker` path has no sigma-clipping
    /// implementation and always averages regardless of this setting (see `ingest`'s own doc
    /// comment on `usesCPUStack`).
    var liveStackMethod: LiveStackMethod = AppSettings.liveStackMethod {
        didSet { AppSettings.liveStackMethod = liveStackMethod }
    }
    /// "Sigma Clipping Factor (Kappa)" — how many standard deviations a pixel must deviate from
    /// its own running average before `accumulateMonoSigmaClipped` rejects it that frame.
    var liveStackSigmaClippingKappa: Float = AppSettings.liveStackSigmaClippingKappa {
        didSet { AppSettings.liveStackSigmaClippingKappa = liveStackSigmaClippingKappa }
    }
    /// `kappa * sigma`, recomputed every `ingest` call from the incoming frame's own histogram —
    /// see `accumulateMonoSigmaClipped`'s doc comment for why this is a single global per-frame
    /// noise estimate rather than a true per-pixel running variance. Read by `MetalPreviewView`
    /// when building `MetalFrameRenderer.pendingUpdate`.
    private(set) var liveStackSigmaClippingKappaSigma: Float = 0

    /// "Dynamic Auto-Stretch" (spec step 5, section 3's Display/Stretch Settings) — the actual fix
    /// for "stacking doesn't visibly brighten": keeps re-deriving a non-linear (arcsinh) stretch
    /// from the *stack's own* current histogram as it grows, via `gpuControls`, instead of the
    /// base `stretch`/`channelStretch` sliders' fixed black/white points staying static while the
    /// underlying SNR actually improves. Opt-in like every other visually-altering toggle here.
    var isLiveStackAutoStretchContinuous: Bool = AppSettings.isLiveStackAutoStretchContinuous {
        didSet { AppSettings.isLiveStackAutoStretchContinuous = isLiveStackAutoStretchContinuous }
    }
    var liveStackStretchAggressiveness: StretchAggressiveness = AppSettings.liveStackStretchAggressiveness {
        didSet { AppSettings.liveStackStretchAggressiveness = liveStackStretchAggressiveness }
    }
    /// "Auto Black Point Offset" slider — nudges the histogram-peak-derived black point that
    /// `isLiveStackAutoStretchContinuous` computes. Positive digs further into the background.
    var liveStackAutoBlackPointOffset: Float = AppSettings.liveStackAutoBlackPointOffset {
        didSet { AppSettings.liveStackAutoBlackPointOffset = liveStackAutoBlackPointOffset }
    }
    /// "Auto Color Balance: aligns the peaks of the R, G, and B histograms" — only meaningful for
    /// a color camera; a no-op for mono the same way `PerChannelStretch` already is everywhere
    /// else in this app.
    var isLiveStackAutoColorBalanceEnabled: Bool = AppSettings.isLiveStackAutoColorBalanceEnabled {
        didSet { AppSettings.isLiveStackAutoColorBalanceEnabled = isLiveStackAutoColorBalanceEnabled }
    }

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

        // Same degenerate-frame guard as `SERWriter.write` — a genuinely blank frame (an
        // auto-crop ROI momentarily tracking empty sky, a transient sensor read glitch) writes
        // fine as a FITS file on its own, but trips Siril's stacking normalization the moment it
        // computes that frame's MAD (median absolute deviation) and gets zero: "MAD is null.
        // Statistics cannot be computed." Skipping it here, like the SER path already does, means
        // every frame that makes it into the sequence is guaranteed usable downstream.
        guard SERWriter.hasVariance(frame.data) else {
            discardedFrameCount += 1
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
        serRecordingURL = url
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
        if let url = serRecordingURL {
            recordActiveSessionCapture(url: url, kind: .serVideo, image: currentDisplayImage())
        }
        serRecordingURL = nil
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

    // MARK: - Siril elaboration (`SirilElaborationService`)

    /// What "Elaborate…" would actually send Siril for one specific capture — `nil` when this
    /// capture's `kind` isn't something Siril can meaningfully process further (a `.png`/`.tiff`
    /// export is already debayered/stretched for display; there's no raw data left to hand off).
    func elaborationSource(forCaptureID captureID: UUID, in session: Session, project: Project) -> (SirilElaborationService.Source, AcquisitionTarget?)? {
        guard let capture = session.captures.first(where: { $0.id == captureID }) else { return nil }
        let folder = projectStore.sessionFolderURL(for: session, in: project)
        let url = folder.appendingPathComponent(capture.fileName)
        let target = capture.preset.flatMap { AcquisitionTarget.resolve(id: $0.targetID) }
        switch capture.kind {
        case .fits: return (.singleFITS(url), target)
        case .serVideo: return (.serVideo(url), target)
        case .png, .tiff, .recording, .video: return nil
        }
    }

    /// What "Elaborate…" would send Siril for a whole session — a `.ser` video wins if one
    /// exists (the unambiguous lucky-imaging case); otherwise every `.fits` capture in the
    /// session becomes one deep-sky (or planetary, if the resolved target says so) sequence.
    /// `nil` when the session has nothing Siril can process (only `.png`/`.tiff` captures, or
    /// none at all).
    func elaborationSource(for session: Session, project: Project) -> (SirilElaborationService.Source, AcquisitionTarget?)? {
        let folder = projectStore.sessionFolderURL(for: session, in: project)
        if let ser = session.captures.first(where: { $0.kind == .serVideo }) {
            let target = ser.preset.flatMap { AcquisitionTarget.resolve(id: $0.targetID) }
            return (.serVideo(folder.appendingPathComponent(ser.fileName)), target)
        }
        let fitsCaptures = session.captures.filter { $0.kind == .fits }
        if fitsCaptures.count == 1, let only = fitsCaptures.first {
            let target = only.preset.flatMap { AcquisitionTarget.resolve(id: $0.targetID) }
            return (.singleFITS(folder.appendingPathComponent(only.fileName)), target)
        }
        if !fitsCaptures.isEmpty {
            let target = fitsCaptures.first?.preset.flatMap { AcquisitionTarget.resolve(id: $0.targetID) }
            return (.fitsFrames(fitsCaptures.map { folder.appendingPathComponent($0.fileName) }), target)
        }
        return nil
    }

    /// Runs `source` through Siril and records the result against `project` — the one entry
    /// point both "Elaborate Session…" and "Elaborate…" on a single capture go through, after the
    /// user's confirmed the (auto-suggested, overridable) `recipe` in `ElaborateSheet`.
    func elaborate(
        source: SirilElaborationService.Source, recipe: ElaborationRecipe,
        sourceSessionIDs: [UUID], sourceCaptureID: UUID?, project: Project,
        parameters: SirilElaborationService.ElaborationParameters = .default,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> ElaboratedImage {
        let outputDirectory = projectStore.elaboratedImagesFolderURL(for: project)
        let baseName = "Elaborated-\(ProjectStore.sanitizeForFilename(project.name))-\(Int(Date().timeIntervalSince1970))"
        let resultURL = try await SirilElaborationService.elaborate(
            source: source, recipe: recipe, outputDirectory: outputDirectory, outputBaseName: baseName,
            parameters: parameters, onLog: onLog
        )
        return try projectsLibrary.addElaboratedImage(
            fileName: resultURL.lastPathComponent, sourceSessionIDs: sourceSessionIDs,
            sourceCaptureID: sourceCaptureID, recipe: recipe, to: project
        )
    }

    /// Runs an existing image (typically a Siril elaboration's `.tif`) through GraXpert and
    /// records the result against `project` as its own new `ElaboratedImage` entry — a new entry
    /// alongside the input, not a replacement, same "both remain comparable" reasoning
    /// `ElaboratedImageCard`'s own doc comment already gives for Siril's "Re-elaborate…".
    func sendToGraXpert(
        inputURL: URL, operation: GraXpertElaborationService.Operation,
        sourceSessionIDs: [UUID], sourceCaptureID: UUID?, project: Project,
        parameters: GraXpertElaborationService.Parameters = .default,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> ElaboratedImage {
        let outputDirectory = projectStore.elaboratedImagesFolderURL(for: project)
        let baseName = "GraXpert-\(ProjectStore.sanitizeForFilename(project.name))-\(Int(Date().timeIntervalSince1970))"
        let resultURL = try await GraXpertElaborationService.run(
            inputURL: inputURL, operation: operation, parameters: parameters,
            outputDirectory: outputDirectory, outputBaseName: baseName, onLog: onLog
        )
        return try projectsLibrary.addElaboratedImage(
            fileName: resultURL.lastPathComponent, sourceSessionIDs: sourceSessionIDs,
            sourceCaptureID: sourceCaptureID, toolLabel: "GraXpert · \(operation.label)", to: project
        )
    }

    /// Runs an existing image through StarNet for star removal — same "new entry alongside the
    /// input" reasoning as `sendToGraXpert`.
    func sendToStarNet(
        inputURL: URL, sourceSessionIDs: [UUID], sourceCaptureID: UUID?, project: Project,
        parameters: StarNetElaborationService.Parameters = .default,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws -> ElaboratedImage {
        let outputDirectory = projectStore.elaboratedImagesFolderURL(for: project)
        let baseName = "StarNet-\(ProjectStore.sanitizeForFilename(project.name))-\(Int(Date().timeIntervalSince1970))"
        let resultURL = try await StarNetElaborationService.run(
            inputURL: inputURL, parameters: parameters, outputDirectory: outputDirectory, outputBaseName: baseName, onLog: onLog
        )
        return try projectsLibrary.addElaboratedImage(
            fileName: resultURL.lastPathComponent, sourceSessionIDs: sourceSessionIDs,
            sourceCaptureID: sourceCaptureID, toolLabel: "StarNet · Star Removal", to: project
        )
    }

    /// Records a `PlanetaryPostProcessingView` result as its own new `ElaboratedImage` — unlike
    /// `sendToGraXpert`/`sendToStarNet`, there's no external process here (the whole pipeline runs
    /// in-app), so this just writes the already-rendered frame to disk and catalogs it. `title`/
    /// `notes` are whatever the user optionally typed in the save sheet; `settings` is the exact
    /// Stage 3-5 recipe that produced `image`, both just carried straight onto the new entry.
    func savePlanetaryPostProcessingResult(
        _ image: CGImage, sourceSessionIDs: [UUID], sourceCaptureID: UUID?, project: Project,
        title: String?, notes: String?, settings: PlanetaryPostProcessor.SettingsSnapshot?
    ) throws -> ElaboratedImage {
        let outputDirectory = projectStore.elaboratedImagesFolderURL(for: project)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fileName = "Planetary-\(ProjectStore.sanitizeForFilename(project.name))-\(Int(Date().timeIntervalSince1970)).png"
        let resultURL = outputDirectory.appendingPathComponent(fileName)
        try ImageExporter.writePNG(image, to: resultURL)
        return try projectsLibrary.addElaboratedImage(
            fileName: fileName, sourceSessionIDs: sourceSessionIDs,
            sourceCaptureID: sourceCaptureID, toolLabel: "Planetary Post-Processing",
            title: title, notes: notes, planetarySettings: settings, to: project
        )
    }

    /// The "Overwrite" half of `PlanetaryPostProcessingView`'s save flow — replaces `existing`'s
    /// own file (same `fileName`, so this really does overwrite the bytes on disk, not just
    /// relabel a new file) and updates its catalog entry's metadata in place, rather than adding
    /// a second `ElaboratedImage` the way `savePlanetaryPostProcessingResult` above does.
    func overwritePlanetaryPostProcessingResult(
        _ image: CGImage, existing: ElaboratedImage, project: Project,
        title: String?, notes: String?, settings: PlanetaryPostProcessor.SettingsSnapshot?
    ) throws -> ElaboratedImage {
        let outputDirectory = projectStore.elaboratedImagesFolderURL(for: project)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let resultURL = outputDirectory.appendingPathComponent(existing.fileName)
        try ImageExporter.writePNG(image, to: resultURL)
        return try projectsLibrary.updateElaboratedImage(
            existing.id, title: title, notes: notes, planetarySettings: settings, in: project
        )
    }

    /// `SingleImagePostProcessingView`'s own save — same "write a PNG into this project's
    /// Elaborated folder, catalog it" shape as `savePlanetaryPostProcessingResult` above, just
    /// under a different tool label so the two are distinguishable in the Elaborated gallery.
    func saveImageEditResult(
        _ image: CGImage, sourceSessionIDs: [UUID], sourceCaptureID: UUID?, project: Project
    ) throws -> ElaboratedImage {
        let outputDirectory = projectStore.elaboratedImagesFolderURL(for: project)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fileName = "Edited-\(ProjectStore.sanitizeForFilename(project.name))-\(Int(Date().timeIntervalSince1970)).png"
        let resultURL = outputDirectory.appendingPathComponent(fileName)
        try ImageExporter.writePNG(image, to: resultURL)
        return try projectsLibrary.addElaboratedImage(
            fileName: fileName, sourceSessionIDs: sourceSessionIDs,
            sourceCaptureID: sourceCaptureID, toolLabel: "Image Editor", to: project
        )
    }

    /// `MosaicComposerView`'s own save — same "write a PNG into this project's Elaborated folder,
    /// catalog it" shape as `saveImageEditResult`/`savePlanetaryPostProcessingResult` above, under
    /// its own tool label. `sourceCaptureID` is always `nil` here (never a single representative
    /// capture — a mosaic result never has just one, same reasoning `savePlanetaryPostProcessingResult`'s
    /// own multi-capture call sites already use `nil` for).
    /// `filePrefix`/`toolLabel` default to the original Mosaic Composer naming — `StillImageStacker`'s
    /// own "Stack Captures" flow (`MosaicComposerView.Mode.stack`) calls this with `"Stack"`/`"Stack
    /// Captures"` instead, so both share this one save path rather than duplicating it.
    func saveMosaicResult(
        _ image: CGImage, sourceSessionIDs: [UUID], project: Project,
        filePrefix: String = "Mosaic", toolLabel: String = "Mosaic Composer"
    ) throws -> ElaboratedImage {
        let outputDirectory = projectStore.elaboratedImagesFolderURL(for: project)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let fileName = "\(filePrefix)-\(ProjectStore.sanitizeForFilename(project.name))-\(Int(Date().timeIntervalSince1970)).png"
        let resultURL = outputDirectory.appendingPathComponent(fileName)
        try ImageExporter.writePNG(image, to: resultURL)
        return try projectsLibrary.addElaboratedImage(
            fileName: fileName, sourceSessionIDs: sourceSessionIDs,
            sourceCaptureID: nil, toolLabel: toolLabel, to: project
        )
    }

    /// "Import one or more images/videos from a file/folder or Apple Photos into a session" —
    /// each `url` is copied into `session`'s own folder and recorded as an ordinary
    /// `CaptureRecord` via `ProjectStore.recordCapture(copyingFileAt:...)`, the exact same call a
    /// real capture path uses, just fed a file that already exists somewhere else instead of one
    /// this app's own camera pipeline just wrote. Skips (rather than aborts on) a URL
    /// `MediaImporter.kind(for:)` doesn't recognize or that fails to copy — a caller reports
    /// `skipped` however it wants (a toast, a summary line) rather than losing an otherwise-good
    /// batch to one bad file. `project` is looked up fresh by ID at the end so the caller's own
    /// (possibly now-stale, several captures later) value isn't what gets saved.
    @discardableResult
    func importMedia(from urls: [URL], into session: Session, project: Project) async -> (imported: [CaptureRecord], skipped: [URL]) {
        var updatedProject = project
        var imported: [CaptureRecord] = []
        var skipped: [URL] = []
        for url in urls {
            guard let kind = MediaImporter.kind(for: url) else {
                skipped.append(url)
                continue
            }
            guard let sessionIndex = updatedProject.sessions.firstIndex(where: { $0.id == session.id })
            else { break } // the session itself is gone — nothing left to import into.
            let currentSession = updatedProject.sessions[sessionIndex]
            let thumbnail = await MediaImporter.makeThumbnail(for: url, kind: kind)
            guard let record = try? projectStore.recordCapture(
                copyingFileAt: url, kind: kind, thumbnail: thumbnail,
                note: "Imported \(url.lastPathComponent)",
                into: currentSession, project: &updatedProject
            ) else {
                skipped.append(url)
                continue
            }
            imported.append(record)
        }
        // `recordCapture` above only persists to disk (`ProjectStore.save`, not
        // `ProjectsLibrary`'s own) — see `ProjectDetailPane.project`'s own doc comment for why a
        // page reading live from `projectsLibrary.projects` wouldn't otherwise see these new
        // captures until reopened.
        if !imported.isEmpty {
            try? projectsLibrary.save(updatedProject)
        }
        return (imported, skipped)
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
    /// Chains every capture-pipeline restart (`changeImageType`/`changeCaptureROI`) one after
    /// another instead of letting them run concurrently — see `restartCapturePipeline`'s doc
    /// comment for the actual bug this exists to prevent.
    private var pipelineRestartTask: Task<Void, Never>?
    private var focusAssistTask: Task<Void, Never>?
    private var enhancementTask: Task<Void, Never>?
    private var qualityScoreTask: Task<Void, Never>?

    // MARK: - Active project/session

    /// `activeSession == nil` is the one gate `RootView` checks to decide whether to show the
    /// Projects browser or the camera `ContentView` — a session's actual *execution* is the
    /// camera UI, browsing a project and its sessions (even with a project "open" as context via
    /// `activeProject` alone) stays in the browser. Not `@ObservationIgnored`:
    /// `RootView`/`ProjectsBrowserView` etc. observe both directly, but `projectStore` itself
    /// never changes after init, so it doesn't need to.
    let projectStore: ProjectStore
    let locationProvider: CoreLocationProvider
    let projectsLibrary: ProjectsLibrary
    /// Not `let` — `updateOllamaConfiguration(serverURL:model:)` rebuilds this in place whenever
    /// Settings or the AI panel's own model menu changes the server URL or pinned model.
    private(set) var ollamaPlanner: OllamaPlanner
    let equipmentLibrary: EquipmentLibrary
    var activeProject: Project?
    var activeSession: Session? {
        didSet {
            // Only the nil ↔ non-nil transition (browser ↔ camera view) matters here — most
            // writes (a fresh capture recorded, resuming the same session) replace `activeSession`
            // with another non-`nil` value and shouldn't touch the AI panel's dock state at all.
            guard (oldValue == nil) != (activeSession == nil) else { return }
            syncAssistantDockStateForCameraMode()
        }
    }
    /// Set by `endActiveSession()` right before clearing `activeSession`, so
    /// `ProjectsBrowserView.onAppear` can re-select that same session (showing its now-updated
    /// history) instead of landing on the project's session list with nothing selected. Consumed
    /// (set back to `nil`) the moment it does.
    var lastEndedSessionID: Session.ID?
    /// Set by `newProject()`/File → "New Project…" to ask `ProjectsBrowserView` to open its
    /// creation sheet as soon as it (re)appears — consumed (set back to `false`) the moment it
    /// does. `newProject()` itself doesn't create anything; the sheet collects a name first (see
    /// `NewProjectSheet` — creating a project always requires one now, there's no more
    /// unnamed-until-later project).
    var isCreatingNewProjectRequested = false
    /// Same idea as `isCreatingNewProjectRequested`, for the Home page's "Quick Start" sheet
    /// instead — set by `requestQuickStart()` (the Project menu's "Quick Start…" item).
    var isQuickStartRequested = false
    /// Same idea again, for "Project → Show All Projects" — jumps straight to the top-level
    /// Projects list rather than wherever the browser would otherwise reopen (the active
    /// project's own page, if any).
    var isShowingAllProjectsRequested = false
    /// Set by "Equipment → View" — opens the Equipment list page.
    var isShowingEquipmentRequested = false
    /// Set by "Equipment → Add New" — opens the Equipment list page with its "New System…" sheet
    /// already showing, rather than requiring a second click once there.
    var isAddingNewEquipmentRequested = false
    /// Same idea as `isShowingAllProjectsRequested`, for "Project → Show Gallery" — jumps straight
    /// to every elaborated image across every active project, regardless of what was showing.
    var isShowingGalleryRequested = false

    /// "Project → Quick Start…" — returns to the Projects browser (if a session was running) and
    /// asks it to open the Quick Start sheet immediately, the same starting point as the Home
    /// page's own "Quick Start" toolbar button.
    func requestQuickStart() {
        activeProject = nil
        activeSession = nil
        isQuickStartRequested = true
    }

    /// Makes `session` (within `project`) the destination for future captures, and — since a
    /// non-`nil` `session` becomes `activeSession` — what `RootView` shows the camera UI for
    /// (running it). Passing `session: nil` stays in the browser: with a non-`nil` `project` that
    /// just sets which project new sessions/location edits apply to by default; `project: nil`
    /// (e.g. `ContentView`'s "Switch Project" action, or the File menu) drops that too.
    func setActive(project: Project?, session: Session?) {
        activeProject = project
        activeSession = session
    }

    /// Stops running the active session and returns to the Projects browser — but, unlike
    /// `setActive(project:nil, session:nil)`, keeps `activeProject` set, so the browser reopens
    /// with that same project (and, via `lastEndedSessionID`, that same session's now-updated
    /// history) already showing instead of the top of the project list. What the camera view's
    /// breadcrumb goes to when the *session* name is pressed.
    func endActiveSession() {
        lastEndedSessionID = activeSession?.id
        activeSession = nil
    }

    /// What the camera view's breadcrumb goes to when the *project* name (not the session name)
    /// is pressed — same as `endActiveSession()` in that it keeps `activeProject` and drops
    /// `activeSession`, but deliberately doesn't set `lastEndedSessionID`, so the browser lands on
    /// the project's own Detail page rather than jumping straight into this session's History.
    func showProjectDetail() {
        activeSession = nil
    }

    /// "Project → Show All Projects" — leaves camera mode if running, and asks the browser to jump
    /// straight to the top-level Projects list regardless of whatever project/session was active.
    func showAllProjects() {
        activeSession = nil
        isShowingAllProjectsRequested = true
    }

    /// "Equipment → View" — leaves camera mode if running, and asks the browser to open the
    /// Equipment list page.
    func showEquipmentList() {
        activeSession = nil
        isShowingEquipmentRequested = true
    }

    /// "Project → Show Gallery" — leaves camera mode if running, and asks the browser to open the
    /// Gallery page (every elaborated image across every active project).
    func showGallery() {
        activeSession = nil
        isShowingGalleryRequested = true
    }

    /// "Equipment → Add New" — same as `showEquipmentList()`, but also opens the "New System…"
    /// sheet immediately rather than requiring a second click once there.
    func showAddNewEquipment() {
        activeSession = nil
        isAddingNewEquipmentRequested = true
    }

    /// `true` once there's a session immediately after the active one in `activeProject.sessions`
    /// (list order — the same order the browser shows them in) — callers use this to disable
    /// "Open Next Session" rather than have it silently do nothing.
    var hasNextSession: Bool {
        guard let project = activeProject, let session = activeSession,
              let index = project.sessions.firstIndex(where: { $0.id == session.id })
        else { return false }
        return index + 1 < project.sessions.count
    }

    /// Same as `hasNextSession`, the other direction — "Open Previous Session" used to not exist
    /// at all, only "Open Next Session" did, so there was no way back to a session already
    /// stepped past without a trip back through the browser.
    var hasPreviousSession: Bool {
        guard let project = activeProject, let session = activeSession,
              let index = project.sessions.firstIndex(where: { $0.id == session.id })
        else { return false }
        return index > 0
    }

    /// Moves straight to the next session in the active project without a trip back through the
    /// browser — a no-op (not a wraparound) once there is none; see `hasNextSession`.
    func openNextSession() {
        guard let project = activeProject, let session = activeSession,
              let index = project.sessions.firstIndex(where: { $0.id == session.id }),
              index + 1 < project.sessions.count
        else { return }
        activeSession = project.sessions[index + 1]
    }

    /// Same as `openNextSession()`, the other direction; see `hasPreviousSession`.
    func openPreviousSession() {
        guard let project = activeProject, let session = activeSession,
              let index = project.sessions.firstIndex(where: { $0.id == session.id }),
              index > 0
        else { return }
        activeSession = project.sessions[index - 1]
    }

    /// Adds a new session to the active project — the same "New Session" default name
    /// `ProjectDetailPane`'s own "Add Session" button uses — without leaving whatever's currently
    /// running; the new session shows up once the browser is reopened, it doesn't become active
    /// on its own.
    @discardableResult
    func createSessionInActiveProject() -> Session? {
        guard let project = activeProject else { return nil }
        let session = Session.newSession(name: "New Session")
        guard let updated = try? projectsLibrary.addSession(session, to: project) else { return nil }
        activeProject = updated
        return session
    }

    /// Deletes the active session (there's nothing left to run) and returns to the browser on the
    /// same project, same as `endActiveSession()`.
    func deleteActiveSession() {
        guard let project = activeProject, let session = activeSession else { return }
        try? projectsLibrary.deleteSession(session.id, in: project)
        activeProject = projectsLibrary.projects.first { $0.id == project.id }
        activeSession = nil
    }

    /// "File → New Project…" — returns to the Projects browser (if a session was running) and
    /// asks it to open its creation sheet immediately, the same starting point as the
    /// toolbar/sidebar "New Project" button but for someone who'd rather use the menu bar.
    func newProject() {
        activeProject = nil
        activeSession = nil
        isCreatingNewProjectRequested = true
    }

    /// Set by `quickStart(with:)` when no camera is connected yet — `applyAcquisitionPreset`
    /// itself silently no-ops without one (see its own guard), so without this the whole point of
    /// picking a Quick Start target (its recommended starting gain/exposure and Live
    /// Stack/Lucky Imaging mode) would be lost the moment the user still had to go connect a
    /// camera afterward, which Quick Start's entire premise requires. Applied and cleared by
    /// `connect(to:)` the next time a camera actually connects.
    var pendingAcquisitionPreset: AcquisitionPreset?

    /// The Projects Home page's "Quick Start" — skips manually creating a project and session for
    /// a one-off "just go observe Saturn tonight" outing: creates both (named after `target`, its
    /// summary as the goal, `target`'s own name as the session's one planned object), applies its
    /// recommended camera setup (immediately if a camera's already connected, otherwise as soon as
    /// one does — see `pendingAcquisitionPreset`), and opens the camera view — where camera
    /// selection itself still happens exactly as it always does, Quick Start doesn't skip that.
    @discardableResult
    func quickStart(with target: AcquisitionTarget) -> Session {
        AppLog.shared.log("Quick Start: \(target.name)")
        var project = Project.newProject(name: target.name, goal: target.summary)
        let session = Session.newSession(name: target.name, goal: target.summary, plannedObjects: [target.name])
        project.sessions = [session]
        do {
            try projectsLibrary.save(project)
        } catch {
            // Doesn't actually exist on disk — entering the camera view for it anyway (below)
            // would look like a working session that quietly loses everything on relaunch.
            lastErrorMessage = "Couldn't create the Quick Start project — \(error.localizedDescription)"
            return session
        }

        let preset = target.recommendedPreset(telescope: telescopeProfile)
        if connectedCamera != nil {
            applyAcquisitionPreset(preset)
        } else {
            pendingAcquisitionPreset = preset
        }

        setActive(project: project, session: session)
        return session
    }

    /// The Insights page's "try this next" suggestions come from `ObservedObjectCatalog`, a wider
    /// list (the full bundled Messier/bright-star catalog plus every planet) than
    /// `AcquisitionTarget.all`'s own small curated set — so a suggestion doesn't always have a
    /// matching target with a recommended preset. Uses `quickStart(with:)` when one does; falls
    /// back to a plain project/session named after `objectName` (no recommended camera setup to
    /// apply, since there's no target to derive one from) otherwise.
    @discardableResult
    func quickStart(forObjectName objectName: String) -> Session {
        if let target = AcquisitionTarget.all.first(where: { $0.name == objectName }) {
            return quickStart(with: target)
        }
        AppLog.shared.log("Quick Start: \(objectName)")
        var project = Project.newProject(name: objectName, goal: "Observe \(objectName)")
        let session = Session.newSession(name: objectName, goal: "Observe \(objectName)", plannedObjects: [objectName])
        project.sessions = [session]
        do {
            try projectsLibrary.save(project)
        } catch {
            lastErrorMessage = "Couldn't create the Quick Start project — \(error.localizedDescription)"
            return session
        }
        setActive(project: project, session: session)
        return session
    }

    /// "Recall the parameters used in a previous action" — applies `preset` (a past
    /// `CaptureRecord.preset` snapshot) to speed up setting up a similar shot again, exactly the
    /// same immediate-or-pending shape `quickStart(with:)` already uses for its own recommended
    /// preset: right away if a camera's already connected, otherwise held until the next
    /// `connect(to:)` actually applies it.
    func recallParameters(_ preset: AcquisitionPreset) {
        AppLog.shared.log("Recalled parameters: \(preset.summaryLine)")
        if connectedCamera != nil {
            applyAcquisitionPreset(preset)
        } else {
            pendingAcquisitionPreset = preset
        }
    }

    private var serRecordingURL: URL?

    init(
        projectStore: ProjectStore = ProjectStore(), locationProvider: CoreLocationProvider = CoreLocationProvider(),
        ollamaPlanner: OllamaPlanner = CameraManager.makePlanner(),
        aiChatLibrary: AIChatLibrary = AIChatLibrary(),
        equipmentLibrary: EquipmentLibrary = EquipmentLibrary()
    ) {
        self.projectStore = projectStore
        self.locationProvider = locationProvider
        self.projectsLibrary = ProjectsLibrary(store: projectStore)
        self.ollamaPlanner = ollamaPlanner
        self.aiChatLibrary = aiChatLibrary
        self.equipmentLibrary = equipmentLibrary
        AstronomyKnowledgeBase.ensureDefaultsExist()
        refreshCameraList()
        // `activeProject` starts `nil` on every launch, full stop — there's no "resume last
        // project" persistence, deliberately: it's what makes the Projects browser the app's
        // actual landing screen every time (see `RootView`), the same "session state always
        // starts fresh" philosophy `AppSettings`'s doc comment already applies to
        // `isLiveStackingEnabled`/`darkFrame`/etc.
    }

    /// Fetches a GPS fix and saves it on whichever of `activeSession`/`activeProject` (session
    /// takes precedence — a project's own `location` is meant as more of a "usual site" default,
    /// see `GeoLocation`'s doc comment) is currently active. A no-op with no active project.
    func useCurrentLocation(for project: Project, session: Session?) {
        locationProvider.requestCurrentLocation { [weak self] location in
            guard let self, let location else { return }
            self.applyLocation(location, to: project, session: session)
        }
    }

    /// Sets a hand-entered location (see `GeoLocation.manual`) on `session` if given, else on
    /// `project` itself. Returns `false` (and does nothing) for an out-of-range latitude/longitude.
    @discardableResult
    func setManualLocation(for project: Project, session: Session?, latitude: Double, longitude: Double, name: String?) -> Bool {
        guard let location = GeoLocation.manual(latitude: latitude, longitude: longitude, name: name) else { return false }
        applyLocation(location, to: project, session: session)
        return true
    }

    /// Shared by both location setters above — persists `location` on `session` (if given) or
    /// `project`, via `ProjectsLibrary` (not `setActive`: setting a location must never itself
    /// open a project into the camera view, so this only mirrors the edit into
    /// `activeProject`/`activeSession` when `project` already happens to be the open one).
    private func applyLocation(_ location: GeoLocation, to project: Project, session: Session?) {
        var updated = project
        if let session, let index = updated.sessions.firstIndex(where: { $0.id == session.id }) {
            updated.sessions[index].location = location
        } else {
            updated.location = location
        }
        do {
            try projectsLibrary.save(updated)
        } catch {
            lastErrorMessage = String(describing: error)
            return
        }
        guard activeProject?.id == updated.id else { return }
        activeProject = updated
        if let session { activeSession = updated.sessions.first(where: { $0.id == session.id }) }
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
        resetCaptureSessionState()
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
            if let gainCap = controlCap(ASI_GAIN, in: caps), gainCap.isWritable {
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
            AppLog.shared.log("Connected to \(camera.name)")

            // A Quick Start picked before any camera was connected left its recommended setup
            // with nothing to apply to yet — `applyAcquisitionPreset` itself silently no-ops
            // without a connected camera. Apply it now that one just did, then forget it (a later
            // reconnect shouldn't replay a Quick Start setup from an earlier session).
            if let pendingAcquisitionPreset {
                applyAcquisitionPreset(pendingAcquisitionPreset)
                self.pendingAcquisitionPreset = nil
            }
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
                // Was 2s — temperature/dropped-frame counts don't change fast enough to need
                // that cadence, and this loop runs continuously the entire time a camera is
                // connected (not just while actively streaming/previewing), so it's a genuine
                // always-on background cost. 5s halves the wake-ups with no real loss of freshness.
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Subscribes to `engine`'s frame stream and starts the video-capture poll loop in
    /// `imageType` (RAW8 by default; Milestone 4 adds RAW16 for higher dynamic range).
    private func startPreview(using engine: CaptureEngine, imageType: ASI_IMG_TYPE = ASI_IMG_RAW8) async {
        isLiveViewActive = true
        let stream = await engine.frames(
            onCameraRemoved: { [weak self] in
                Task { @MainActor in self?.handleCameraRemoved() }
            },
            onStreamError: { [weak self] error in
                Task { @MainActor in self?.handleStreamError(error) }
            }
        )
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

    /// The one place a live capture pipeline restart actually happens — `changeImageType`/
    /// `changeCaptureROI` both funnel their `engine.stop()` → `...` → `startPreview()` sequence
    /// through this instead of each spawning its own untracked `Task`. Awaits any restart already
    /// in flight before starting this one, so two requests fired back-to-back with no `await`
    /// between them on the caller's side (`applyAcquisitionPreset` changing both image type *and*
    /// ROI at once, say — exactly what "create a new session" does via `quickStart(with:)` while
    /// a camera is already connected) apply strictly one at a time instead of interleaving.
    ///
    /// Without this, two overlapping restarts raced: `CaptureEngine.startStreaming` no-ops via
    /// `guard !isRunning else { return }` if the other restart's own `startStreaming` already won,
    /// so the *later* restart's `frames()` call still replaces the actor's stream `continuation`
    /// even though no new poll loop is feeding it — leaving `frameConsumerTask` (whichever
    /// restart's `startPreview` happened to finish last) iterating a stream nothing yields to
    /// anymore, with `isLiveViewActive`/`connectionState` still reporting `.streaming`. Nothing
    /// throws in that path, so the live view just goes silently stale with no in-app recovery —
    /// reported as "the camera hangs and I need to reset" when starting a new session.
    /// True whenever a capture-pipeline restart is queued or actually in flight — surfaced so the
    /// UI (the ROI picker/custom-ROI Apply button) can disable itself for that stretch instead of
    /// letting the user queue up several more restarts before the first one settles. Each restart
    /// briefly tears the live feed down and rebuilds it (`engine.stop()` → reconfigure →
    /// `startPreview`), so firing several back-to-back — nothing previously stopped that — showed
    /// up as the live preview repeatedly flashing/tearing until the whole backlog finally drained,
    /// "I need to restart the app because it continues to flash between rows."
    private(set) var isRestartingCapturePipeline = false
    /// Bumped on every `restartCapturePipeline` call — lets a restart tell, once it finishes,
    /// whether it was the *last* one queued (in which case it clears `isRestartingCapturePipeline`)
    /// or whether a newer one has since been queued behind it (in which case it leaves the flag
    /// alone — that newer restart will clear it once it, in turn, finishes).
    private var pipelineRestartGeneration = 0

    private func restartCapturePipeline(_ body: @escaping () async -> Void) {
        let previous = pipelineRestartTask
        isRestartingCapturePipeline = true
        pipelineRestartGeneration += 1
        let generation = pipelineRestartGeneration
        pipelineRestartTask = Task { [weak self] in
            await previous?.value
            await body()
            if self?.pipelineRestartGeneration == generation {
                self?.isRestartingCapturePipeline = false
            }
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
        restartCapturePipeline { [weak self] in
            await engine.stop()
            await self?.startPreview(using: engine, imageType: imageType)
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
    /// `CaptureEngine.setROI`'s `binning` — 1 (off) or 2 (2×2 pixel binning). The deep-sky
    /// "trade resolution for SNR/frame-rate" toggle: averaging each 2×2 block of photosites into
    /// one output pixel quarters resolution but roughly quadruples per-pixel signal, which for a
    /// faint, noise-limited deep-sky target is usually the better trade than the extra detail a
    /// full-resolution frame would have shown anyway. Session state, not an `AppSettings`
    /// preference — same reasoning as `captureROIWidth`/`captureROIHeight` (a stale non-default
    /// value silently carrying over to a new, unrelated session would be a worse default than
    /// always starting unbinned).
    private(set) var captureBinning: Int = 1

    /// Requests a smaller-than-full-sensor capture region, and/or 2×2 pixel binning — ZWO cameras
    /// only (see `CaptureEngine.setROI`'s doc comment for why either is worth doing at all: a
    /// smaller ROI genuinely increases achievable frame rate, and binning genuinely increases
    /// per-pixel SNR, since less data has to be read off the sensor per frame either way — the
    /// same "small ROI, high FPS" technique real planetary/lunar lucky-imaging tools (FireCapture,
    /// SharpCap) rely on, plus the "bin for SNR" technique real deep-sky tools offer alongside
    /// it). `width`/`height` `nil` resets to the full (binned) sensor. `centerX`/`centerY`
    /// (binned-sensor pixel coordinates) place the ROI anywhere on the sensor — `nil` means
    /// centered on the sensor, which is what every caller except the Controls panel's own
    /// custom-ROI fields uses. Without the center-resolving logic here, a ROI always landed at the
    /// sensor's top-left corner (`ASISetStartPos` was never called at all) regardless of where the
    /// actual target sat — see `ROIGeometry.startPosition`'s doc comment. No-op for a webcam/iPhone
    /// source, where there's no `ASISetROIFormat` equivalent — frame size there is whatever the
    /// selected `AVCaptureDevice.Format` already is.
    func changeCaptureROI(width: Int?, height: Int?, centerX: Int? = nil, centerY: Int? = nil, binning: Int = 1) {
        guard let engine = captureEngine, connectedCamera != nil else { return }
        // No-op guard (matching `changeImageType`'s) — without it, requesting the exact same ROI/
        // binning already in effect (e.g. "Reset to Default" when the ROI is already full-sensor,
        // unbinned) still tore the live stream down and rebuilt it: a visible flash/CPU spike and
        // a brief window of every `currentFrame == nil`-gated control going disabled, for no
        // actual change.
        guard width != captureROIWidth || height != captureROIHeight
            || centerX != captureROICenterX || centerY != captureROICenterY
            || binning != captureBinning else { return }
        frameConsumerTask?.cancel()
        currentFrame = nil
        currentImage = nil
        captureROIWidth = width
        captureROIHeight = height
        captureROICenterX = width != nil ? centerX : nil
        captureROICenterY = height != nil ? centerY : nil
        captureROIAppliedStartX = nil
        captureROIAppliedStartY = nil
        captureBinning = binning
        let imageType = selectedImageType
        restartCapturePipeline { [weak self] in
            await engine.stop()
            await engine.setROI(width: width, height: height, centerX: centerX, centerY: centerY, binning: binning)
            await self?.startPreview(using: engine, imageType: imageType)
            if width != nil, height != nil, let applied = try? await engine.currentStartPosition() {
                self?.captureROIAppliedStartX = applied.x
                self?.captureROIAppliedStartY = applied.y
            }
        }
    }

    /// "Bin 2×2 (Deep Sky)" — the Controls panel's dedicated binning toggle. A thin
    /// `changeCaptureROI` call that keeps whatever ROI is already set (most deep-sky sessions want
    /// the full binned sensor, i.e. no custom ROI at all, but this doesn't force that) and just
    /// changes `binning` — kept separate from `changeCaptureROI` itself since binning is a plain
    /// on/off switch in the UI, not a width/height/center picker.
    /// `ASI_HARDWARE_BIN` (a generic on/off camera control, toggled from the dynamic controls
    /// list — see `controlRow`'s `case ASI_HARDWARE_BIN` in `ControlsPanelView`) and this ROI
    /// binning are two independent, uncoordinated binning mechanisms. With both active, the
    /// sensor delivers data already reduced once on-chip, and `ASISetROIFormat`'s own `binning`
    /// then averages that again — the result no longer has a clean, period-2 Bayer mosaic aligned
    /// the way `camera.bayerPattern` still assumes, but the debayer step (`Debayer`/
    /// `MetalFrameRenderer`) feeds it through unchanged, as if it were still raw unbinned data.
    /// That misaligned demosaic is exactly the scattered green/blue dot artifact reported when
    /// "Hardware Bin and 2×2 are both set." Rather than trying to make the debayer step handle
    /// doubly-binned data correctly (lossy/ambiguous), enforce a single binning source: turning
    /// this ROI binning on turns Hardware Bin off first.
    func changeCaptureBinning(_ binning: Int) {
        if binning > 1, let hardwareBinCap = controlCap(ASI_HARDWARE_BIN, in: controls),
           (controlValues[hardwareBinCap.id]?.value ?? 0) != 0 {
            setControlValue(ASI_HARDWARE_BIN, value: 0)
        }
        changeCaptureROI(width: captureROIWidth, height: captureROIHeight, centerX: captureROICenterX, centerY: captureROICenterY, binning: binning)
    }

    /// The other half of `changeCaptureBinning`'s invariant: turning Hardware Bin on turns this
    /// ROI binning off first, so the two mechanisms are never active together. See
    /// `changeCaptureBinning`'s doc comment for why.
    func setHardwareBinEnabled(_ enabled: Bool) {
        if enabled, captureBinning > 1 {
            changeCaptureBinning(1)
        }
        setControlValue(ASI_HARDWARE_BIN, value: enabled ? 1 : 0)
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

    /// Looks up a specific ASI control's capabilities by type — this exact `first(where:)` lookup
    /// used to be duplicated across nine separate call sites (`applyPlanetaryPreset`,
    /// `applyAcquisitionPreset`, `currentAcquisitionPreset`, `resetToDefaultConfiguration`, the
    /// bias/dark calibration flow, and the initial-connect gain default). Takes `caps` explicitly
    /// rather than defaulting to `self.controls` — one call site (right after a fresh ZWO connect)
    /// needs to look up a just-read-from-the-SDK array before it's been assigned to `controls` yet.
    private func controlCap(_ type: ASI_CONTROL_TYPE, in caps: [ZWOControlCaps]) -> ZWOControlCaps? {
        caps.first { $0.controlType.rawValue == type.rawValue }
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

        if let exposureCap = controlCap(ASI_EXPOSURE, in: controls), exposureCap.isWritable {
            let microseconds = Int(preset.startingExposureSeconds(for: telescopeProfile) * 1_000_000)
            setControlValue(ASI_EXPOSURE, value: min(max(microseconds, exposureCap.minValue), exposureCap.maxValue))
        }
        if let gainCap = controlCap(ASI_GAIN, in: controls), gainCap.isWritable {
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
            changeCaptureROI(width: preset.roiWidth, height: preset.roiHeight, binning: preset.binning ?? 1)

            if let exposureSeconds = preset.exposureSeconds,
               let exposureCap = controlCap(ASI_EXPOSURE, in: controls), exposureCap.isWritable {
                let microseconds = Int(exposureSeconds * 1_000_000)
                setControlValue(ASI_EXPOSURE, value: min(max(microseconds, exposureCap.minValue), exposureCap.maxValue))
            }
            if let gain = preset.gain,
               let gainCap = controlCap(ASI_GAIN, in: controls), gainCap.isWritable {
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
        // `?? []` covers a preset saved before "Filters" existed — same reasoning as
        // `isMeshDriftCorrectionEnabled` above, an older preset simply had none active.
        activeFilterSelections = preset.selectedFilters ?? []
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
        let gain = controlCap(ASI_GAIN, in: controls).flatMap { controlValues[$0.id]?.value }
        let exposureMicroseconds = controlCap(ASI_EXPOSURE, in: controls).flatMap { controlValues[$0.id]?.value }
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
            serDurationSeconds: nil,
            selectedFilters: activeFilterSelections.isEmpty ? nil : activeFilterSelections,
            binning: captureBinning
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

    /// "File → Save As Project…" — packages the active project's whole folder (its metadata, every
    /// session, every capture file and thumbnail) into one `.zip` a user can hand to someone else,
    /// unlike `ProjectStore.save`'s own per-edit `project.json`-only write. A no-op with no active
    /// project, the same "nothing to act on" reasoning `exportCurrentFrame` already applies for
    /// `currentFrame == nil`. Archiving runs off the main actor (`ProjectArchive` shells out to
    /// `/usr/bin/ditto` and waits for it) so a large project doesn't freeze the UI while zipping.
    func saveActiveProjectAsFile() {
        guard let project = activeProject else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = "\(project.name).zip"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let projectFolder = self.projectStore.projectFolderURL(for: project)
            Task.detached(priority: .utility) {
                do {
                    try ProjectArchive.archive(projectFolder: projectFolder, to: url)
                } catch {
                    await MainActor.run { self.lastErrorMessage = String(describing: error) }
                }
            }
        }
    }

    /// "File → Load Project…" — the other half of `saveActiveProjectAsFile()`: unpacks a `.zip`
    /// (this app's own export, or one from another user/machine sharing a project) into a
    /// brand-new project in this library. `ProjectArchive.importProject` always assigns a fresh
    /// `id`/`folderName`, so this can never silently collide with or overwrite an existing project
    /// — including re-importing the same file twice.
    func loadProjectFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let projectsRoot = self.projectStore.rootDirectory
            Task.detached(priority: .utility) {
                do {
                    let imported = try ProjectArchive.importProject(from: url, into: projectsRoot)
                    await MainActor.run {
                        self.projectsLibrary.reload()
                        self.setActive(project: imported, session: nil)
                    }
                } catch {
                    await MainActor.run { self.lastErrorMessage = String(describing: error) }
                }
            }
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
        if let gainCap = controlCap(ASI_GAIN, in: controls), gainCap.isWritable {
            setControlValue(ASI_GAIN, value: min(max(5, gainCap.minValue), gainCap.maxValue))
        }
        if let exposureCap = controlCap(ASI_EXPOSURE, in: controls), exposureCap.isWritable {
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
        // A real frame just arrived — in continuous streaming mode that's also exactly when the
        // camera's own internal cycle starts exposing the next one (see `liveViewFrameStartDate`'s
        // doc comment), so this is the reset point for "time until the next frame" countdown.
        if !isCapturingExposure, let liveExposure = currentLiveExposureSeconds,
           liveExposure >= Self.liveViewCountdownMinimumDuration {
            liveViewFrameStartDate = Date()
            liveViewFrameExpectedDuration = liveExposure
        } else {
            liveViewFrameStartDate = nil
            liveViewFrameExpectedDuration = nil
        }

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
        updateLiveStackSigmaClippingKappaSigma(processed)

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

        if isLiveStackingEnabled, !effectiveLiveStackPaused, liveStackAutoStretchTask == nil {
            let restretchNow = Date()
            if lastLiveStackAutoStretchDate == nil
                || restretchNow.timeIntervalSince(lastLiveStackAutoStretchDate!) >= Self.liveStackAutoStretchInterval {
                lastLiveStackAutoStretchDate = restretchNow
                // The averaged frame, not the raw one just ingested — on the CPU path `currentFrame`
                // already is that average (see just above); on the GPU path the accumulation lives
                // entirely inside `MetalFrameRenderer`, reachable only via the same
                // `gpuAccumulatedFrameProvider` readback `frameForExport()` uses. This one texture
                // readback stays on the main actor (a single `getBytes` + format pass, not the
                // expensive part) — everything that follows is plain CPU work on the resulting
                // `CapturedFrame` value, with no actor affinity, so it's safe to detach.
                if let stackedFrame = usesCPUStack ? currentFrame : gpuAccumulatedFrameProvider?(selectedImageType) {
                    let isContinuous = isLiveStackAutoStretchContinuous
                    let isGPUControlsEnabled = gpuControls.isEnabled
                    let isAutoColorBalanceEnabled = isLiveStackAutoColorBalanceEnabled
                    let isColorCamera = connectedCamera?.isColorCamera ?? false
                    let bayerPattern = connectedCamera?.bayerPattern ?? ASI_BAYER_RG
                    let aggressiveness = liveStackStretchAggressiveness
                    let blackPointOffset = liveStackAutoBlackPointOffset
                    // Up to 4 full-frame CPU passes (the base histogram, the dynamic-stretch
                    // histogram, and — worst case — both a mono and a per-channel histogram for
                    // Auto Color Balance) plus, on a real astro sensor, several megapixels each:
                    // this was previously all synchronous on `@MainActor`, once every 5 seconds,
                    // for as long as Live Stack ran — a real periodic multi-second beachball
                    // ("every time it cycles the cursor goes into wait"), not a one-off. Detached
                    // so it can take however long it needs without blocking the run loop.
                    liveStackAutoStretchTask = Task.detached(priority: .utility) { [weak self] in
                        let histogram = HistogramComputer.histogram(for: stackedFrame)
                        let auto = DisplayStretch.autoStretch(histogram: histogram)

                        var dynamicResult: LiveStackDynamicStretch.Result?
                        var channelPeaks: (red: Float, green: Float, blue: Float)?
                        if isContinuous, isGPUControlsEnabled {
                            dynamicResult = LiveStackDynamicStretch.compute(
                                histogram: histogram, aggressiveness: aggressiveness, blackPointOffset: blackPointOffset
                            )
                            if isAutoColorBalanceEnabled, isColorCamera,
                               let channels = HistogramComputer.channelHistograms(for: stackedFrame, isColorCamera: true, bayerPattern: bayerPattern) {
                                channelPeaks = (
                                    Self.peakFraction(channels.red), Self.peakFraction(channels.green), Self.peakFraction(channels.blue)
                                )
                            }
                        }
                        await self?.applyLiveStackAutoStretch(auto: auto, dynamicResult: dynamicResult, channelPeaks: channelPeaks)
                    }
                }
            }
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
            // Was 250ms — bumped alongside Focus Assist/Planetary Tracking's own floors (see
            // their doc comments) as a modest, easily-reverted energy tweak: this Vision-based
            // pass plus a GPU/CPU render every cycle is real continuous work for as long as the
            // feature's enabled, and streak masking specifically doesn't need to react faster
            // than ~2.5x/sec to still feel live.
            try? await Task.sleep(for: .milliseconds(400))
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
    /// Shared "begin a blocking single-exposure capture" preamble — `captureSingleExposure`/
    /// `captureDarkFrame`/`captureFlatFrame` each duplicated this exact ~7-line sequence
    /// (stop live view's frame consumer, mark the exposure as in-progress with its start time/
    /// duration for the UI's countdown, clear any stale error) plus a matching `defer` resetting
    /// those same three properties back.
    private func beginBlockingCapture(seconds: Double) {
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        isLiveViewActive = false
        isCapturingExposure = true
        capturingExposureStartDate = Date()
        capturingExposureDurationSeconds = seconds
        lastErrorMessage = nil
    }

    private func endBlockingCapture() {
        isCapturingExposure = false
        capturingExposureStartDate = nil
        capturingExposureDurationSeconds = nil
    }

    func captureDarkFrame(seconds: Double) async {
        guard let camera = connectedCamera else { return }
        beginBlockingCapture(seconds: seconds)
        // Unlike `captureSingleExposure` (whose own doc comment says explicitly: stays paused so
        // the user can inspect that still frame, "call `resumeLiveView()` to go back"), nothing
        // about a dark/flat calibration frame is meant to be inspected on screen — it's consumed
        // straight into `calibrationLibrary`. With no UI anywhere offering a "Resume Live View"
        // button next to this capture (unlike single exposure's), leaving live view paused here
        // was a straight freeze: the preview goes blank/stuck on the last frame and stays that
        // way forever once this returns.
        defer { endBlockingCapture(); resumeLiveView() }

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
            let gain = controlCap(ASI_GAIN, in: controls).flatMap { controlValues[$0.id]?.value }
            calibrationLibrary.addDark(frame, exposureMicroseconds: exposureMicroseconds, gain: gain)
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
        beginBlockingCapture(seconds: seconds)
        defer { endBlockingCapture() }

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
            let gain = controlCap(ASI_GAIN, in: controls).flatMap { controlValues[$0.id]?.value }
            calibrationLibrary.addFlat(frame, exposureMicroseconds: exposureMicroseconds, gain: gain)
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
            let minimumMicroseconds = controlCap(ASI_EXPOSURE, in: controls).map { max($0.minValue, 32) } ?? 32
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
        luckyBurstGeneration += 1
    }

    /// Bumped by `startLuckyImagingBurst`/`startLiveCapture`/`discardLuckyImagingSession` —
    /// `startLiveCapture`'s own delayed timer checks this before acting, so a *stale* timer left
    /// over from a Live Capture burst that was superseded (a Lucky Imaging burst started before
    /// the timer fired, or Live Capture tapped again) can't reach into whatever burst is running
    /// now and stomp on it. Without this, the stale timer still fired `isLuckyImagingPaused =
    /// true` on the new session, permanently blocking `ingest`'s frame-adding guard before that
    /// session ever reached its own target frame count — the Lucky Imaging UI's "Capturing…"
    /// state then never clears, looking exactly like a hang.
    private var luckyBurstGeneration = 0

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
        isLiveCaptureBurstActive = false
        luckyBurstGeneration += 1
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

    // MARK: - Live Capture (iPhone-Live-Photo-style burst + pick)

    /// True for exactly `startLiveCapture`'s `durationSeconds` — `LiveCaptureBrowserView` shows a
    /// "Capturing…" state for as long as this is true, then flips to the frame-picker once it
    /// isn't. Distinct from `LuckyImagingSession.isComplete` (frame-count-based) since this burst
    /// is stopped by elapsed time, not a target frame count — see `startLiveCapture`'s own doc
    /// comment for why.
    private(set) var isLiveCaptureBurstActive = false

    /// Buffers every incoming live frame for `durationSeconds` (default 3, matching an iPhone
    /// Live Photo), then lets the user scrub through the whole burst afterward
    /// (`LiveCaptureBrowserView`) and export whichever single frame actually looked sharpest —
    /// rather than betting on the timing of one manual capture. Reuses `LuckyImagingSession`
    /// exactly as-is (the same in-memory scored-frame buffer `ingest` already knows how to feed)
    /// — the only real difference from an actual Lucky Imaging burst is *what* stops it: elapsed
    /// time (`isLuckyImagingPaused = true` once the timer fires) instead of a target frame count,
    /// so `targetFrameCount` here is just a generous cap never expected to be hit first.
    ///
    /// Shares `luckyImagingSession` with the Lucky Imaging feature — starting one while the other
    /// already has a burst in flight replaces it, same as starting a second Lucky Imaging burst
    /// would. The UI is expected to disable whichever trigger isn't relevant while the other's
    /// burst is active/its frames are still being browsed, rather than this guarding it itself.
    func startLiveCapture(durationSeconds: Double = 3) {
        luckyImagingSession = LuckyImagingSession(targetFrameCount: 100_000)
        isLuckyImagingPaused = false
        isLiveCaptureBurstActive = true
        luckyBurstGeneration += 1
        let generation = luckyBurstGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(durationSeconds))
            guard let self, self.luckyBurstGeneration == generation else { return }
            self.isLuckyImagingPaused = true
            self.isLiveCaptureBurstActive = false
        }
    }

    /// Shows one specific frame from the current Live Capture burst, in the order it was actually
    /// captured (unlike `showLuckyImagingFrame(atSortedIndex:)`, which indexes the
    /// sharpest-first ranking) — a scrubber naturally wants chronological order, the same way
    /// scrubbing an iPhone Live Photo does.
    func showLiveCaptureFrame(atIndex index: Int) {
        guard let session = luckyImagingSession else { return }
        let frames = session.scoredFrames
        guard frames.indices.contains(index) else { return }
        currentFrame = frames[index].frame
        frameID &+= 1
        refreshCurrentImage()
        // `refreshCurrentImage()` only actually renders `currentImage` in CPU mode (see its own
        // doc comment) — fine for the live per-frame stream (`MetalPreviewView` reads
        // `currentFrame` directly in GPU mode, never `currentImage`), but `LiveCaptureBrowserView`
        // has its own separate preview pane that only ever reads `currentImage`, so browsing a
        // captured burst's frames in GPU mode left that preview stuck on a loading spinner
        // forever — confirmed live (GPU mode active, a frame selected and scored, preview still
        // black). This is exactly the kind of rare, user-initiated action `currentDisplayImage()`'s
        // own on-demand fallback already exists for (export, polar alignment); rendering
        // unconditionally here, once per scrub (not once per live frame), costs nothing like what
        // makes `refreshCurrentImage()` skip it for the streaming path.
        if useMetalRenderer, let frame = currentFrame, let camera = connectedCamera {
            currentImage = renderedCurrentImage(frame: frame, camera: camera)
        }
    }

    // MARK: - Export

    /// Writes `currentFrame`/`currentImage` in the requested format: FITS carries the raw
    /// (pre-debayer) sensor data — the standard way capture software archives what the sensor
    /// actually saw; PNG/TIFF export the already-debayered, stretched display image for quick
    /// sharing.
    ///
    /// While a project/session is active, this saves straight into that session's own folder
    /// with an auto-generated `<object>-<date>-<time>` name — no `NSSavePanel` folder picker at
    /// all. The app already organizes every capture by project/session; asking the user to also
    /// choose a folder here was a redundant step, not meaningful control, and it's exactly the
    /// session folder `recordActiveSessionCapture` copies the file into anyway right afterward.
    /// With no active session there's nowhere "already organized" to save into, so this falls
    /// back to the old save-panel behavior (still with the same smarter default filename).
    func exportCurrentFrame(as kind: ExportKind) {
        guard currentFrame != nil else { return }
        let ext = Self.fileExtension(for: kind)
        if let project = activeProject, let session = activeSession {
            let filename = Self.autoCaptureFilename(object: session.plannedObjects.first, extension: ext)
            let folder = projectStore.sessionFolderURL(for: session, in: project)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            finishExport(kind: kind, to: folder.appendingPathComponent(filename))
            return
        }

        let panel = NSSavePanel()
        switch kind {
        case .fits: panel.allowedContentTypes = [UTType(filenameExtension: "fits") ?? .data]
        case .png: panel.allowedContentTypes = [.png]
        case .tiff: panel.allowedContentTypes = [.tiff]
        }
        panel.nameFieldStringValue = Self.autoCaptureFilename(object: nil, extension: ext)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                self?.finishExport(kind: kind, to: url)
            }
        }
    }

    private static func fileExtension(for kind: ExportKind) -> String {
        switch kind {
        case .fits: return "fits"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    /// A default filename built from what's actually being captured — "M13-2026-08-15-213045.fits"
    /// — rather than a generic "capture.fits", used both when saving straight into a session
    /// folder (no dialog at all) and as the still-smarter default when a save panel is shown
    /// (no active session to organize into).
    static func autoCaptureFilename(object: String?, extension ext: String, date: Date = Date()) -> String {
        let trimmedObject = object?.trimmingCharacters(in: .whitespacesAndNewlines)
        let objectPart = (trimmedObject?.isEmpty == false ? trimmedObject : nil) ?? "capture"
        return "\(ProjectStore.sanitizeForFilename(objectPart))-\(autoCaptureFilenameDateFormatter.string(from: date)).\(ext)"
    }

    private static let autoCaptureFilenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// Bumped once per successful `exportCurrentFrame` — the only signal today that a capture
    /// actually happened, since pressing the capture button otherwise produces no visible/audible
    /// feedback at all. `PreviewView` observes this via `.onChange` to flash the preview and
    /// `NSSound.beep()` plays alongside it, matching what a physical shutter would communicate.
    private(set) var captureFeedbackTrigger = 0

    /// Gathers whatever in-memory data the actual write needs (cheap — already-decoded pixels,
    /// no disk I/O yet), then hands the disk write itself off to `Task.detached`. A full-detail
    /// TIFF or FITS of a multi-megapixel sensor frame can take long enough to encode that doing
    /// it inline on this (SwiftUI button action → `@MainActor`) call blocked the whole app and
    /// spun the pointer — this is the fix for that freeze. Bookkeeping that touches `@MainActor`
    /// state (`recordExport`, `recordActiveSessionCapture`, the shutter-feedback beep) resumes
    /// afterwards, back on the main actor.
    private func finishExport(kind: ExportKind, to url: URL) {
        switch kind {
        case .fits:
            guard let frame = frameForExport() else { return }
            let instrumentName = connectedCamera?.name ?? "skyformac"
            let isColorCamera = connectedCamera?.isColorCamera ?? false
            let bayerPattern = connectedCamera?.bayerPattern ?? ASI_BAYER_RG
            let image = imageForExport()
            runExport(url: url) {
                try FITSWriter.write(
                    frame: frame, instrumentName: instrumentName, isColorCamera: isColorCamera, bayerPattern: bayerPattern, to: url
                )
            } onSuccess: {
                self.recordExport(url: url, kind: .fits)
                self.recordActiveSessionCapture(url: url, kind: .fits, image: image)
            }
        case .png:
            guard let image = imageForExport() else { return }
            runExport(url: url) {
                try ImageExporter.writePNG(image, to: url)
            } onSuccess: {
                self.recordExport(url: url, kind: .png)
                self.recordActiveSessionCapture(url: url, kind: .png, image: image)
            }
        case .tiff:
            guard let image = imageForExport() else { return }
            runExport(url: url) {
                try ImageExporter.writeTIFF(image, to: url)
            } onSuccess: {
                self.recordExport(url: url, kind: .tiff)
                self.recordActiveSessionCapture(url: url, kind: .tiff, image: image)
            }
        }
    }

    private func runExport(
        url: URL, write: @escaping @Sendable () throws -> Void, onSuccess: @escaping @MainActor () -> Void
    ) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated, operation: write).value
            } catch {
                lastErrorMessage = String(describing: error)
                return
            }
            onSuccess()
            captureFeedbackTrigger &+= 1
            NSSound.beep()
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
        let rendered = renderedCurrentImage(frame: frame, camera: camera)
        return rendered.map(croppedToPreviewZoom)
    }

    /// `PreviewView` keeps this in sync with its own on-screen pinch-zoom/pan (normalized,
    /// top-left origin, matching `CGImage.cropping(to:)`'s coordinate space directly) — full
    /// frame (`(0, 0, 1, 1)`) when not zoomed in. Without this, a capture taken while zoomed in
    /// to frame a small target (Saturn, say) on screen still exported the *entire* sensor frame,
    /// making the target look tiny in the saved file even though it looked large while framing
    /// the shot — the export pipeline never knew the preview was zoomed at all. Deliberately only
    /// applied to the debayered/stretched PNG/TIFF export path here, not the raw FITS frame
    /// (`frameForExport()`, written directly in `finishExport`): cropping raw Bayer data would
    /// need to preserve the CFA pattern's 2×2 alignment, and FITS is meant to keep the full raw
    /// sensor capture for calibration/stacking regardless of how the shot was framed on screen.
    var previewCropRectNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)

    private func croppedToPreviewZoom(_ image: CGImage) -> CGImage {
        guard previewCropRectNormalized.width < 0.999 || previewCropRectNormalized.height < 0.999 else { return image }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let pixelRect = CGRect(
            x: (previewCropRectNormalized.minX * w).rounded(),
            y: (previewCropRectNormalized.minY * h).rounded(),
            width: (previewCropRectNormalized.width * w).rounded(),
            height: (previewCropRectNormalized.height * h).rounded()
        )
        return image.cropping(to: pixelRect) ?? image
    }

    // MARK: - Active session capture recording

    /// Best-effort: files the just-written `url` into the active session's own folder (a copy —
    /// `url` itself is left alone, since it's usually exactly where the user chose to save it via
    /// an `NSSavePanel`) with a thumbnail generated from `image`, if any. A no-op when no
    /// project/session is active. Failures here (disk full, permissions) surface through
    /// `lastErrorMessage` but never undo the export/recording that already succeeded.
    private func recordActiveSessionCapture(url: URL, kind: CaptureRecord.Kind, image: CGImage?) {
        guard var project = activeProject, let session = activeSession else { return }
        let thumbnail = image.flatMap(ThumbnailGenerator.makeThumbnail(from:))
        do {
            try projectStore.recordCapture(
                copyingFileAt: url, kind: kind, thumbnail: thumbnail, note: captureActionNote(for: kind, session: session),
                object: session.plannedObjects.first, location: session.effectiveLocation(inProject: project),
                equipmentSystemID: session.effectiveEquipmentSystemID(inProject: project),
                preset: currentAcquisitionPreset(name: captureActionNote(for: kind, session: session)),
                into: session, project: &project
            )
        } catch {
            lastErrorMessage = String(describing: error)
            return
        }
        activeProject = project
        activeSession = project.sessions.first(where: { $0.id == session.id })
        projectsLibrary.syncInMemory(project)
    }

    /// A plain-English record of what actually happened, alongside the file/thumbnail itself —
    /// "Captured Saturn in Live Stack for 30 sec" rather than just a filename and a timestamp,
    /// since that's what actually makes a timeline recognizable at a glance later. Built from
    /// whatever real state is available at the moment of capture — the session's own planned
    /// object (falling back to its name), which acquisition mode was actually active, and (for an
    /// SER recording specifically) how long it actually ran.
    func captureActionNote(for kind: CaptureRecord.Kind, session: Session) -> String {
        let target = session.plannedObjects.first ?? session.name
        switch kind {
        case .serVideo:
            let seconds = Int(serRecordingElapsedSeconds.rounded())
            return "Recorded \(target) as an SER video for \(seconds) sec"
        case .recording:
            return "Recorded \(target) to a continuous capture sequence"
        case .video:
            // Never actually produced by a real capture — `.video` only ever comes from
            // `MediaImporter`'s own "Import…" flow (`CameraManager.importMedia`), which builds
            // its own note directly rather than calling this. Exhaustiveness only.
            return "Imported a video for \(target)"
        case .fits, .png, .tiff:
            let formatName = kind == .fits ? "FITS" : (kind == .png ? "PNG" : "TIFF")
            if isLiveStackingEnabled {
                return "Captured \(target) in Live Stack as \(formatName)"
            } else if luckyImagingSession != nil {
                return "Captured \(target) in Lucky Imaging as \(formatName)"
            } else {
                return "Captured \(target) as a single \(formatName) frame"
            }
        }
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
            toneCurves: isToneCurveEnabled ? toneCurves : nil,
            filterGain: combinedFilterGain
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
        let currentFilterGain = combinedFilterGain
        let frameIDAtSchedule = frameID

        enhancementTask = Task.detached(priority: .userInitiated) { [weak self] in
            var displayFrame = frame
            if denoiseEnabled, let denoised = ImageEnhancer.denoise(displayFrame, isColorCamera: isColorCamera, bayerPattern: bayerPattern) {
                displayFrame = denoised
            }
            if sharpenEnabled, let sharpened = ImageEnhancer.waveletSharpen(
                displayFrame, fineGain: sharpenAmount, midGain: sharpenAmount * 0.6
            ) {
                displayFrame = sharpened
            }
            let image = CGImageRenderer.makeDisplayImage(
                from: displayFrame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: currentStretch,
                channelStretch: currentChannelStretch, toneCurves: currentToneCurves, filterGain: currentFilterGain
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
            // Was 200ms — see the matching bump in `scheduleStreakDetectionIfNeeded`'s doc
            // comment; planetary tracking specifically only needs to keep up with a slowly
            // drifting disk (mount tracking error, not fast motion), so ~3.3x/sec is still smooth.
            try? await Task.sleep(for: .milliseconds(300))
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
            // Was 250ms — see the matching bump in `scheduleStreakDetectionIfNeeded`'s doc
            // comment; a focus/HFD readout updating ~2.5x/sec is still plenty responsive for
            // manually adjusting focus by eye.
            try? await Task.sleep(for: .milliseconds(400))
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
        beginBlockingCapture(seconds: seconds)
        defer { endBlockingCapture() }

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
    ///
    /// Routed through `restartCapturePipeline` (rather than a bare `Task { await startPreview
    /// (...) }`, as this used to do) for the same reason `changeImageType`/`changeCaptureROI`
    /// are: an untracked `Task` here raced with any restart already in flight (e.g. one queued
    /// by a ROI change right as this fired) without cancelling the *existing*
    /// `frameConsumerTask` first — the exact "two overlapping restarts" failure
    /// `restartCapturePipeline`'s own doc comment describes, just reached from this call site
    /// instead. The symptom was a stream nothing feeds coexisting with an orphaned one still
    /// polling/decoding: `currentFrame` stops updating (so anything gated on it, e.g. most of
    /// the Controls panel, looks stuck disabled) while CPU usage stays elevated from the
    /// abandoned side still running.
    func resumeLiveView() {
        isLiveViewActive = true
        if let engine = webcamEngine {
            consumeWebcamFrames(engine.frames())
        } else if let camera = connectedCamera, let engine = captureEngine, camera.cameraID >= 0 {
            frameConsumerTask?.cancel()
            let imageType = selectedImageType
            restartCapturePipeline { [weak self] in
                await self?.startPreview(using: engine, imageType: imageType)
            }
        }
    }

    /// Everything about the *current capture session* — recording, live stack, lucky imaging,
    /// every background analysis task, ROI, polar alignment, cloud sentinel — reset regardless of
    /// *why* the camera stopped being usable (an explicit Disconnect, a ZWO camera unplugged, or a
    /// webcam disconnecting). Previously only `disconnect()` did all of this; `handleCameraRemoved()`
    /// and `handleWebcamDisconnected()` each did only a small subset, so unplugging a camera mid-
    /// SER/FITS recording and reconnecting could resume writing the *new* camera's frames into the
    /// *old*, never-finalized recording (stale `serWriter`/`isRecordingSERVideo`, no header/trailer
    /// patch), or leave a stale live-stack/lucky-imaging session hanging around. Deliberately
    /// excludes anything genuinely specific to *how* the camera stopped (which engine to tear down,
    /// `connectionState`'s exact value, which camera list to refresh) — those stay in each caller.
    private func resetCaptureSessionState() {
        captureROIWidth = nil
        captureROIHeight = nil
        captureROICenterX = nil
        captureROICenterY = nil
        captureROIAppliedStartX = nil
        captureROIAppliedStartY = nil
        captureBinning = 1
        liveViewFrameStartDate = nil
        liveViewFrameExpectedDuration = nil
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
        catalogFetchTask?.cancel()
        catalogFetchTask = nil
        liveWCS = nil
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
    }

    func disconnect() {
        if let name = connectedCamera?.name {
            AppLog.shared.log("Disconnected from \(name)")
        }
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        diagnosticsPollTask?.cancel()
        diagnosticsPollTask = nil
        droppedFrameCount = nil
        gainOffsetPresets = nil
        lmhGainOffsetPresets = nil
        resetCaptureSessionState()
        webcamEngine?.stop()
        webcamEngine = nil
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

    /// Called by `CaptureEngine` when the background poll loop hits any error other than the
    /// camera being physically removed (that's `handleCameraRemoved`, which also forgets the
    /// camera entirely) — e.g. a flaky USB link returning a general SDK error mid-stream.
    /// Previously the poll loop just quietly ended the stream here: `isLiveViewActive` stayed
    /// `true` (so "Resume Live View" — only shown when it's `false` — never appeared) and no error
    /// was ever shown, leaving the app looking like it was still streaming while producing
    /// nothing. The stream is genuinely dead either way, so recording/live-stack/lucky-imaging
    /// state gets the same reset a full disconnect would give it (see
    /// `resetCaptureSessionState()` — leaving a recording "in progress" while no frames arrive is
    /// exactly the corrupted-file bug that reset exists to prevent), but unlike
    /// `handleCameraRemoved`, `connectedCamera`/`captureEngine`/`controls` are left alone — the
    /// camera may well still be physically present and responsive, so "Resume Live View" can
    /// retry without a full reconnect.
    private func handleStreamError(_ error: Error) {
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        resetCaptureSessionState()
        // `resetCaptureSessionState()` sets `isLiveViewActive = true` (the right default after a
        // full disconnect, ready for the next connect) — override back to `false` here so the
        // "Resume Live View" affordance actually shows up, matching `startPreview`'s own failure
        // path just below.
        isLiveViewActive = false
        lastErrorMessage = String(describing: error)
        connectionState = .error(String(describing: error))
    }

    /// Called by `CaptureEngine` when a background call reports `ASI_ERROR_CAMERA_REMOVED`.
    func handleCameraRemoved() {
        frameConsumerTask?.cancel()
        frameConsumerTask = nil
        diagnosticsPollTask?.cancel()
        diagnosticsPollTask = nil
        droppedFrameCount = nil
        gainOffsetPresets = nil
        lmhGainOffsetPresets = nil
        resetCaptureSessionState()
        connectionState = .error(ZWOError.cameraRemoved.description)
        lastErrorMessage = ZWOError.cameraRemoved.description
        captureEngine = nil
        connectedCamera = nil
        controls = []
        controlValues = [:]
        refreshCameraList()
    }
}
