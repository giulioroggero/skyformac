import AppKit
import SwiftUI

/// A full-size modal for touching up a single already-captured still — a `.fits`/`.png`/`.tiff`
/// capture, or a Lucky Imaging/Live Capture frame exported and reopened here — with GPU-backed
/// color/contrast/curves/sharpen/rotate/crop adjustments (`ImageEditor`, Core Image-based) plus a
/// one-tap "Magic Wand" auto-fix. The single-image counterpart to
/// `PlanetaryPostProcessingView`, which is for stacking a whole `.ser` burst instead — this view
/// has no registration/stacking stage at all, just load → adjust → save.
struct SingleImagePostProcessingView: View {
    let sourceURL: URL
    let sourceDescription: String
    /// Where `onSave`'s result actually lands on disk — just enough for the "Saved as…" banner's
    /// own "Publish to AstroBin…" button to point at the right file, without this view needing to
    /// know about `CameraManager`/`Project` at all.
    let elaboratedImagesFolderURL: URL
    var onSave: (CGImage) async throws -> ElaboratedImage
    /// Closes this view's own window — a plain closure (not `@Environment(\.dismiss)`, which only
    /// does anything inside a `.sheet`/`NavigationStack`) since this is now hosted in a real
    /// `NSWindow` via `DetachedContentWindowController` instead, precisely so it can be moved and
    /// resized like any other window.
    var onDismiss: () -> Void

    private enum Stage: Equatable { case loading, ready, failed }
    @State private var stage: Stage = .loading
    @State private var errorMessage: String?

    /// The loaded source, never mutated — "Reset" and the crop/rotate/color sliders all measure
    /// from this. `Magic Wand` instead mutates `workingImage` (below), so a manual reset can
    /// still get back to the true original even after auto-fixing.
    @State private var originalImage: CGImage?
    /// What every adjustment slider actually renders from — starts equal to `originalImage`,
    /// replaced by `ImageEditor.autoFixed(_:)`'s result when Magic Wand is used, so a further
    /// manual tweak (say, a bit more sharpening) layers on top of the auto-fix instead of
    /// overwriting it.
    @State private var workingImage: CGImage?
    @State private var previewImage: CGImage?
    @State private var renderTask: Task<Void, Never>?

    @State private var adjustments = ImageEditor.Adjustments()
    // Crop expressed as four independent edge insets (0...0.49 each) rather than a draggable
    // rectangle — real crop control with far less UI/gesture code; a live drag-rect selector
    // would be a reasonable follow-up but isn't needed for "allow the user to crop."
    @State private var cropLeft: Double = 0
    @State private var cropRight: Double = 0
    @State private var cropTop: Double = 0
    @State private var cropBottom: Double = 0

    // Preview zoom/pan — lets a sharpen/denoise/star-size result be checked at real pixel scale
    // instead of only ever seeing the whole image shrunk to fit the pane.
    @State private var zoomScale: CGFloat = 1
    @State private var zoomOffset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero

    /// "Split View" compare — stacks the untouched `originalImage` above the live `previewImage`
    /// instead of showing only the edited result, so a subtle adjustment (a touch of denoise, a
    /// small gamma nudge) is actually visible against the source rather than trusted from memory.
    /// Vertical (original on top, edited below), not side-by-side — the preview pane itself is
    /// usually wider than it is tall, so a vertical split keeps each half at a more useful size
    /// than halving the width would.
    @State private var isComparingToOriginal = false
    @State private var isApplyingMagicWand = false
    @State private var isCenteringObject = false
    @State private var isRemovingGradient = false
    @State private var gradientErrorMessage: String?
    @State private var isRemovingCosmicRays = false
    @State private var isApplyingTikhonovDeconvolution = false
    @State private var aiToolErrorMessage: String?
    /// Precomputed once per `workingImage` (see `refreshStarMask()`) rather than inside
    /// `ImageEditor.render` itself — `StarDetector.detectStars` is a synchronous, possibly-slow
    /// Vision request, and `render` runs on every single slider tweak for the live preview.
    @State private var starMask: CGImage?
    @State private var isSaving = false
    @State private var savedImage: ElaboratedImage?
    @State private var saveErrorMessage: String?

    // AI Assistant — see `aiAssistantSection`'s own doc comment. A page-local chat (not the
    // sidebar's own `AssistantChatPanel`/`CameraManager` machinery, which this standalone window
    // doesn't hold a reference to) scoped just to this one image-editing session.
    @State private var aiChatMessages: [AssistantMessage] = []
    @State private var aiChatInput = ""
    @State private var isAIChatThinking = false
    @State private var aiChatErrorMessage: String?
    /// The last AI reply that proposed slider values rather than just answering — shown as an
    /// Approve/Reject card below the chat, never applied until the user taps Apply, the same
    /// "propose, don't act" discipline the sidebar assistant's own `AssistantAction` follows.
    @State private var pendingAISuggestion: OllamaPlanner.ImageAdjustmentSuggestion?
    @State private var isEnhancingWithAI = false
    @State private var aiEnhanceErrorMessage: String?
    /// Whether `workingImage`'s current pixels were actually regenerated by `GeminiImageEnhancer`
    /// (and so already carry the "AI - Sky For Mac" watermark) — cleared by anything that replaces
    /// `workingImage` from a different source, so this never claims a watermark is present on
    /// pixels that no longer have one.
    @State private var wasEnhancedByAI = false

    /// See `PlanetaryPostProcessingView.fullScreenSize`'s own doc comment — `static`, since this
    /// is also what every call site hands `DetachedContentWindowController` as the window's own
    /// *initial* size; the window itself is genuinely resizable now, so this is just a starting
    /// point, not a permanent constraint.
    static var fullScreenSize: CGSize { PlanetaryPostProcessingView.fullScreenSize }
    static var minWindowSize: NSSize { PlanetaryPostProcessingView.minWindowSize }

    private var cropRect: CGRect? {
        guard cropLeft > 0 || cropRight > 0 || cropTop > 0 || cropBottom > 0 else { return nil }
        let width = max(0.02, 1 - cropLeft - cropRight)
        let height = max(0.02, 1 - cropTop - cropBottom)
        return CGRect(x: cropLeft, y: cropTop, width: width, height: height)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch stage {
            case .loading:
                Spacer()
                ProgressView("Loading \(sourceURL.lastPathComponent)…")
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
                Divider()
                aiAssistantBar
            }
        }
        .frame(minWidth: Self.minWindowSize.width, maxWidth: .infinity, minHeight: Self.minWindowSize.height, maxHeight: .infinity)
        .background(.background)
        .task { await loadImage() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Image").font(.headline)
                Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let savedImage {
                Label("Saved as \(savedImage.fileName)", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Button("Publish to AstroBin…", systemImage: "arrow.up.forward.app") {
                    AstroBinPublisher.publish(elaboratedImagesFolderURL.appendingPathComponent(savedImage.fileName))
                }
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                if let saveErrorMessage {
                    Text(saveErrorMessage).font(.caption).foregroundStyle(.red)
                }
                Button("Cancel") { onDismiss() }
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
                    magicWandSection
                    Divider()
                    cropSection
                    Divider()
                    rotateSection
                    Divider()
                    ImageAdjustmentsControls(adjustments: $adjustments, onChange: scheduleRender)
                    Divider()
                    aiSection
                }
                .padding(16)
            }
            .frame(width: 320)
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            if isComparingToOriginal {
                VStack(spacing: 2) {
                    labeledComparisonImage("Original", image: originalImage)
                    labeledComparisonImage("Edited", image: previewImage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ZStack {
                    Color.black
                    if let previewImage {
                        Image(decorative: previewImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(12)
                            .scaleEffect(zoomScale)
                            .offset(zoomOffset)
                            // Pinch-to-zoom (trackpad) and the slider below both drive the same
                            // `zoomScale` — checking a sharpen/denoise/star-size result at real
                            // pixel scale needs more than "fit the whole image in the pane."
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in zoomScale = min(max(1, value), Self.maxZoomScale) }
                            )
                            // Only actually pans once zoomed in — at 1x there's nothing to pan to,
                            // and a plain drag shouldn't fight with anything else on the page.
                            .gesture(
                                DragGesture()
                                    .onChanged { value in
                                        guard zoomScale > 1 else { return }
                                        zoomOffset = CGSize(
                                            width: dragStartOffset.width + value.translation.width,
                                            height: dragStartOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in dragStartOffset = zoomOffset }
                            )
                    } else {
                        ProgressView()
                    }
                }
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            zoomControlBar
        }
    }

    /// One half of the vertical compare split — shares the exact same `zoomScale`/`zoomOffset`/
    /// `dragStartOffset` state the single-image preview above uses, rather than each half (or
    /// compare mode as a whole) having its own: "if the image is zoomed keep the already set
    /// zoom" falls out for free since toggling `isComparingToOriginal` never touches that state,
    /// and "if the user moves one image, move the other" falls out for free too, since dragging
    /// *either* half updates the one shared `zoomOffset` both halves render from — there's no
    /// separate synchronization to get right.
    @ViewBuilder
    private func labeledComparisonImage(_ label: String, image: CGImage?) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .scaleEffect(zoomScale)
                    .offset(zoomOffset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in zoomScale = min(max(1, value), Self.maxZoomScale) }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard zoomScale > 1 else { return }
                                zoomOffset = CGSize(
                                    width: dragStartOffset.width + value.translation.width,
                                    height: dragStartOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in dragStartOffset = zoomOffset }
                    )
            } else {
                ProgressView()
            }
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private static let maxZoomScale: CGFloat = 8

    private var zoomControlBar: some View {
        HStack {
            Text("Zoom").font(.caption)
            Button {
                withAnimation { resetZoom() }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoomScale <= 1)
            Slider(value: $zoomScale, in: 1...Self.maxZoomScale)
            Button {
                withAnimation { zoomScale = Self.maxZoomScale }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Text(String(format: "%.1fx", zoomScale))
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
            if zoomScale != 1 {
                Button("Reset") { withAnimation { resetZoom() } }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .help("Pinch, or drag this slider, to zoom into the preview — drag the image itself to pan once zoomed in.")
    }

    private func resetZoom() {
        zoomScale = 1
        zoomOffset = .zero
        dragStartOffset = .zero
    }

    private var magicWandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Auto-Fix").font(.title3.bold())
                Spacer()
                Button("Reset") { reset() }
                    .disabled(isBusyWithAnyAITool)
            }
            Text("Analyzes the image and picks color/contrast adjustments automatically — the same technology behind Photos.app's \"Auto Enhance.\" Manual sliders below still apply on top afterward.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            // Two per row, not one long `HStack` — with "Remove Background Gradient"'s own long
            // label in the mix, a single row of four+ buttons stopped fitting the sidebar's width
            // at all and became unreadable (truncated/wrapped labels running into each other).
            // Reset moved up next to the section title, and Compare to Original takes the slot
            // freed up next to Remove Gradient, keeping this a clean two-per-row grid.
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Button {
                        applyMagicWand()
                    } label: {
                        if isApplyingMagicWand {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        } else {
                            Label("Magic Wand", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isBusyWithAnyAITool)
                    Button {
                        centerObject()
                    } label: {
                        if isCenteringObject {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        } else {
                            Label("Center Object", systemImage: "scope").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isBusyWithAnyAITool)
                    .help("Shifts the image so its brightest area lands in the exact middle of the frame.")
                }
                GridRow {
                    Button {
                        removeBackgroundGradient()
                    } label: {
                        if isRemovingGradient {
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                        } else {
                            Label("Remove Gradient", systemImage: "square.stack.3d.forward.dottedline").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(isBusyWithAnyAITool)
                    .help("Samples plain sky background away from stars/nebulosity, fits a smooth gradient, and subtracts it — light pollution/moon glow/vignetting removal.")
                    Toggle("Compare to Original", systemImage: "rectangle.split.1x2", isOn: $isComparingToOriginal)
                        .toggleStyle(.button)
                        .frame(maxWidth: .infinity)
                        .help("Show the untouched original stacked above the current edit, instead of only the edit.")
                }
            }
            .buttonStyle(.bordered)
            if let gradientErrorMessage {
                Text(gradientErrorMessage).font(.caption).foregroundStyle(.red)
            }
        }
    }

    /// On-device machine-learning tools, distinct from the deterministic filters below (Sharpen,
    /// Denoise, etc.) — each bakes into `workingImage` the same one-shot way Magic Wand/Center
    /// Object/Remove Background Gradient above do, since neither has an `Adjustments` slot (a
    /// trained model's output isn't expressible as a slider value) and Tikhonov deconvolution's
    /// own iterative solve is too costly to re-run on every unrelated slider tweak the way
    /// `ImageEditor.render`'s Core Image-based filters are. See each tool's own doc comment
    /// (`CosmicRayRemover`, `TikhonovDeconvolver`) for exactly what runs and its license.
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI").font(.title3.bold())
            // One per row, full width — with labels this long ("Tikhonov Deconvolution"), side by
            // side in the sidebar's own width stopped being readable, same fix as the Auto-Fix
            // section's own button row above.
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    removeCosmicRays()
                } label: {
                    if isRemovingCosmicRays {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Label("Remove Cosmic Rays", systemImage: "sparkle").frame(maxWidth: .infinity)
                    }
                }
                .disabled(!CosmicRayRemover.isAvailable || isBusyWithAnyAITool)
                .help("Deep-learning cosmic-ray/hot-pixel detection and repair (deepCR, on-device Core ML) — recognizes real cosmic-ray hit shapes a simple outlier filter misses.")
                Button {
                    applyTikhonovDeconvolution()
                } label: {
                    if isApplyingTikhonovDeconvolution {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Label("Tikhonov Deconvolution", systemImage: "wand.and.rays").frame(maxWidth: .infinity)
                    }
                }
                .disabled(isBusyWithAnyAITool)
                .help("Regularized deblurring (Tikhonov/Landweber) — a smoother, more noise-robust alternative to the Sharpen section's own Deconvolution slider below.")
            }
            .buttonStyle(.bordered)
            if let aiToolErrorMessage {
                Text(aiToolErrorMessage).font(.caption).foregroundStyle(.red)
            }
            if !CosmicRayRemover.isAvailable {
                Text("Cosmic-ray removal's bundled model didn't load — this build may be missing its Core ML resource.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isBusyWithAnyAITool: Bool {
        isApplyingMagicWand || isCenteringObject || isRemovingGradient || isRemovingCosmicRays || isApplyingTikhonovDeconvolution
    }

    /// Grounds an AI chat in *this* page's own current view — the visible preview image plus its
    /// current slider values — so it can answer questions about what's actually on screen and
    /// propose specific adjustments, not just give generic advice. Two distinct capabilities live
    /// here: a text/vision chat (any provider whose model can see images — every cloud provider
    /// qualifies, a local Ollama model needs to itself be vision-capable) that proposes slider
    /// values for this app's own deterministic filters to apply, and — Gemini only, since neither
    /// Anthropic nor a local Ollama model can output an edited image at all — a genuine pixel-level
    /// "AI Enhance" that sends the image to Gemini's own image-generation model and gets a
    /// regenerated one back, watermarked "AI - Sky For Mac" in its bottom-right corner so anyone
    /// looking at it afterward can tell it wasn't purely this app's own filters.
    /// Unlike every other section on this page, this is *not* inside the sidebar's own
    /// `ScrollView` — it's a persistent bar spanning the full window, below both the preview pane
    /// and the sidebar, always visible regardless of how far the sidebar's been scrolled. A chat
    /// input buried at the bottom of a long scrollable sliders list — where it originally
    /// lived — reads as "this page has no chat at all" rather than "scroll down for it."
    private var aiAssistantBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !aiChatMessages.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(aiChatMessages) { message in
                            ChatBubbleRendering.bubble(message)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }

            if let pendingAISuggestion {
                aiSuggestionCard(pendingAISuggestion)
            }

            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                TextField("Ask AI about this image, or ask it to fix something…", text: $aiChatInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...3)
                    .onSubmit(sendAIChatMessage)
                Button {
                    sendAIChatMessage()
                } label: {
                    if isAIChatThinking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                    }
                }
                .disabled(isAIChatThinking || aiChatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || previewImage == nil)
                .help("Grounded in the image currently shown in the preview — uses whichever AI provider is set in Settings.")
                Divider().frame(height: 20)
                Button {
                    enhanceWithAI()
                } label: {
                    if isEnhancingWithAI {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("AI Enhance", systemImage: "sparkles.rectangle.stack")
                    }
                }
                .disabled(isEnhancingWithAI || isBusyWithAnyAITool || workingImage == nil)
                .help("Sends this image to Google Gemini's own image-generation model for a genuine AI-regenerated enhancement — not this app's own filters. Uses whatever's typed in the field to its left as the instruction, or a generic \"just improve this\" if it's empty. Requires Gemini selected as the AI provider in Settings (a plain API key, or Vertex AI with a service account). Watermarks the result \"AI - Sky For Mac.\"")
            }
            .padding(8)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            if let aiChatErrorMessage {
                Text(aiChatErrorMessage).font(.caption).foregroundStyle(.red)
            }
            if let aiEnhanceErrorMessage {
                Text(aiEnhanceErrorMessage).font(.caption).foregroundStyle(.red)
            }
            if wasEnhancedByAI {
                Label("This image includes an AI Enhance pass (watermarked).", systemImage: "checkmark.seal")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial)
    }

    @ViewBuilder
    private func aiSuggestionCard(_ suggestion: OllamaPlanner.ImageAdjustmentSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(suggestion.message).font(.caption)
            HStack {
                Button("Apply") { applyAISuggestion() }
                    .controlSize(.small)
                Button("Dismiss") { pendingAISuggestion = nil }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sendAIChatMessage() {
        let trimmed = aiChatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAIChatThinking, let previewImage else { return }
        guard let imageData = AIVisionImageEncoder.jpegData(from: previewImage) else {
            aiChatErrorMessage = "Couldn't prepare this image to send to the AI."
            return
        }
        aiChatInput = ""
        aiChatErrorMessage = nil
        aiChatMessages.append(AssistantMessage(role: .user, text: trimmed))
        let history = aiChatMessages
        let description = Self.describeAdjustments(adjustments)
        isAIChatThinking = true
        let planner = CameraManager.makePlanner()
        Task {
            do {
                let response = try await planner.discussImage(
                    message: trimmed, adjustmentsDescription: description, image: imageData, history: history
                )
                isAIChatThinking = false
                switch response {
                case .reply(let text):
                    aiChatMessages.append(AssistantMessage(role: .assistant, text: text))
                case .suggestion(let suggestion):
                    aiChatMessages.append(AssistantMessage(role: .assistant, text: suggestion.message))
                    pendingAISuggestion = suggestion
                }
            } catch {
                isAIChatThinking = false
                aiChatErrorMessage = (error as? OllamaError)?.userFacingMessage ?? "Couldn't reach the AI provider."
            }
        }
    }

    /// Plain-English summary of every non-default slider, folded into the AI chat's own prompt so
    /// it knows what's already been tried rather than proposing a value that's effectively already
    /// applied.
    private static func describeAdjustments(_ adjustments: ImageEditor.Adjustments) -> String {
        var parts: [String] = []
        if adjustments.brightness != 0 { parts.append("brightness \(adjustments.brightness)") }
        if adjustments.contrast != 1 { parts.append("contrast \(adjustments.contrast)") }
        if adjustments.saturation != 1 { parts.append("saturation \(adjustments.saturation)") }
        if adjustments.gamma != 1 { parts.append("gamma \(adjustments.gamma)") }
        if adjustments.sharpenIntensity != 0 { parts.append("sharpen \(adjustments.sharpenIntensity)") }
        if adjustments.denoiseAmount != 0 { parts.append("denoise \(adjustments.denoiseAmount)") }
        if adjustments.chromaNoiseReduction != 0 { parts.append("chroma noise reduction \(adjustments.chromaNoiseReduction)") }
        if adjustments.greenCastRemoval != 0 { parts.append("green cast removal \(adjustments.greenCastRemoval)") }
        if adjustments.starSizeReduction != 0 { parts.append("star size reduction \(adjustments.starSizeReduction)") }
        if adjustments.shadowLift != 0 { parts.append("shadow lift \(adjustments.shadowLift)") }
        if adjustments.highlightRecovery != 0 { parts.append("highlight recovery \(adjustments.highlightRecovery)") }
        if adjustments.vibrance != 0 { parts.append("vibrance \(adjustments.vibrance)") }
        if adjustments.warmth != 0 { parts.append("warmth \(adjustments.warmth)") }
        if adjustments.tint != 0 { parts.append("tint \(adjustments.tint)") }
        if adjustments.deconvolutionSharpen != 0 { parts.append("deconvolution sharpen \(adjustments.deconvolutionSharpen)") }
        return parts.isEmpty ? "No adjustments applied yet (all sliders at default)." : parts.joined(separator: ", ")
    }

    private func applyAISuggestion() {
        guard let pendingAISuggestion else { return }
        if let v = pendingAISuggestion.brightness { adjustments.brightness = v }
        if let v = pendingAISuggestion.contrast { adjustments.contrast = v }
        if let v = pendingAISuggestion.saturation { adjustments.saturation = v }
        if let v = pendingAISuggestion.gamma { adjustments.gamma = v }
        if let v = pendingAISuggestion.sharpenIntensity { adjustments.sharpenIntensity = v }
        if let v = pendingAISuggestion.denoiseAmount { adjustments.denoiseAmount = v }
        if let v = pendingAISuggestion.chromaNoiseReduction { adjustments.chromaNoiseReduction = v }
        if let v = pendingAISuggestion.greenCastRemoval { adjustments.greenCastRemoval = v }
        if let v = pendingAISuggestion.starSizeReduction { adjustments.starSizeReduction = v }
        if let v = pendingAISuggestion.shadowLift { adjustments.shadowLift = v }
        if let v = pendingAISuggestion.highlightRecovery { adjustments.highlightRecovery = v }
        if let v = pendingAISuggestion.vibrance { adjustments.vibrance = v }
        if let v = pendingAISuggestion.warmth { adjustments.warmth = v }
        if let v = pendingAISuggestion.tint { adjustments.tint = v }
        if let v = pendingAISuggestion.deconvolutionSharpen { adjustments.deconvolutionSharpen = v }
        self.pendingAISuggestion = nil
        scheduleRender()
    }

    /// The generic instruction used when the chat bar's own text field is empty — "just make it
    /// better" with no specific direction from the user.
    private static let defaultAIEnhanceInstructions = """
    Enhance this astrophotography image: reduce noise, improve contrast and sharpness, correct \
    any color cast, and bring out faint detail — without distorting star shapes or changing the \
    framing/aspect ratio. Return only the improved image.
    """

    /// Gemini-only genuine pixel regeneration — see `aiAssistantSection`'s own doc comment for why
    /// Anthropic/Ollama can't do this at all. Bakes into `workingImage` the same one-shot way Magic
    /// Wand/Remove Cosmic Rays do, then watermarks the result before it lands there, so the
    /// watermark is a real, permanent part of the saved pixels rather than a UI overlay someone
    /// could accidentally export around.
    ///
    /// Whatever's currently typed into the chat bar's own text field becomes the enhancement
    /// instruction ("remove the gradient and boost the nebula's red", say) instead of always using
    /// the generic default — the same field the chat Send button reads, so a user only ever has
    /// one place to type what they want and picks which button acts on it. Falls back to a generic
    /// "just improve this" instruction when the field is empty. Recorded into the chat transcript
    /// either way, so the bar reads as one continuous conversation regardless of which action a
    /// given turn actually triggered.
    ///
    /// Only checks the provider is actually Gemini here — whether that means a plain API key or
    /// Vertex AI (and whether *that*'s fully configured) is `GeminiEndpoint.resolve`'s own job, so
    /// this doesn't duplicate that validation and risk the two disagreeing.
    private func enhanceWithAI() {
        guard let workingImage else { return }
        guard AppSettings.aiProvider == .gemini else {
            aiEnhanceErrorMessage = "AI Enhance needs Google Gemini selected as the AI provider in Settings."
            return
        }
        guard let imageData = AIVisionImageEncoder.jpegData(from: workingImage, quality: 0.92) else {
            aiEnhanceErrorMessage = "Couldn't prepare this image to send to Gemini."
            return
        }
        let customInstruction = aiChatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions: String
        if customInstruction.isEmpty {
            instructions = Self.defaultAIEnhanceInstructions
        } else {
            instructions = """
            Enhance this astrophotography image as follows: \(customInstruction). Preserve star \
            shapes and the image's framing/aspect ratio unless asked otherwise. Return only the \
            improved image.
            """
            aiChatMessages.append(AssistantMessage(role: .user, text: customInstruction))
            aiChatInput = ""
        }
        isEnhancingWithAI = true
        aiEnhanceErrorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let resultData = try await GeminiImageEnhancer.enhance(
                    image: imageData, apiKey: AppSettings.geminiAPIKey ?? "",
                    model: AppSettings.geminiImageModel ?? SettingsView.geminiImageModelChoices[0],
                    instructions: instructions
                )
                guard let source = CGImageSourceCreateWithData(resultData as CFData, nil),
                      let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let watermarked = AIWatermark.apply(to: decoded)
                else {
                    await MainActor.run {
                        self.isEnhancingWithAI = false
                        self.aiEnhanceErrorMessage = "Gemini's reply didn't include a usable image."
                    }
                    return
                }
                await MainActor.run {
                    self.isEnhancingWithAI = false
                    self.workingImage = watermarked
                    self.wasEnhancedByAI = true
                    if !customInstruction.isEmpty {
                        self.aiChatMessages.append(AssistantMessage(role: .assistant, text: "Applied AI Enhance with that instruction."))
                    }
                    self.refreshStarMask()
                    self.scheduleRender()
                }
            } catch {
                await MainActor.run {
                    self.isEnhancingWithAI = false
                    self.aiEnhanceErrorMessage = (error as? OllamaError)?.userFacingMessage ?? "Couldn't reach Gemini."
                }
            }
        }
    }

    private func removeCosmicRays() {
        guard let workingImage else { return }
        isRemovingCosmicRays = true
        aiToolErrorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let cleaned = try CosmicRayRemover.clean(workingImage)
                await MainActor.run {
                    self.isRemovingCosmicRays = false
                    self.workingImage = cleaned
                    self.wasEnhancedByAI = false
                    self.refreshStarMask()
                    self.scheduleRender()
                }
            } catch {
                await MainActor.run {
                    self.isRemovingCosmicRays = false
                    self.aiToolErrorMessage = "Couldn't remove cosmic rays: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyTikhonovDeconvolution() {
        guard let workingImage else { return }
        isApplyingTikhonovDeconvolution = true
        aiToolErrorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let deconvolved = try TikhonovDeconvolver.deconvolve(workingImage, amount: 0.5)
                await MainActor.run {
                    self.isApplyingTikhonovDeconvolution = false
                    self.workingImage = deconvolved
                    self.wasEnhancedByAI = false
                    self.refreshStarMask()
                    self.scheduleRender()
                }
            } catch {
                await MainActor.run {
                    self.isApplyingTikhonovDeconvolution = false
                    self.aiToolErrorMessage = "Couldn't deconvolve: \(error.localizedDescription)"
                }
            }
        }
    }

    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Crop").font(.title3.bold())
            ResettableAdjustmentSlider(label: "Left", value: $cropLeft, range: 0...0.49, defaultValue: 0, format: "%.0f%%", displayScale: 100, onChange: scheduleRender)
            ResettableAdjustmentSlider(label: "Right", value: $cropRight, range: 0...0.49, defaultValue: 0, format: "%.0f%%", displayScale: 100, onChange: scheduleRender)
            ResettableAdjustmentSlider(label: "Top", value: $cropTop, range: 0...0.49, defaultValue: 0, format: "%.0f%%", displayScale: 100, onChange: scheduleRender)
            ResettableAdjustmentSlider(label: "Bottom", value: $cropBottom, range: 0...0.49, defaultValue: 0, format: "%.0f%%", displayScale: 100, onChange: scheduleRender)
        }
    }

    private var rotateSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rotate").font(.title3.bold())
            ResettableAdjustmentSlider(
                label: "Angle", value: $adjustments.rotationDegrees, range: -180...180, defaultValue: 0,
                step: 0.5, format: "%.1f°", onChange: scheduleRender
            )
            HStack {
                Button("-90°") { adjustments.rotationDegrees -= 90; scheduleRender() }
                Button("+90°") { adjustments.rotationDegrees += 90; scheduleRender() }
            }
        }
    }

    // MARK: - Pipeline

    private func loadImage() async {
        do {
            let image = try await Task.detached(priority: .userInitiated) {
                try CGImageRenderer.loadDisplayImage(from: sourceURL)
            }.value
            originalImage = image
            workingImage = image
            previewImage = image
            stage = .ready
            refreshStarMask()
        } catch {
            errorMessage = "Couldn't open \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            stage = .failed
        }
    }

    /// Not `Task.detached` — `CGImage` isn't `Sendable`-annotated by CoreGraphics (despite being
    /// safe to read from any thread once created), which trips Swift 6's "sending" checker on
    /// every attempt to hand one into a detached task. `ImageEditor.render`/`autoFixed` already
    /// do their actual work on the GPU via Core Image's own Metal-backed `CIContext` — the CPU
    /// side here is just building/dispatching that filter graph, cheap enough (unlike
    /// `PlanetaryPostProcessor`'s hand-written per-pixel Swift loops) that running it directly
    /// inside a plain, cancellable `Task` is fine without also detaching it off the main actor.
    private func scheduleRender() {
        renderTask?.cancel()
        guard let workingImage else { return }
        var adj = adjustments
        adj.cropRect = cropRect
        let mask = starMask
        renderTask = Task {
            guard !Task.isCancelled else { return }
            previewImage = ImageEditor.render(workingImage, with: adj, starMask: mask) ?? workingImage
        }
    }

    /// Recomputes `starMask` for whatever `workingImage` currently is — called after every
    /// operation that replaces `workingImage`'s own pixels/geometry (load, Magic Wand, Center
    /// Object, Remove Background Gradient, Reset), so `starSizeReduction` always scopes itself to
    /// this image's actual current star locations instead of a stale mask from before.
    private func refreshStarMask() {
        guard let workingImage else { starMask = nil; return }
        Task.detached(priority: .utility) {
            let mask = ImageEditor.computeStarMask(for: workingImage)
            await MainActor.run { self.starMask = mask }
        }
    }

    private func applyMagicWand() {
        guard let originalImage else { return }
        isApplyingMagicWand = true
        Task {
            let fixed = ImageEditor.autoFixed(originalImage)
            isApplyingMagicWand = false
            guard let fixed else { return }
            workingImage = fixed
            wasEnhancedByAI = false
            refreshStarMask()
            // Magic Wand bakes Core Image's own scene-analysis auto-enhance directly into
            // `workingImage`'s pixels — there's no `Adjustments` slot that corresponds to what it
            // actually computed (per-channel exposure, vibrance, tone curve), so the sliders
            // below can't *show* the change. But leaving `adjustments` at whatever it was before
            // is worse: it keeps displaying values that no longer describe anything real (measured
            // against the pre-wand image, now silently stale), which reads as "the wand did
            // nothing" or "these values are wrong." Resetting to identity means the sliders
            // honestly reflect the new baseline — no adjustment on top of it yet — and any further
            // slider tweak still layers on top of the wand's result via `workingImage`.
            adjustments = .identity
            scheduleRender()
        }
    }

    /// "Allow to center the object in the image" — unlike Magic Wand, this bakes into whatever
    /// `workingImage` currently is (not always `originalImage`), since a geometric shift doesn't
    /// conflict with color/tone edits already applied the way Magic Wand's own scene analysis
    /// might; there's no reason centering should discard them.
    private func centerObject() {
        guard let workingImage else { return }
        isCenteringObject = true
        Task {
            let centered = ImageEditor.centerObject(workingImage)
            isCenteringObject = false
            guard let centered else { return }
            self.workingImage = centered
            wasEnhancedByAI = false
            refreshStarMask()
            scheduleRender()
        }
    }

    /// "Background/gradient extraction" — same bakes-into-`workingImage` treatment as Magic Wand/
    /// Center Object above, via `GradientExtractor`'s automatic sampling (see its own doc comment
    /// for exactly how it picks background points and fits/subtracts the gradient).
    private func removeBackgroundGradient() {
        guard let workingImage else { return }
        isRemovingGradient = true
        gradientErrorMessage = nil
        Task.detached(priority: .userInitiated) {
            do {
                let corrected = try GradientExtractor.removeGradient(from: workingImage)
                await MainActor.run {
                    self.isRemovingGradient = false
                    self.workingImage = corrected
                    self.wasEnhancedByAI = false
                    self.refreshStarMask()
                    self.scheduleRender()
                }
            } catch {
                await MainActor.run {
                    self.isRemovingGradient = false
                    self.gradientErrorMessage = Self.describe(error)
                }
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case GradientExtractor.ExtractionError.tooFewSamples:
            return "Couldn't find enough plain background away from stars/nebulosity to model a gradient."
        default:
            return "Couldn't remove the background gradient."
        }
    }

    private func reset() {
        workingImage = originalImage
        adjustments = .identity
        cropLeft = 0
        cropRight = 0
        cropTop = 0
        cropBottom = 0
        previewImage = originalImage
        wasEnhancedByAI = false
        refreshStarMask()
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
}
