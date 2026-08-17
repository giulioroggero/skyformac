import SwiftUI

/// The confirmation sheet behind "Remove Stars…" on an `ElaboratedImageCard` — StarNet has just
/// one operation and one real knob (stride), so this is the simplest of the three elaboration
/// sheets: no recipe/operation picker, no "Open in…" GUI hand-off (StarNet has no GUI app to open
/// — it's a bare CLI tool). Presenting this at all already implies StarNet integration is enabled
/// — callers check `AppSettings.isStarNetIntegrationEnabled` first and show `StarNetDisabledPrompt`
/// instead when it isn't.
struct StarNetSheet: View {
    let inputURL: URL
    let sourceDescription: String
    var onRun: (StarNetElaborationService.Parameters, @escaping @Sendable (String) -> Void) async throws -> ElaboratedImage

    @Environment(\.dismiss) private var dismiss
    @State private var stride: Double = 256
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var completedImage: ElaboratedImage?
    @State fileprivate var logText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Remove Stars with StarNet").font(.headline)

            Text(sourceDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let completedImage {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Saved to Your Project", systemImage: "checkmark.seal.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                    Text("\(completedImage.fileName) is now in this project's Elaborated section, alongside the image you sent to StarNet — open the project page anytime to view or delete it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Produces a starless version of this image — useful for compositing nebulosity/background separately from the star field, or for a smoother auto-stretch that isn't fighting bright star cores.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Stride") {
                    HStack {
                        Slider(value: $stride, in: 2...512, step: 2)
                        Text("\(Int(stride))px").font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
                    }
                }
                .disabled(isRunning)
                Text("Smaller catches smaller stars but runs slower; StarNet's own suggested starting point is 256.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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
                                Text(logText.isEmpty ? "Waiting for StarNet…" : logText)
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
                            Text("Run")
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

    private var statusLine: String {
        guard let last = logText.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return isRunning ? "Starting StarNet…" : ""
        }
        return String(last)
    }

    private func run() async {
        isRunning = true
        errorMessage = nil
        logText = ""
        defer { isRunning = false }
        let parameters = StarNetElaborationService.Parameters(stride: Int(stride))
        do {
            let sink = StarNetLogSink(self)
            completedImage = try await onRun(parameters) { chunk in sink.update(chunk) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Bridges `onRun`'s `@Sendable` log callback back onto the main actor — same reasoning as
/// `ElaborateSheet`'s own `LogSink`.
@MainActor
private final class StarNetLogSink {
    private let owner: StarNetSheet
    init(_ owner: StarNetSheet) { self.owner = owner }

    nonisolated func update(_ text: String) {
        Task { @MainActor in owner.logText = text }
    }
}

/// Shown instead of `StarNetSheet` when StarNet integration is off — same pattern as
/// `SirilDisabledPrompt`/`GraXpertDisabledPrompt`.
struct StarNetDisabledPrompt: View {
    var onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("StarNet Integration Is Off")
                .font(.headline)
            Text("Removing stars from an elaborated image needs StarNet integration turned on first — it's off by default since StarNet is a separate tool this doesn't bundle.")
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
