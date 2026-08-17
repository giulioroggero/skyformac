import AppKit
import SwiftUI

/// The confirmation sheet behind "Send to GraXpert…" on an `ElaboratedImageCard` — picks an
/// operation (Background Extraction or Denoising), lets the user adjust its parameters, then runs
/// it and reports the result. Much simpler than `ElaborateSheet`: GraXpert works on one already-
/// existing image at a time, so there's no source-kind/recipe resolution or crop step, just an
/// operation and its own knobs. Presenting this at all already implies GraXpert integration is
/// enabled — callers check `AppSettings.isGraXpertIntegrationEnabled` first and show
/// `GraXpertDisabledPrompt` instead when it isn't.
struct GraXpertSheet: View {
    let inputURL: URL
    let sourceDescription: String
    var onRun: (GraXpertElaborationService.Operation, GraXpertElaborationService.Parameters, @escaping @Sendable (String) -> Void) async throws -> ElaboratedImage

    @Environment(\.dismiss) private var dismiss
    @State private var operation: GraXpertElaborationService.Operation = .backgroundExtraction
    @State private var correction: GraXpertElaborationService.Correction = .subtraction
    @State private var smoothing: Double = 0.1
    @State private var denoiseStrength: Double = 0.5
    @State private var useGPU = true
    @State private var isRunning = false
    @State private var errorMessage: String?
    @State private var completedImage: ElaboratedImage?
    @State fileprivate var logText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send to GraXpert").font(.headline)

            Text(sourceDescription)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let completedImage {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Saved to Your Project", systemImage: "checkmark.seal.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                    Text("\(completedImage.fileName) is now in this project's Elaborated section, alongside the image you sent to GraXpert — open the project page anytime to view, re-process, or delete it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Operation", selection: $operation) {
                    ForEach(GraXpertElaborationService.Operation.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isRunning)

                Text(operationExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                parametersSection

                Toggle("Use GPU acceleration", isOn: $useGPU)
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
                                Text(logText.isEmpty ? "Waiting for GraXpert…" : logText)
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
                Button("Open in GraXpert…", systemImage: "arrow.up.forward.app") { openInGraXpert() }
                    .help("Opens GraXpert's own app with this file loaded, for manual background-point placement or inspecting the AI model's output before accepting it.")
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
        .frame(width: 460)
    }

    @ViewBuilder
    private var parametersSection: some View {
        switch operation {
        case .backgroundExtraction:
            Picker("Correction", selection: $correction) {
                ForEach(GraXpertElaborationService.Correction.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .disabled(isRunning)
            LabeledContent("Smoothing") {
                HStack {
                    Slider(value: $smoothing, in: 0...1)
                    Text(String(format: "%.2f", smoothing)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            .disabled(isRunning)
        case .denoising:
            LabeledContent("Strength") {
                HStack {
                    Slider(value: $denoiseStrength, in: 0...1)
                    Text(String(format: "%.2f", denoiseStrength)).font(.caption.monospacedDigit()).frame(width: 36, alignment: .trailing)
                }
            }
            .disabled(isRunning)
        }
    }

    private var operationExplanation: String {
        switch operation {
        case .backgroundExtraction:
            return "Models and removes gradients — light pollution, vignetting, moon glow — that Siril's own stacking doesn't correct for."
        case .denoising:
            return "AI-based noise reduction, tuned for astronomical images rather than a generic photo denoiser."
        }
    }

    private var statusLine: String {
        guard let last = logText.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return isRunning ? "Starting GraXpert…" : ""
        }
        return String(last)
    }

    private func openInGraXpert() {
        try? GraXpertAppLauncher.open(inputURL)
    }

    private func run() async {
        isRunning = true
        errorMessage = nil
        logText = ""
        defer { isRunning = false }
        let parameters = GraXpertElaborationService.Parameters(
            correction: correction, smoothing: smoothing, denoiseStrength: denoiseStrength, useGPU: useGPU
        )
        do {
            let sink = GraXpertLogSink(self)
            completedImage = try await onRun(operation, parameters) { chunk in sink.update(chunk) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Bridges `onRun`'s `@Sendable` log callback back onto the main actor — same reasoning as
/// `ElaborateSheet`'s own `LogSink`.
@MainActor
private final class GraXpertLogSink {
    private let owner: GraXpertSheet
    init(_ owner: GraXpertSheet) { self.owner = owner }

    nonisolated func update(_ text: String) {
        Task { @MainActor in owner.logText = text }
    }
}

/// Shown instead of `GraXpertSheet` when GraXpert integration is off — same pattern as
/// `SirilDisabledPrompt`.
struct GraXpertDisabledPrompt: View {
    var onOpenSettings: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("GraXpert Integration Is Off")
                .font(.headline)
            Text("Sending an elaborated image to GraXpert for gradient removal or denoising needs GraXpert integration turned on first — it's off by default since GraXpert is a separate app this doesn't bundle.")
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
