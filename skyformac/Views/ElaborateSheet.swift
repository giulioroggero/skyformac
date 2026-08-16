import SwiftUI

/// The confirmation sheet behind every "Elaborate…" button (`SessionDetailPane`,
/// `TimelineStripView`, `CaptureDetailPage`) — shows the auto-suggested recipe
/// (`SirilElaborationService.resolveRecipe`, "the default config depending on the object"),
/// lets the user override it, then runs the elaboration and reports the result. Presenting this
/// at all already implies Siril integration is enabled — callers check
/// `AppSettings.isSirilIntegrationEnabled` first and show `SirilDisabledPrompt` instead when it
/// isn't.
struct ElaborateSheet: View {
    let source: SirilElaborationService.Source
    let suggestedRecipe: ElaborationRecipe
    let sourceDescription: String
    var onElaborate: (ElaborationRecipe) async throws -> ElaboratedImage

    @Environment(\.dismiss) private var dismiss
    @State private var recipe: ElaborationRecipe
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var completedImage: ElaboratedImage?

    init(
        source: SirilElaborationService.Source, suggestedRecipe: ElaborationRecipe, sourceDescription: String,
        onElaborate: @escaping (ElaborationRecipe) async throws -> ElaboratedImage
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
                Label("Done — saved as \(completedImage.fileName)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
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

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
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
        .frame(width: 420)
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

    private func run() async {
        isRunning = true
        errorMessage = nil
        defer { isRunning = false }
        do {
            completedImage = try await onElaborate(recipe)
        } catch {
            errorMessage = error.localizedDescription
        }
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
