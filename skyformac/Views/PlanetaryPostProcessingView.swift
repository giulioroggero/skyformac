import AppKit
import SwiftUI

/// Full-screen ("the modal is full size windows") planetary/lunar lucky-imaging pipeline behind
/// the Capture page's "Post-Process…" button — implements `specs/skyformac_Post_Processing_Planets
/// .md`'s five stages (`PlanetaryPostProcessor`) with interactive parameter controls and a live
/// preview, then hands the finished frame off to `onSave` to record as an `ElaboratedImage`, the
/// same catalog Siril/GraXpert/StarNet results land in. Unlike `ElaborateSheet`, which just calls
/// out to Siril and reports its log, this view *is* the tool — every parameter change re-runs the
/// (pure, GPU-independent) pipeline itself.
struct PlanetaryPostProcessingView: View {
    let sourceURL: URL
    let sourceDescription: String
    var onSave: (CGImage) async throws -> ElaboratedImage
    /// Where a just-saved `ElaboratedImage`'s file actually lives — plain path construction
    /// (`ProjectStore.elaboratedImagesFolderURL(for:)` + `fileName`), handed down rather than
    /// giving this view direct `Project`/`ProjectStore` access, same reasoning as `onSave` itself.
    var resolveGraXpertInputURL: (ElaboratedImage) -> URL
    /// Runs an already-saved result through GraXpert — only offered once `onSave` has produced
    /// one, mirroring `ElaboratedImageCard`'s own "elaborate first, then optionally send that
    /// saved result on to GraXpert" flow, rather than needing its own separate temp-file plumbing.
    var onSendToGraXpert: (URL, GraXpertElaborationService.Operation, GraXpertElaborationService.Parameters, @escaping @Sendable (String) -> Void) async throws -> ElaboratedImage
    var onOpenGraXpertSettings: () -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable { case setup, loading, ready, failed }

    @State private var stage: Stage = .setup
    @State private var errorMessage: String?
    @State fileprivate var progressText = "Loading frames…"
    @State fileprivate var progressFraction: Double?
    @State fileprivate var logLines: [String] = []

    /// Cancels whichever `Task.detached` `runDetached`/`runDetachedThrowing` most recently
    /// started — set on every call so "Cancel"/dismissal always has a live handle to the actual
    /// background work currently running, however many stages deep `loadAndProcess` is.
    @State private var cancelCurrentWork: (() -> Void)?

    @State private var loadedSequence: PlanetaryPostProcessor.LoadedSequence?
    @State private var registeredFrames: [PlanetaryPostProcessor.RegisteredFrame] = []
    @State private var baseStack: PlanetaryPostProcessor.StackedImage?
    /// The wavelet-sharpened + RGB-aligned image, cached separately from `baseStack` — the input
    /// `renderOnly()` re-renders from on every stretch-only tweak, so black/white-point/log
    /// sliders don't have to redo the (much more expensive) sharpen+align pass just to see a new
    /// stretch, which is what made "change stretch" feel unresponsive before this.
    @State private var sharpenedImage: PlanetaryPostProcessor.StackedImage?
    @State private var isRestacking = false

    // Stage 3 parameters.
    @State private var keepBestPercent: Double = 50
    @State private var stackMethod: PlanetaryPostProcessor.StackMethod = .median
    /// The values the *current* `baseStack` was actually combined with — compared against the
    /// live slider/picker above to show a "press Restack to apply" hint, since (unlike every
    /// other parameter here) these two require a full re-stack rather than a live re-render.
    @State private var appliedKeepBestPercent: Double = 50
    @State private var appliedStackMethod: PlanetaryPostProcessor.StackMethod = .median

    // Stage 4 parameters.
    @State private var waveletLayers: [PlanetaryPostProcessor.WaveletLayer] = Self.defaultLayers
    @State private var denoise: Double = 0

    // Stage 5 parameters.
    @State private var alignRGBChannels = true
    @State private var blackPoint: Double = 0
    @State private var whitePoint: Double = 1
    @State private var useLogStretch = false
    @State private var logStretchIntensity: Double = 5

    @State private var previewImage: CGImage?
    @State private var sharpenTask: Task<Void, Never>?
    @State private var renderTask: Task<Void, Never>?

    @State private var isSaving = false
    @State private var savedImage: ElaboratedImage?
    @State private var saveErrorMessage: String?

    @State private var isSendingToGraXpert = false
    @State private var isPromptingGraXpertSettings = false
    @State private var graXpertResult: ElaboratedImage?

    // `waveletSharpen`'s reconstruction is exact (base + Σ detail) when every gain is 1.0 — that's
    // a no-op, not sharpening, so a flat `1.0` default silently reproduced the unsharpened stack
    // and looked like "sharpening does nothing, just a fog." Gains above 1.0 amplify a layer's
    // detail beyond what was actually there; tapering from finest to coarsest (a standard
    // unsharp-mask shape) boosts the micro-texture/edges a planetary image lives or dies on
    // without also exaggerating the coarsest, noise-prone scale.
    private static let defaultLayers: [PlanetaryPostProcessor.WaveletLayer] = [1.6, 1.35, 1.15, 1.0]
        .enumerated().map { .init(id: $0.offset, gain: $0.element) }

    private var fullScreenSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        return CGSize(width: max(visible.width - 40, 980), height: max(visible.height - 40, 660))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch stage {
            case .setup:
                setupBody
            case .loading:
                Spacer()
                progressPanel
                Spacer()
            case .failed:
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.red)
                    Text(errorMessage ?? "Something went wrong.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            case .ready:
                readyBody
            }
        }
        // macOS has no `.fullScreenCover` — this is presented as a `.sheet`, so filling nearly the
        // whole screen (rather than sizing to content, a plain sheet's macOS default) is what
        // makes it read as "a full-size window" rather than a small popup like `ElaborateSheet`.
        .frame(width: fullScreenSize.width, height: fullScreenSize.height)
        .background(.background)
        .onDisappear { cancelCurrentWork?() }
        .sheet(isPresented: $isPromptingGraXpertSettings) {
            GraXpertDisabledPrompt(onOpenSettings: onOpenGraXpertSettings)
        }
        .sheet(isPresented: $isSendingToGraXpert) {
            if let savedImage {
                let inputURL = resolveGraXpertInputURL(savedImage)
                GraXpertSheet(
                    inputURL: inputURL,
                    sourceDescription: "Sending \(savedImage.fileName) to GraXpert."
                ) { operation, parameters, onLog in
                    let result = try await onSendToGraXpert(inputURL, operation, parameters, onLog)
                    graXpertResult = result
                    return result
                }
            }
        }
    }

    /// Shown first, before any file I/O or computation starts — lets the user pick the two
    /// parameters that actually shape *what gets loaded/stacked* (`keepBestPercent`/`stackMethod`)
    /// up front, rather than silently running with hardcoded defaults nobody chose and only
    /// letting them override after the fact via "Restack". The heavier wavelet/color/stretch
    /// parameters stay adjustable live after stacking, same as before — those are cheap to re-run
    /// and benefit from seeing the actual stacked image first.
    private var setupBody: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                Text("Set Up Stacking").font(.title2.bold())
                Text("Every frame in \(sourceURL.lastPathComponent) gets scored and registered first, regardless of these settings — they only decide how the sharpest frames get combined afterwards. You can re-stack with different values later without reloading.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                stackingSection
            }
            .padding(24)
            .frame(width: 440)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            Button("Start Processing") {
                stage = .loading
                Task { await loadAndProcess() }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .padding(.top, 20)
            Spacer()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Planetary Post-Processing").font(.headline)
                Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let savedImage {
                if let graXpertResult {
                    Label("Sent to GraXpert as \(graXpertResult.fileName)", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Label("Saved as \(savedImage.fileName)", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Button("Send to GraXpert…", systemImage: "sparkles") { startSendingToGraXpert() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if let saveErrorMessage {
                    Text(saveErrorMessage).font(.caption).foregroundStyle(.red)
                }
                Button("Cancel") {
                    cancelCurrentWork?()
                    dismiss()
                }
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save as Elaborated Image")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(stage != .ready || previewImage == nil || isSaving)
            }
        }
        .padding(16)
    }

    private var readyBody: some View {
        HSplitView {
            previewPane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stackingSection
                    Divider()
                    waveletSection
                    Divider()
                    colorSection
                    Divider()
                    stretchSection
                }
                .padding(16)
            }
            .frame(width: 340)
        }
    }

    private var previewPane: some View {
        ZStack {
            Color.black
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
                    // Restacking replaces `baseStack` entirely, so the old preview is now stale —
                    // dim it rather than blanking to black, so there's always something on screen
                    // (the "show a preview" ask) while the new stack + its own re-render run.
                    .opacity(isRestacking ? 0.35 : 1)
            } else {
                // Reachable right after the very first stack finishes, before its first wavelet-
                // sharpen/align/stretch render completes — without this text it read as a plain
                // black, unexplained loading spinner with no indication anything was happening.
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Sharpening & rendering preview…").font(.caption).foregroundStyle(.white.opacity(0.7))
                }
            }
            if isRestacking {
                progressPanel
                    .padding(20)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// Progress bar + scrolling log — shown full-size during initial `.loading`, and reused as an
    /// overlay on the (dimmed, still-visible) old preview during "Restack", so both cases give
    /// the same clearly-live feedback instead of a bare, motionless spinner.
    private var progressPanel: some View {
        VStack(spacing: 12) {
            if let progressFraction {
                ProgressView(value: progressFraction).frame(width: 360)
            } else {
                ProgressView().frame(width: 360)
            }
            Text(progressText).font(.callout).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(logLines.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("logBottom")
                }
                .frame(width: 480, height: 220)
                .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: logLines) { _, _ in proxy.scrollTo("logBottom", anchor: .bottom) }
            }
            Button("Cancel", role: .cancel) { cancelCurrentWork?() }
        }
    }

    // MARK: - Parameter sections

    private var stackingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if stage == .ready {
                Text("Stacking").font(.title3.bold())
                Text("\(registeredFrames.count) frames registered against the sharpest frame's own position.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Keep Best") {
                HStack {
                    Slider(value: $keepBestPercent, in: 5...100, step: 1).disabled(isRestacking)
                    Text("\(Int(keepBestPercent))%").font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            Text("What fraction of the sharpest registered frames to combine — lower rejects more atmospheric-seeing blur, at the cost of fewer frames to average noise out of.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Picker("Method", selection: $stackMethod) {
                ForEach(PlanetaryPostProcessor.StackMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isRestacking)
            Text(stackMethod == .median
                ? "Median: robust against outlier frames (satellite trails, hot pixels), the usual pick."
                : "Mean: slightly smoother noise, more sensitive to any bad frames that slipped past scoring.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if stage == .ready {
                HStack(spacing: 8) {
                    Button {
                        Task { await restack() }
                    } label: {
                        if isRestacking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Restack")
                        }
                    }
                    .disabled(isRestacking)
                    // Live progress/log/Cancel for a restack shows as an overlay on the preview
                    // itself (`previewPane`'s own `progressPanel`) — the same reasoning as the
                    // main `.loading` stage's progress panel, just reused rather than duplicated
                    // here.
                    if !isRestacking, keepBestPercent != appliedKeepBestPercent || stackMethod != appliedStackMethod {
                        // Unlike the wavelet/color/stretch controls below, Keep Best/Method can't
                        // re-render live — applying them means recombining every selected frame
                        // from scratch. Without this, dragging the slider and seeing nothing
                        // happen (until you notice and press Restack) reads as broken.
                        Text("Changed — press Restack to apply.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var waveletSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wavelet Sharpening").font(.title3.bold())
            Text("À trous multi-scale sharpening — fine layers bring up micro-texture, coarse layers bring up broad contrast.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach($waveletLayers) { $layer in
                LabeledContent(layerLabel(layer.id)) {
                    HStack {
                        Slider(value: $layer.gain, in: 0...3, step: 0.05)
                        Text(String(format: "%.2f", layer.gain)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                    }
                }
            }
            .onChange(of: waveletLayers) { _, _ in scheduleSharpen() }
            LabeledContent("Denoise") {
                HStack {
                    Slider(value: $denoise, in: 0...1, step: 0.01)
                    Text(String(format: "%.2f", denoise)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            .onChange(of: denoise) { _, _ in scheduleSharpen() }
        }
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color").font(.title3.bold())
            if loadedSequence?.isColorCamera == true {
                Toggle("Align RGB Channels", isOn: $alignRGBChannels)
                    .onChange(of: alignRGBChannels) { _, _ in scheduleSharpen() }
                Text("Cross-correlates R/G/B to fix atmospheric-dispersion fringing at the disk's edge.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("This sequence is monochrome — no color channels to align.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stretchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Stretch").font(.title3.bold())
                Spacer()
                Button("Auto") { autoStretch() }
                    .buttonStyle(.borderless)
            }
            LabeledContent("Black Point") {
                HStack {
                    Slider(value: $blackPoint, in: 0...1, step: 0.005)
                    Text(String(format: "%.3f", blackPoint)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
            }
            .onChange(of: blackPoint) { _, _ in renderOnly() }
            LabeledContent("White Point") {
                HStack {
                    Slider(value: $whitePoint, in: 0...1, step: 0.005)
                    Text(String(format: "%.3f", whitePoint)).font(.caption.monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
            }
            .onChange(of: whitePoint) { _, _ in renderOnly() }
            Toggle("Non-Linear (Log) Stretch", isOn: $useLogStretch)
                .onChange(of: useLogStretch) { _, _ in renderOnly() }
            if useLogStretch {
                LabeledContent("Intensity") {
                    HStack {
                        Slider(value: $logStretchIntensity, in: 0.1...50, step: 0.1)
                        Text(String(format: "%.1f", logStretchIntensity)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                    }
                }
                .onChange(of: logStretchIntensity) { _, _ in renderOnly() }
            }
        }
    }

    private func layerLabel(_ id: Int) -> String {
        switch id {
        case 0: return "Layer 1 (Fine)"
        case waveletLayers.count - 1: return "Layer \(id + 1) (Coarse)"
        default: return "Layer \(id + 1)"
        }
    }

    // MARK: - Pipeline

    private func appendLog(_ line: String) {
        logLines.append(line)
        progressText = line
    }

    /// Runs `work` on a background thread via `Task.detached` — required since this synchronous,
    /// non-yielding, CPU-bound engine code would otherwise run directly on the main actor (the
    /// context every `async` function on this view starts in, `.task { }`'s closure included)
    /// and freeze the whole app until it finished. `await`ing the detached task's `.value` here,
    /// rather than folding the *entire* calling function into one big detached task, is what lets
    /// execution hop back onto the main actor afterwards — so every `@State` write in
    /// `loadAndProcess`/`restack` between `runDetached` calls happens safely on the main actor,
    /// not from that background thread.
    ///
    /// `work` receives an explicit `isCancelled` check to thread into
    /// `PlanetaryPostProcessor.scoreAndRegister`/`stack`'s own `isCancelled` parameter — plain
    /// `Task.isCancelled` is NOT enough on its own: `stack`'s `combine` step runs its per-pixel
    /// work via `DispatchQueue.concurrentPerform`, whose worker closures have no ambient `Task`
    /// context, so they can never observe `task.cancel()` below. `cancelCurrentWork` therefore
    /// flips `PlanetaryCancellationFlag` directly (in addition to cancelling the `Task`, which
    /// still matters for the plain sequential loops that *do* run inside this exact task).
    private func runDetached<T: Sendable>(_ work: @escaping @Sendable (@escaping () -> Bool) -> T) async -> T {
        let flag = PlanetaryCancellationFlag()
        let task = Task.detached(priority: .userInitiated) { work({ flag.isCancelled }) }
        cancelCurrentWork = { flag.cancel(); task.cancel() }
        return await task.value
    }

    private func runDetachedThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        cancelCurrentWork = { task.cancel() }
        return try await task.value
    }

    private func loadAndProcess() async {
        let sink = ProgressSink(self)
        do {
            appendLog("Loading \(sourceURL.lastPathComponent)…")
            let sequence = try await runDetachedThrowing { try PlanetaryPostProcessor.loadSequence(from: sourceURL) }
            loadedSequence = sequence
            alignRGBChannels = sequence.isColorCamera
            let cameraDescription = sequence.isColorCamera
                ? "color, \(PlanetaryPostProcessor.bayerPatternName(sequence.bayerPattern)) Bayer mosaic"
                : "monochrome"
            appendLog("Loaded \(sequence.frames.count) frames (\(cameraDescription)).")

            progressFraction = 0
            appendLog("Scoring & registering \(sequence.frames.count) frames against the sharpest frame's own position…")
            let frameCount = sequence.frames.count
            let registered = await runDetached { isCancelled in
                PlanetaryPostProcessor.scoreAndRegister(
                    frames: sequence.frames, isColorCamera: sequence.isColorCamera, bayerPattern: sequence.bayerPattern,
                    progress: { fraction in sink.reportProgress(fraction, phase: "Registering", total: frameCount) },
                    isCancelled: isCancelled
                )
            }
            guard !Task.isCancelled else { return }
            registeredFrames = registered
            progressFraction = 1
            appendLog("Registered \(registered.count) of \(frameCount) frames.")

            progressFraction = 0
            let percent = keepBestPercent
            let method = stackMethod
            appendLog("Stacking the sharpest \(Int(percent))% of frames using \(method.rawValue.lowercased()) combination…")
            let stackResult = await runDetached { isCancelled in
                PlanetaryPostProcessor.stack(
                    frames: sequence.frames, registered: registered, isColorCamera: sequence.isColorCamera,
                    bayerPattern: sequence.bayerPattern, keepBestPercent: percent, method: method,
                    progress: { fraction in sink.reportProgress(fraction, phase: "Stacking", total: frameCount) },
                    isCancelled: isCancelled
                )
            }
            guard !Task.isCancelled else { return }
            guard let stacked = stackResult else {
                errorMessage = "Couldn't stack this sequence — no frames scored above the minimum signal threshold."
                appendLog("Stacking failed — no frames scored above the minimum signal threshold.")
                stage = .failed
                return
            }
            baseStack = stacked
            appliedKeepBestPercent = percent
            appliedStackMethod = method
            progressFraction = 1
            appendLog("Stack complete — \(stacked.width)×\(stacked.height), \(stacked.channels) channel(s). Sharpening & rendering preview…")
            stage = .ready
            // Not `renderOnly()` — that renders with the black/white point still at their
            // `0...1` identity defaults, which looks solid black on real (linear, low-signal)
            // sensor data (see `DisplayStretch.autoStretch`'s own doc comment on exactly this).
            // Auto-stretching the very first preview is what makes the initial result visible at
            // all instead of "the result is a black image" until the user finds the Auto button.
            scheduleSharpen(useAutoStretch: true)
        } catch {
            errorMessage = error.localizedDescription
            appendLog("Failed: \(error.localizedDescription)")
            stage = .failed
        }
    }

    private func restack() async {
        guard let sequence = loadedSequence, !isRestacking else { return }
        isRestacking = true
        defer { isRestacking = false }
        let percent = keepBestPercent
        let method = stackMethod
        let registered = registeredFrames
        let sink = ProgressSink(self)
        let frameCount = sequence.frames.count
        appendLog("Restacking the sharpest \(Int(percent))% of frames using \(method.rawValue.lowercased()) combination…")
        progressFraction = 0
        let stacked = await runDetached { isCancelled in
            PlanetaryPostProcessor.stack(
                frames: sequence.frames, registered: registered, isColorCamera: sequence.isColorCamera,
                bayerPattern: sequence.bayerPattern, keepBestPercent: percent, method: method,
                progress: { fraction in sink.reportProgress(fraction, phase: "Stacking", total: frameCount) },
                isCancelled: isCancelled
            )
        }
        progressFraction = nil
        guard !Task.isCancelled, let stacked else { return }
        baseStack = stacked
        appliedKeepBestPercent = percent
        appliedStackMethod = method
        appendLog("Restacked — sharpening & rendering preview…")
        scheduleSharpen()
    }

    /// The expensive stage (wavelet sharpen → RGB align) — re-run only when `baseStack` changes
    /// (a fresh stack/restack) or a wavelet/color parameter does, then caches the result in
    /// `sharpenedImage` and renders from it. `useAutoStretch` picks between the two ways a render
    /// can follow: the very first stack has no user-chosen black/white point yet (`autoStretch()`
    /// derives one from the actual data), every later call already does (`renderOnly()` reuses it
    /// as-is). Cancels any in-flight sharpen/render first so a fast slider drag doesn't queue up a
    /// backlog of stale work.
    private func scheduleSharpen(useAutoStretch: Bool = false) {
        sharpenTask?.cancel()
        renderTask?.cancel()
        guard let baseStack else { return }
        let layers = waveletLayers
        let denoiseAmount = denoise
        let align = alignRGBChannels
        sharpenTask = Task {
            let sharpened = await Task.detached(priority: .userInitiated) {
                var image = PlanetaryPostProcessor.waveletSharpen(baseStack, layers: layers, denoise: denoiseAmount)
                if align { image = PlanetaryPostProcessor.alignRGBChannels(image) }
                return image
            }.value
            if Task.isCancelled { return }
            sharpenedImage = sharpened
            if useAutoStretch {
                autoStretch()
            } else {
                renderOnly()
            }
        }
    }

    /// Cheap stage only — a per-pixel black/white-point (and optional log) stretch of the
    /// already-sharpened image cached in `sharpenedImage`. This is what makes stretch sliders
    /// feel live: it skips redoing the full wavelet-sharpen/align pass `scheduleSharpen()` above
    /// does, which previously ran on every single stretch-slider drag too and made "change
    /// stretch" feel unresponsive rather than live.
    private func renderOnly() {
        renderTask?.cancel()
        guard let sharpenedImage else { return }
        let black = blackPoint
        let white = whitePoint
        let logIntensity = useLogStretch ? logStretchIntensity : nil
        renderTask = Task {
            let cgImage = await Task.detached(priority: .userInitiated) {
                PlanetaryPostProcessor.renderImage(sharpenedImage, blackPoint: black, whitePoint: white, logStretchIntensity: logIntensity)
            }.value
            if Task.isCancelled { return }
            previewImage = cgImage
        }
    }

    private func autoStretch() {
        guard let sharpenedImage else { return }
        Task {
            let histogram = await Task.detached(priority: .userInitiated) {
                PlanetaryPostProcessor.histogram(of: sharpenedImage)
            }.value
            guard let auto = DisplayStretch.autoStretch(histogram: histogram) else { return }
            blackPoint = auto.blackPoint
            whitePoint = auto.whitePoint
            renderOnly()
        }
    }

    private func save() async {
        guard let previewImage else { return }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }
        do {
            savedImage = try await onSave(previewImage)
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private func startSendingToGraXpert() {
        if AppSettings.isGraXpertIntegrationEnabled {
            isSendingToGraXpert = true
        } else {
            isPromptingGraXpertSettings = true
        }
    }
}

/// Bridges `PlanetaryPostProcessor`'s `progress: ((Float) -> Void)?` callbacks — invoked from a
/// background `Task.detached` closure, potentially hundreds of times per stage — back onto the
/// main actor to update `PlanetaryPostProcessingView`'s own `@State progressFraction`/
/// `progressText`, without spamming the scrolling log with one line per frame. Same bridging
/// reasoning as `ElaborateSheet`'s own `LogSink`.
@MainActor
private final class ProgressSink {
    private let owner: PlanetaryPostProcessingView
    /// Last 10%-milestone appended to the visible scrolling log, per phase name — `progressText`
    /// alone updates on every call, but it's a single line easy to glance past; without also
    /// pushing periodic lines into the scrolling log, a multi-minute phase with only the progress
    /// bar moving reads as "no other logs, stuck" even while it's actually advancing.
    private var lastLoggedMilestone: [String: Int] = [:]
    init(_ owner: PlanetaryPostProcessingView) { self.owner = owner }

    nonisolated func reportProgress(_ fraction: Float, phase: String, total: Int) {
        let done = Int(fraction * Float(total))
        let percent = Int((fraction * 100).rounded())
        Task { @MainActor in
            owner.progressFraction = Double(fraction)
            let line = "\(phase) \(done)/\(total) frames (\(percent)%)…"
            owner.progressText = line
            let milestone = (percent / 10) * 10
            if milestone > (lastLoggedMilestone[phase] ?? -10) {
                lastLoggedMilestone[phase] = milestone
                owner.logLines.append(line)
            }
        }
    }
}
