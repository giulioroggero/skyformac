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
    /// One `.ser` (the normal case), or several to combine into a single pooled burst before
    /// registering/stacking — "I want to combine several different captures and stack it."
    /// `PlanetaryPostProcessor.loadSequence(from:)`'s `[URL]` overload does the actual pooling;
    /// every other stage downstream has no idea more than one file was involved at all.
    let sourceURLs: [URL]
    let sourceDescription: String
    var onSave: (CGImage, _ title: String?, _ notes: String?, _ settings: PlanetaryPostProcessor.SettingsSnapshot?) async throws -> ElaboratedImage
    /// The "Overwrite" half of the save flow — replaces an already-saved result's own file and
    /// metadata in place (same `ElaboratedImage.id`) instead of cataloging a new one. Only ever
    /// offered once `savedImage` is non-nil, i.e. this view has already saved something once this
    /// session — see `startSaveFlow()`'s own doc comment.
    var onOverwrite: (CGImage, _ existing: ElaboratedImage, _ title: String?, _ notes: String?, _ settings: PlanetaryPostProcessor.SettingsSnapshot?) async throws -> ElaboratedImage
    /// Where a just-saved `ElaboratedImage`'s file actually lives — plain path construction
    /// (`ProjectStore.elaboratedImagesFolderURL(for:)` + `fileName`), handed down rather than
    /// giving this view direct `Project`/`ProjectStore` access, same reasoning as `onSave` itself.
    var resolveGraXpertInputURL: (ElaboratedImage) -> URL
    /// Runs an already-saved result through GraXpert — only offered once `onSave` has produced
    /// one, mirroring `ElaboratedImageCard`'s own "elaborate first, then optionally send that
    /// saved result on to GraXpert" flow, rather than needing its own separate temp-file plumbing.
    var onSendToGraXpert: (URL, GraXpertElaborationService.Operation, GraXpertElaborationService.Parameters, @escaping @Sendable (String) -> Void) async throws -> ElaboratedImage
    var onOpenGraXpertSettings: () -> Void
    /// Pre-fills every Stage 3-5 control from a previous result's own recorded settings —
    /// "post-process more…starting from the original with the settings used" (an elaborated
    /// image's "Redo from Original…"). `nil` (the default) leaves every control at its normal
    /// fresh-start value, exactly as before this existed — see `applyInitialSettingsIfNeeded()`.
    var initialSettings: PlanetaryPostProcessor.SettingsSnapshot? = nil
    /// Closes this view's own window — a plain closure (not `@Environment(\.dismiss)`, which only
    /// does anything inside a `.sheet`/`NavigationStack`) since this is now hosted in a real
    /// `NSWindow` via `DetachedContentWindowController` instead, precisely so it can be moved and
    /// resized like any other window.
    var onDismiss: () -> Void

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

    /// Restricts `scoreAndRegister`'s intensity-weighted centroid to just the selected object —
    /// see `roiSection`'s own doc comment for why this genuinely matters, not just a nice-to-have
    /// crop. Required (see "Start Processing"'s `.disabled`) precisely because leaving it `nil`
    /// is what used to produce the ghosted/duplicated stacks this exists to prevent.
    @State private var roiRect: SirilElaborationService.PixelRect?
    @State private var sourcePreview: (image: NSImage, pixelSize: (width: Int, height: Int), isColorCamera: Bool)?
    /// Distinguishes "still loading" (`sourcePreview == nil`, `false`) from "loading finished but
    /// failed" (`sourcePreview == nil`, `true`) — without this, a preview that fails to decode
    /// left `roiSection` showing "Loading preview…" forever, and now also permanently blocked
    /// "Start Processing" behind a box nothing exists to draw. On failure, the object-to-track
    /// requirement below is waived instead, so the burst can still be registered whole-frame.
    @State private var sourcePreviewFailed = false

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

    /// The Stage 3-5 pipeline's own output (stack → wavelet sharpen/align → stretch), *before*
    /// `singleShotAdjustments` — what `renderOnly()` actually computes. `previewImage` below
    /// (what's actually displayed and saved) is this run back through `ImageEditor.render(_:with:)`
    /// whenever the "Single Shot" tab's adjustments aren't at their identity default.
    @State private var stackedPreviewImage: CGImage?
    @State private var previewImage: CGImage?
    @State private var sharpenTask: Task<Void, Never>?
    @State private var renderTask: Task<Void, Never>?

    private enum SidebarTab: String, CaseIterable, Identifiable {
        case video = "Video"
        case singleShot = "Single Shot"
        var id: String { rawValue }
    }
    /// "In edit and post processing[,] right bar add two tabs, one for video management and one
    /// for editing single shots. The single shots [editing] can be used also in the post
    /// processed image" — `.video` is the existing Stage 3-5 stacking/wavelet/color/stretch
    /// controls; `.singleShot` reuses `ImageEditor` (the same single-image touch-up
    /// `SingleImagePostProcessingView`/"Edit Image…" uses) applied on top of `stackedPreviewImage`
    /// — the same tool, just one stage later in the pipeline instead of needing to save this
    /// result first and reopen it there separately.
    @State private var sidebarTab: SidebarTab = .video
    @State private var singleShotAdjustments = ImageEditor.Adjustments()
    @State private var isApplyingMagicWandToSingleShot = false
    @State private var isCenteringObject = false

    @State private var isSaving = false
    @State private var savedImage: ElaboratedImage?
    @State private var saveErrorMessage: String?
    /// Only asked once `savedImage` is already set — nothing to choose between on a first save.
    @State private var isChoosingSaveMode = false
    @State private var pendingSaveOverwritesExisting = false
    @State private var isPromptingSaveDetails = false
    @State private var saveTitle = ""
    @State private var saveNotes = ""

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

    /// Close to the screen's whole visible area ("the post processing view window must be
    /// larger, full width and height") but NOT exactly equal to it — sizing this window to
    /// exactly `visibleFrame` (tried once, reverted, back when this was still a `.sheet`) left no
    /// room for its own title bar without something having to give. `static` (not an instance
    /// property) — this is also what every call site hands `DetachedContentWindowController` as
    /// the window's own *initial* size; the window itself is genuinely resizable now ("the
    /// edit/preview windows can be moved across the screen and resized"), so this is just a
    /// starting point, not a permanent constraint the way it was as a `.sheet`'s fixed frame.
    static var fullScreenSize: CGSize {
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        return CGSize(width: max(visible.width - 40, 980), height: max(visible.height - 40, 660))
    }
    static let minWindowSize = NSSize(width: 980, height: 660)

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
        // Fills whatever size the window actually is (see `DetachedContentWindowController`'s
        // own doc comment) rather than a fixed size — a fixed `.frame(width:height:)` here would
        // silently fight the window's own resizing instead of actually growing/shrinking with it.
        .frame(minWidth: Self.minWindowSize.width, maxWidth: .infinity, minHeight: Self.minWindowSize.height, maxHeight: .infinity)
        .background(.background)
        .onDisappear { cancelCurrentWork?() }
        .onAppear { applyInitialSettingsIfNeeded() }
        .task {
            sourcePreview = sourceURLs.first.flatMap(Self.loadSourcePreview)
            sourcePreviewFailed = sourcePreview == nil
        }
        .confirmationDialog(
            "You already saved a version of this result.", isPresented: $isChoosingSaveMode, titleVisibility: .visible
        ) {
            Button("Save as New Version") {
                pendingSaveOverwritesExisting = false
                isPromptingSaveDetails = true
            }
            Button("Overwrite Saved Version") {
                pendingSaveOverwritesExisting = true
                isPromptingSaveDetails = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep the one you already saved and add this as another, or replace it with this result.")
        }
        .sheet(isPresented: $isPromptingSaveDetails) {
            SaveElaboratedImageDetailsSheet(
                title: $saveTitle, notes: $saveNotes, isOverwriting: pendingSaveOverwritesExisting,
                onSave: { Task { await save() } }
            )
        }
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

    /// Shown first, before any file I/O or computation starts — lets the user pick the
    /// parameters up front rather than silently running with hardcoded defaults nobody chose.
    /// `keepBestPercent`/`stackMethod` are the two that actually shape *what gets loaded/
    /// stacked*; `waveletSection` below is here too so the sharpening you want is already dialed
    /// in for the very first result — same `@State` the ready screen's own copy binds to, so
    /// whatever's set here just carries straight through to `scheduleSharpen()`'s first real run
    /// once a stacked image actually exists (that function itself no-ops with nothing to sharpen
    /// yet, so touching these sliders now is harmless). Still adjustable live after stacking too,
    /// same as before — cheap to re-run and easier to judge against the real stacked image.
    /// Was `VStack { Spacer(); HStack { ... }; Button; Spacer() }` — with nothing bounding the
    /// settings panel's height, adding a `ScrollView` there (see `stackingSection`'s sibling
    /// sections below) made it greedily claim all available vertical space, squeezing "Start
    /// Processing" itself down to zero height instead of just scrolling its own content. Giving
    /// the `HStack` the greedy `maxHeight: .infinity` explicitly, and keeping the button in its
    /// own fixed-height footer below it (not sandwiched between two plain `Spacer()`s), is what
    /// actually pins the button visible regardless of how tall the settings panel's content gets.
    private var setupBody: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            HStack(alignment: .top, spacing: 24) {
                roiSection
                    .frame(width: 420)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Set Up Stacking").font(.title2.bold())
                    Text(sourceURLs.count > 1
                        ? "Every frame across all \(sourceURLs.count) selected captures gets pooled, scored, and registered first, regardless of these settings — they only decide how the sharpest frames get combined afterwards. You can re-stack with different values later without reloading."
                        : "Every frame in \(sourceURLs.first?.lastPathComponent ?? "this capture") gets scored and registered first, regardless of these settings — they only decide how the sharpest frames get combined afterwards. You can re-stack with different values later without reloading.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            stackingSection
                            Divider()
                            waveletSection
                            Divider()
                            colorSection
                            Divider()
                            stretchSection
                        }
                    }
                }
                .padding(24)
                .frame(width: 460)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
            }
            .frame(maxHeight: .infinity)

            VStack(spacing: 6) {
                Button("Start Processing") {
                    stage = .loading
                    Task { await loadAndProcess() }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!canStartProcessing)
                if !canStartProcessing {
                    Text("Draw a box around the object to track above before starting.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 20)
        }
    }

    /// "Select the object before stacking, otherwise it duplicates the images" — registration
    /// (`scoreAndRegister`'s intensity-weighted centroid, the spec's "1-Point/Anchor Box"
    /// technique) is built for a *single* bright, compact target. Left unconstrained, it weighs
    /// every bright thing in the frame at once — a companion star, a moon, a sensor reflection —
    /// and the centroid it lands on can shift from frame to frame as those objects' relative
    /// brightness/position changes, registering each frame against a slightly different point
    /// instead of the same one. Stacking frames that were each nudged toward a different bright
    /// spot produces exactly the ghosted/doubled look reported — not a bug in the stack itself,
    /// a bug in what registration was even trying to lock onto. Drawing a box around just the
    /// intended object restricts the centroid search to it, the same fix `ElaborateSheet`'s own
    /// `cropSection` already uses for Siril's crop-to-region. Hidden until the preview's loaded —
    /// nothing to draw a box on yet.
    @ViewBuilder
    private var roiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Object to Track").font(.title3.bold())
                Spacer()
                if roiRect != nil {
                    Button("Clear") { roiRect = nil }
                        .buttonStyle(.borderless)
                }
            }
            if let sourcePreview {
                CropRectangleSelector(image: sourcePreview.image, pixelSize: sourcePreview.pixelSize, cropRect: $roiRect)
                Text(roiRect == nil
                    ? "Draw a box around the object you want to track — required before processing starts. If there's more than one bright thing in frame (a moon, a companion star, a reflection), registration can lock onto a different one from frame to frame without this, and the stack comes out ghosted/duplicated instead of sharp."
                    : "Registering against \(roiRect!.width)×\(roiRect!.height)px.")
                    .font(.caption2)
                    .foregroundStyle(roiRect == nil ? .orange : .secondary)
            } else if sourcePreviewFailed {
                Text("Couldn't load a preview to draw a box on — processing will register against the whole frame instead.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView("Loading preview…").controlSize(.small)
            }
        }
    }

    /// "Start Processing" needs an object-to-track box drawn first — unless the preview itself
    /// couldn't load (`sourcePreviewFailed`), in which case there's nothing to draw one on and
    /// this waives the requirement rather than leaving the button permanently disabled.
    private var canStartProcessing: Bool {
        roiRect != nil || sourcePreviewFailed
    }

    /// Whether a saved-then-restacked result exists to offer a real choice between — `save()`
    /// only actually asks (`isChoosingSaveMode`) when this is true; a first save always just
    /// creates a new entry, nothing to overwrite yet.
    private var hasAlreadySavedThisSession: Bool { savedImage != nil }

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
                    Label("Saved as \(savedImage.displayLabel)", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                    Button("Send to GraXpert…", systemImage: "sparkles") { startSendingToGraXpert() }
                }
            }
            if let saveErrorMessage {
                Text(saveErrorMessage).font(.caption).foregroundStyle(.red)
            }
            Button(hasAlreadySavedThisSession ? "Done" : "Cancel") {
                if hasAlreadySavedThisSession {
                    onDismiss()
                } else {
                    cancelCurrentWork?()
                    onDismiss()
                }
            }
            Button {
                startSaveFlow()
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text(hasAlreadySavedThisSession ? "Save Again…" : "Save as Elaborated Image")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(stage != .ready || previewImage == nil || isSaving)
        }
        .padding(16)
    }

    private var readyBody: some View {
        HSplitView {
            previewPane
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                Picker("", selection: $sidebarTab) {
                    ForEach(SidebarTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        switch sidebarTab {
                        case .video:
                            stackingSection
                            Divider()
                            waveletSection
                            Divider()
                            colorSection
                            Divider()
                            stretchSection
                        case .singleShot:
                            singleShotSection
                        }
                    }
                    .padding(16)
                }
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

    /// Prefers `loadedSequence` (the real answer, available once Stage 1 has actually run) but
    /// falls back to `sourcePreview`'s own quick first-frame read — available immediately on the
    /// setup screen, before "Start Processing" — so `colorSection` reads correctly there too
    /// instead of defaulting to "monochrome" just because nothing's loaded yet.
    private var isColorCameraSource: Bool {
        loadedSequence?.isColorCamera ?? sourcePreview?.isColorCamera ?? false
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color").font(.title3.bold())
            if isColorCameraSource {
                Toggle("Align RGB Channels", isOn: $alignRGBChannels)
                    .onChange(of: alignRGBChannels) { _, _ in scheduleSharpen() }
                Text("Aligns R/G/B to fix atmospheric-dispersion fringing at the disk's edge — most accurate with an \"Object to Track\" box drawn on the setup screen, so it isn't thrown off by noise/background elsewhere in the frame.")
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

    /// The "Single Shot" tab's own controls — `ImageEditor.Adjustments`, the same set
    /// `SingleImagePostProcessingView`'s "Edit Image…" offers, applied here on top of
    /// `stackedPreviewImage` instead of a saved file reopened separately. Deliberately doesn't
    /// include that view's crop/rotate — the "Object to Track" box already scoped registration to
    /// the useful region, and a rotate has little value on an already-stacked planetary disk — so
    /// this covers exactly what a *further touch-up* actually needs: tone, sharpen/denoise, and
    /// the astrophotography-specific tools (green-cast removal, star-size reduction).
    private var singleShotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Single Shot Adjustments").font(.title3.bold())
                Spacer()
                if singleShotAdjustments != .identity {
                    Button("Reset") {
                        singleShotAdjustments = .identity
                        applySingleShotAdjustments()
                    }
                    .buttonStyle(.borderless)
                }
            }
            Text("The same touch-up tools \"Edit Image…\" offers, applied straight to this stacked result — no need to save first and reopen it there separately.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    applyMagicWandToSingleShot()
                } label: {
                    if isApplyingMagicWandToSingleShot {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Magic Wand (Auto-Fix)", systemImage: "wand.and.stars")
                    }
                }
                .disabled(stackedPreviewImage == nil || isApplyingMagicWandToSingleShot || isCenteringObject)
                Button {
                    centerSingleShotObject()
                } label: {
                    if isCenteringObject {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Center Object", systemImage: "scope")
                    }
                }
                .disabled(stackedPreviewImage == nil || isApplyingMagicWandToSingleShot || isCenteringObject)
                .help("Shifts the image so its brightest area lands in the exact middle of the frame.")
            }

            // "In single shot use the edit functionalities of the edit image from capture page —
            // don't duplicate the code" — the exact same Color/Clean Up/Sharpen/Astronomy Tools
            // controls `SingleImagePostProcessingView`'s own sections use, not a second,
            // independently maintained copy of the same ~15 sliders.
            ImageAdjustmentsControls(adjustments: $singleShotAdjustments, onChange: applySingleShotAdjustments)
        }
    }

    private func applyMagicWandToSingleShot() {
        guard let stackedPreviewImage else { return }
        isApplyingMagicWandToSingleShot = true
        Task {
            let autoFixed = ImageEditor.autoFixed(stackedPreviewImage)
            isApplyingMagicWandToSingleShot = false
            // Magic Wand bakes Core Image's own scene-analysis auto-enhance directly into the
            // preview pixels (same reasoning as `SingleImagePostProcessingView.applyMagicWand()`)
            // rather than mapping it back onto `Adjustments`' own sliders, which have no slot for
            // the per-channel color balance its analysis picks — so this replaces the base image
            // `applySingleShotAdjustments()` renders from, resetting the sliders to identity
            // (their default) rather than double-applying on top of what Magic Wand already baked
            // in.
            guard let autoFixed else { return }
            self.stackedPreviewImage = autoFixed
            singleShotAdjustments = .identity
            applySingleShotAdjustments()
        }
    }

    /// "Allow to center the object in the image" — same `ImageEditor.centerObject(_:)` as
    /// `SingleImagePostProcessingView.centerObject()`, baked into `stackedPreviewImage` (the same
    /// base Magic Wand bakes into above) rather than mapped onto an `Adjustments` slider, since a
    /// geometric shift has no such slot either.
    private func centerSingleShotObject() {
        guard let stackedPreviewImage else { return }
        isCenteringObject = true
        Task {
            let centered = ImageEditor.centerObject(stackedPreviewImage)
            isCenteringObject = false
            guard let centered else { return }
            self.stackedPreviewImage = centered
            applySingleShotAdjustments()
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
            appendLog(sourceURLs.count > 1
                ? "Loading \(sourceURLs.count) captures…"
                : "Loading \(sourceURLs.first?.lastPathComponent ?? "capture")…")
            let sequence = try await runDetachedThrowing { try PlanetaryPostProcessor.loadSequence(from: sourceURLs) }
            loadedSequence = sequence
            // No longer force-resets `alignRGBChannels` here — it's now a real setup-screen
            // control (`colorSection`, also shown in `setupBody`) the user can set *before* this
            // runs; overwriting it here would silently discard that choice (and, for "Redo from
            // Original," discard `initialSettings.alignRGBChannels` too). Safe to leave whatever
            // it already is for a monochrome source either way — `alignRGBChannels(_:)` itself
            // no-ops unless `channels == 3`.
            let cameraDescription = sequence.isColorCamera
                ? "color, \(PlanetaryPostProcessor.bayerPatternName(sequence.bayerPattern)) Bayer mosaic"
                : "monochrome"
            appendLog("Loaded \(sequence.frames.count) frames (\(cameraDescription)).")

            progressFraction = 0
            let roi = roiRect.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            appendLog(roi == nil
                ? "Scoring & registering \(sequence.frames.count) frames against the sharpest frame's own position…"
                : "Scoring & registering \(sequence.frames.count) frames against the selected object…")
            let frameCount = sequence.frames.count
            let registered = await runDetached { isCancelled in
                PlanetaryPostProcessor.scoreAndRegister(
                    frames: sequence.frames, isColorCamera: sequence.isColorCamera, bayerPattern: sequence.bayerPattern, roi: roi,
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
            appendLog("Stacking the sharpest \(Int(percent))% of frames using \(method.rawValue.lowercased()) combination\(Self.stackPathNote(for: method))…")
            let stackResult = await runDetached { isCancelled in
                PlanetaryPostProcessor.stack(
                    frames: sequence.frames, registered: registered, isColorCamera: sequence.isColorCamera,
                    bayerPattern: sequence.bayerPattern, keepBestPercent: percent, method: method,
                    progress: { fraction in sink.reportProgress(fraction, phase: "Stacking", total: frameCount) },
                    isCancelled: isCancelled,
                    didUseGPU: { usedGPU in sink.reportGPUUsage(usedGPU, phase: "Stacking") }
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
        appendLog("Restacking the sharpest \(Int(percent))% of frames using \(method.rawValue.lowercased()) combination\(Self.stackPathNote(for: method))…")
        progressFraction = 0
        let stacked = await runDetached { isCancelled in
            PlanetaryPostProcessor.stack(
                frames: sequence.frames, registered: registered, isColorCamera: sequence.isColorCamera,
                bayerPattern: sequence.bayerPattern, keepBestPercent: percent, method: method,
                progress: { fraction in sink.reportProgress(fraction, phase: "Stacking", total: frameCount) },
                isCancelled: isCancelled,
                didUseGPU: { usedGPU in sink.reportGPUUsage(usedGPU, phase: "Stacking") }
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
        // Same region the "Object to Track" selector restricted registration to — narrowing the
        // per-channel centroid to just the object is what keeps this stage from being fooled by
        // background/noise the way a whole-frame centroid was; see `alignRGBChannels`'s own doc
        // comment for the failure mode this fixes.
        let roi = roiRect.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        sharpenTask = Task {
            let sharpened = await Task.detached(priority: .userInitiated) {
                var image = PlanetaryPostProcessor.waveletSharpen(baseStack, layers: layers, denoise: denoiseAmount)
                if align { image = PlanetaryPostProcessor.alignRGBChannels(image, roi: roi) }
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
            stackedPreviewImage = cgImage
            applySingleShotAdjustments()
        }
    }

    /// `previewImage`'s own final assembly step — `ImageEditor.render(_:with:)` is the same
    /// GPU-backed (Core Image/Metal) call `SingleImagePostProcessingView.scheduleRender()` uses,
    /// cheap enough to run directly on the main actor rather than detaching (see that function's
    /// own doc comment for why). Skips the render entirely at the identity default, so a "Video"-
    /// tab-only session (the common case) never pays for it at all.
    private func applySingleShotAdjustments() {
        guard let stackedPreviewImage else {
            previewImage = nil
            return
        }
        guard singleShotAdjustments != .identity else {
            previewImage = stackedPreviewImage
            return
        }
        previewImage = ImageEditor.render(stackedPreviewImage, with: singleShotAdjustments) ?? stackedPreviewImage
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

    /// "Save as Elaborated Image"/"Save Again…"'s action — asks new-version-vs-overwrite first
    /// only when there's actually a choice to make (`hasAlreadySavedThisSession`), then always
    /// asks for optional title/description before the real `save()` runs. A first save has
    /// nothing to overwrite yet, so it skips straight to the details sheet.
    private func startSaveFlow() {
        saveErrorMessage = nil
        if hasAlreadySavedThisSession {
            isChoosingSaveMode = true
        } else {
            pendingSaveOverwritesExisting = false
            isPromptingSaveDetails = true
        }
    }

    /// Every Stage 3-5 parameter the *currently displayed* `previewImage` was actually produced
    /// with — `appliedKeepBestPercent`/`appliedStackMethod` (not the live, possibly-unapplied
    /// slider/picker values — see their own doc comment) for Stage 3, the rest live straight off
    /// `@State` since Stage 4/5 always re-render immediately rather than needing a "Restack"-style
    /// apply step.
    private func currentSettingsSnapshot() -> PlanetaryPostProcessor.SettingsSnapshot {
        PlanetaryPostProcessor.SettingsSnapshot(
            roi: roiRect, keepBestPercent: appliedKeepBestPercent, stackMethod: appliedStackMethod,
            waveletLayers: waveletLayers, denoise: denoise, alignRGBChannels: alignRGBChannels,
            blackPoint: blackPoint, whitePoint: whitePoint,
            logStretchIntensity: useLogStretch ? logStretchIntensity : nil,
            singleShotAdjustments: singleShotAdjustments == .identity ? nil : singleShotAdjustments
        )
    }

    /// The inverse of `currentSettingsSnapshot()` — seeds every Stage 3-5 control from
    /// `initialSettings` once, right as this view appears (so the "Object to Track" box is
    /// already drawn and "Start Processing" is immediately enabled, not just the sliders). A
    /// no-op when `initialSettings` is `nil` (every ordinary "Post-Process…" launch).
    private func applyInitialSettingsIfNeeded() {
        guard let settings = initialSettings else { return }
        roiRect = settings.roi
        keepBestPercent = settings.keepBestPercent
        stackMethod = settings.stackMethod
        appliedKeepBestPercent = settings.keepBestPercent
        appliedStackMethod = settings.stackMethod
        waveletLayers = settings.waveletLayers
        denoise = settings.denoise
        alignRGBChannels = settings.alignRGBChannels
        blackPoint = settings.blackPoint
        whitePoint = settings.whitePoint
        useLogStretch = settings.logStretchIntensity != nil
        logStretchIntensity = settings.logStretchIntensity ?? 5
        singleShotAdjustments = settings.singleShotAdjustments ?? .identity
    }

    private func save() async {
        guard let previewImage else { return }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }
        let title = saveTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = saveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = currentSettingsSnapshot()
        do {
            if pendingSaveOverwritesExisting, let existing = savedImage {
                savedImage = try await onOverwrite(
                    previewImage, existing, title.isEmpty ? nil : title, notes.isEmpty ? nil : notes, settings
                )
            } else {
                savedImage = try await onSave(
                    previewImage, title.isEmpty ? nil : title, notes.isEmpty ? nil : notes, settings
                )
            }
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

    /// A quick auto-stretched preview of the source `.ser`'s first frame, just for `roiSection`'s
    /// crop selector to draw over — same idea as `ElaborateSheet.loadSERPreview`, kept separate
    /// since that one's `private` to its own file and this view has no other reason to depend on
    /// `ElaborateSheet` at all.
    /// Makes the GPU-vs-CPU split in `PlanetaryPostProcessor.stack` visible in the log rather than
    /// a silent implementation detail — "restack goes slow, is there duplicated old CPU code"
    /// traced back to exactly this: Mean streams through `PlanetaryGPUStacker` (see its own doc
    /// comment), but Median has no GPU equivalent — a true per-pixel median needs every sample
    /// resident to pick from, which Metal has no reduction primitive for — so it *always* runs on
    /// CPU, restack included. Nothing was duplicated; Median was simply never GPU-accelerated,
    /// and a restack (unlike the very first stack, which also includes a fast GPU registration
    /// pass diluting the wait) is *only* this combine step, so a CPU-bound Median restack has
    /// nothing faster running alongside it to make the wait feel shorter.
    /// Mean's own case says nothing here — whether *this* run actually used the GPU isn't known
    /// yet at the point this pre-stacking log line is written (the same call can go either way run
    /// to run; see `reportGPUUsage`'s own doc comment), so guessing "(GPU when available)" ahead of
    /// time was speculative and often wrong-looking next to the definitive "Stacking used the
    /// GPU/CPU" line that follows once the run actually finishes. Median's case is a fact known in
    /// advance (it's never GPU-accelerated at all, full stop), so that one still states it upfront.
    private static func stackPathNote(for method: PlanetaryPostProcessor.StackMethod) -> String {
        method == .mean
            ? ""
            : " (CPU — a true per-pixel median needs every sample, so there's no GPU shortcut here)"
    }

    private static func loadSourcePreview(_ url: URL) -> (image: NSImage, pixelSize: (width: Int, height: Int), isColorCamera: Bool)? {
        guard let (frame, isColorCamera, bayerPattern) = try? SERReader.readFirstFrame(from: url),
              let auto = DisplayStretch.autoStretch(histogram: HistogramComputer.histogram(for: frame)),
              let cgImage = CGImageRenderer.makeDisplayImage(from: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: auto)
        else { return nil }
        return (NSImage(cgImage: cgImage, size: NSSize(width: frame.width, height: frame.height)), (frame.width, frame.height), isColorCamera)
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

    /// "Show if used GPU or CPU" — `PlanetaryPostProcessor.stack`'s own `didUseGPU` callback
    /// fires with the *definitive* answer for this specific run, not just "GPU when available"
    /// (the same method can legitimately go either way run to run — no `MTLDevice` at all, or a
    /// real GPU call that failed mid-burst and fell back), so this appends a follow-up log line
    /// once stacking actually finishes instead of only stating an intent beforehand.
    nonisolated func reportGPUUsage(_ usedGPU: Bool, phase: String) {
        Task { @MainActor in
            owner.logLines.append("\(phase) used the \(usedGPU ? "GPU" : "CPU").")
        }
    }
}

/// The optional title/description prompt every save from `PlanetaryPostProcessingView` shows —
/// "the user very time save can optionally add a title and description." A plain small sheet
/// rather than inline fields on the main toolbar, since it's only needed for the instant of
/// actually saving, not while adjusting the live preview.
private struct SaveElaboratedImageDetailsSheet: View {
    @Binding var title: String
    @Binding var notes: String
    let isOverwriting: Bool
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isOverwriting ? "Overwrite Saved Version" : "Save as Elaborated Image").font(.headline)
            TextField("Title (optional)", text: $title)
            TextField("Description (optional)", text: $notes, axis: .vertical)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    dismiss()
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
