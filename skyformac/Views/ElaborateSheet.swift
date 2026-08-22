import AppKit
import SwiftUI

/// The confirmation sheet behind every "Elaborate…" button (`SessionDetailPane`,
/// `TimelineStripView`, `CaptureDetailPage`) — shows the auto-suggested recipe
/// (`SirilElaborationService.resolveRecipe`, "the default config depending on the object"),
/// lets the user override it (recipe, an optional crop to the planet, and Siril's own stacking
/// parameters), then runs the elaboration and reports the result. Presenting this at all already
/// implies Siril integration is enabled — callers check `AppSettings.isSirilIntegrationEnabled`
/// first and show `SirilDisabledPrompt` instead when it isn't.
struct ElaborateSheet: View {
    let source: SirilElaborationService.Source
    let suggestedRecipe: ElaborationRecipe
    let sourceDescription: String
    /// The `@Sendable` log callback is forwarded straight down to
    /// `SirilElaborationService.elaborate`'s own `onLog` — see that type's doc comment for why the
    /// growing log text arrives this way rather than as an `AsyncStream`.
    var onElaborate: (ElaborationRecipe, SirilElaborationService.ElaborationParameters, @escaping @Sendable (String) -> Void) async throws -> ElaboratedImage

    @Environment(\.dismiss) private var dismiss
    @State private var recipe: ElaborationRecipe
    @State private var isRunning = false
    @State private var isPreparingDirectOpen = false
    @State private var errorMessage: String?
    @State private var completedImage: ElaboratedImage?
    @State fileprivate var logText = ""

    @State private var sourcePreview: (image: NSImage, pixelSize: (width: Int, height: Int))?
    @State private var cropRect: SirilElaborationService.PixelRect?
    @State private var isShowingAdvanced = false
    @State private var rejectionSigmaLow: Double = 3.0
    @State private var rejectionSigmaHigh: Double = 3.0

    init(
        source: SirilElaborationService.Source, suggestedRecipe: ElaborationRecipe, sourceDescription: String,
        onElaborate: @escaping (ElaborationRecipe, SirilElaborationService.ElaborationParameters, @escaping @Sendable (String) -> Void) async throws -> ElaboratedImage
    ) {
        self.source = source
        self.suggestedRecipe = suggestedRecipe
        self.sourceDescription = sourceDescription
        self.onElaborate = onElaborate
        self._recipe = State(initialValue: suggestedRecipe)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Elaborate with Siril")
                .font(.headline)

            Text(sourceDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let completedImage {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Saved to Your Project", systemImage: "checkmark.seal.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                    Text("\(completedImage.fileName) is now in this project's Elaborated section — open the project page anytime to view, re-elaborate, or delete it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Recipe", selection: $recipe) {
                    ForEach(availableRecipes, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isRunning)

                Text(recipeExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                cropSection

                DisclosureGroup("Advanced Parameters", isExpanded: $isShowingAdvanced) {
                    advancedParametersSection
                }
                .disabled(isRunning)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if isRunning || !logText.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            if isRunning {
                                ProgressView().controlSize(.small)
                            }
                            Text(statusLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(logText.isEmpty ? "Waiting for Siril…" : logText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("logBottom")
                            }
                            .frame(height: 140)
                            .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                            .onChange(of: logText) { _, _ in proxy.scrollTo("logBottom", anchor: .bottom) }
                        }
                    }
                }
            }

            HStack {
                Button {
                    openInSiril()
                } label: {
                    if isPreparingDirectOpen {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Open Siril Directly…", systemImage: "arrow.up.forward.app")
                    }
                }
                .disabled(isPreparingDirectOpen)
                .help("Debayers the source, then opens Siril's own app with it loaded, for full manual control — alignment, rejection, curves, PixelMath — beyond what this automated recipe covers.")
                Spacer()
                if completedImage != nil {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .disabled(isRunning)
                    Button {
                        Task { await run() }
                    } label: {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Elaborate")
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await loadSourcePreview() }
    }

    /// "Does Siril need that I rectangle the planet?" — not strictly required, but cropping to
    /// just the disk first is genuinely worth doing (see `SirilElaborationService.PixelRect`'s own
    /// doc comment); this is where the user actually does that, dragging a box over the first
    /// frame. Hidden entirely until the preview's finished loading — nothing to draw a box on yet.
    @ViewBuilder
    private var cropSection: some View {
        if let sourcePreview {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Crop to Region").font(.callout)
                    Spacer()
                    if cropRect != nil {
                        Button("Clear") { cropRect = nil }
                            .buttonStyle(.borderless)
                            .disabled(isRunning)
                    }
                }
                CropRectangleSelector(image: sourcePreview.image, pixelSize: sourcePreview.pixelSize, cropRect: $cropRect)
                    .disabled(isRunning)
                Text(cropRect == nil
                    ? "Optional — drag a box over the planet to crop every frame to just that region before stacking. Faster, and keeps a slowly-drifting disk centered."
                    : "Cropping to \(cropRect!.width)×\(cropRect!.height)px.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView("Loading preview…").controlSize(.small)
        }
    }

    @ViewBuilder
    private var advancedParametersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Siril's own stacking rejection — how many standard deviations a pixel can deviate from its stack before being thrown out (satellite trails, cosmic ray hits, hot pixels).")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LabeledContent("Reject Below (σ)") {
                HStack {
                    Slider(value: $rejectionSigmaLow, in: 1...5, step: 0.1)
                    Text(String(format: "%.1f", rejectionSigmaLow)).font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                }
            }
            LabeledContent("Reject Above (σ)") {
                HStack {
                    Slider(value: $rejectionSigmaHigh, in: 1...5, step: 0.1)
                    Text(String(format: "%.1f", rejectionSigmaHigh)).font(.caption.monospacedDigit()).frame(width: 30, alignment: .trailing)
                }
            }
        }
        .padding(.top, 4)
    }

    /// Only recipes that make sense for `source` — a single FITS frame has nothing to register
    /// or stack, so `.singleImage` is the only option; a sequence (`.serVideo`/`.fitsFrames`) can
    /// go either way depending on whether the object actually has a star field to register
    /// against.
    private var availableRecipes: [ElaborationRecipe] {
        if case .singleFITS = source { return [.singleImage] }
        return [.planetary, .deepSky]
    }

    private var recipeExplanation: String {
        switch recipe {
        case .singleImage:
            return "Debayers the raw frame using its camera's own Bayer pattern, then applies an auto-stretch — no stacking (just one frame to work with)."
        case .planetary:
            return "Stacks every frame with outlier-pixel rejection, skipping star-based registration (Siril's registration needs a star field, which a planetary disk doesn't have). Best for the Moon/planets."
        case .deepSky:
            return "Registers frames against their star field, stacks with outlier-pixel rejection, then auto-stretches. Best for star clusters, galaxies, and nebulae."
        }
    }

    /// The log's last non-blank line — Siril's own output is one step/progress message per line,
    /// so this is a reasonable "what's happening right now" without showing the whole transcript
    /// inline with the rest of the sheet's controls.
    private var statusLine: String {
        guard let last = logText.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return isRunning ? "Starting Siril…" : ""
        }
        return String(last)
    }

    /// The one file "Open in Siril…" hands off, and what the crop preview is derived from — the
    /// first (only, for `.singleFITS`/`.serVideo`) file, or the first frame of a `.fitsFrames`
    /// burst.
    private var primarySourceURL: URL? {
        switch source {
        case .singleFITS(let url), .serVideo(let url): return url
        case .fitsFrames(let urls): return urls.first
        }
    }

    private func loadSourcePreview() async {
        guard let url = primarySourceURL else { return }
        let loaded: (NSImage, (width: Int, height: Int))?
        switch source {
        case .singleFITS, .fitsFrames:
            loaded = Self.loadFITSPreview(url)
        case .serVideo:
            loaded = Self.loadSERPreview(url)
        }
        sourcePreview = loaded
    }

    private static func loadFITSPreview(_ url: URL) -> (NSImage, (width: Int, height: Int))? {
        guard let parsed = try? FITSReader.read(from: url),
              let auto = DisplayStretch.autoStretch(histogram: HistogramComputer.histogram(for: parsed.frame)),
              let cgImage = CGImageRenderer.makeDisplayImage(
                from: parsed.frame, isColorCamera: parsed.isColorCamera, bayerPattern: parsed.bayerPattern, stretch: auto
              )
        else { return nil }
        return (NSImage(cgImage: cgImage, size: NSSize(width: parsed.frame.width, height: parsed.frame.height)), (parsed.frame.width, parsed.frame.height))
    }

    private static func loadSERPreview(_ url: URL) -> (NSImage, (width: Int, height: Int))? {
        guard let (frame, isColorCamera, bayerPattern) = try? SERReader.readFirstFrame(from: url),
              let auto = DisplayStretch.autoStretch(histogram: HistogramComputer.histogram(for: frame)),
              let cgImage = CGImageRenderer.makeDisplayImage(from: frame, isColorCamera: isColorCamera, bayerPattern: bayerPattern, stretch: auto)
        else { return nil }
        return (NSImage(cgImage: cgImage, size: NSSize(width: frame.width, height: frame.height)), (frame.width, frame.height))
    }

    private func openInSiril() {
        isPreparingDirectOpen = true
        errorMessage = nil
        Task {
            do {
                let url = try await SirilElaborationService.prepareForDirectOpen(source: source)
                try SirilAppLauncher.open(url)
            } catch {
                errorMessage = error.localizedDescription
            }
            isPreparingDirectOpen = false
        }
    }

    private func run() async {
        isRunning = true
        errorMessage = nil
        logText = ""
        defer { isRunning = false }
        let parameters = SirilElaborationService.ElaborationParameters(
            cropRect: cropRect, rejectionSigmaLow: rejectionSigmaLow, rejectionSigmaHigh: rejectionSigmaHigh
        )
        do {
            let sink = LogSink(self)
            completedImage = try await onElaborate(recipe, parameters) { chunk in sink.update(chunk) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Bridges `onElaborate`'s `@Sendable` log callback (invoked from a background queue) back onto
/// the main actor to update `ElaborateSheet`'s own `@State logText` — a plain closure capturing
/// `self` directly wouldn't satisfy `@Sendable` itself, since a `View` struct isn't `Sendable`.
/// Held only for the duration of one `run()` call, so a strong reference here isn't a leak.
@MainActor
private final class LogSink {
    private let owner: ElaborateSheet
    init(_ owner: ElaborateSheet) { self.owner = owner }

    nonisolated func update(_ text: String) {
        Task { @MainActor in owner.logText = text }
    }
}

/// Shown instead of `ElaborateSheet` when Siril integration is off — "the user can enable this
/// feature from settings and is prompted if she clicks on elaborate."
struct SirilDisabledPrompt: View {
    var onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Siril Integration Is Off")
                .font(.headline)
            Text("Sending captures to Siril for further processing (stacking, registration, stretching) needs Siril integration turned on first — it's off by default since Siril is a separate app this doesn't bundle.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Open Settings…") {
                    dismiss()
                    onOpenSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
