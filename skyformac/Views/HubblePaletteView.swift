import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Combines three separately-captured monochrome narrowband channels (Sulfur-II, Hydrogen-alpha,
/// Oxygen-III) — each a still image or a video/`.ser` burst, reduced to one representative stacked
/// frame — into one false-color "Hubble/SHO Palette" composite (`HubblePaletteCombiner`). A
/// standalone tool (reached from Home's own "Common Tasks," not from inside any one project/
/// session) since its three inputs are independent files, not something already living in one
/// session's own captures the way `MosaicComposerView`'s tiles are. Reuses
/// `ImageAdjustmentsControls`/`ImageEditor` for the same touch-up pass every other post-processing
/// screen already offers, once the three channels are actually combined.
struct HubblePaletteView: View {
    var cameraManager: CameraManager
    var onDismiss: () -> Void

    private enum ChannelSlot: String, CaseIterable, Identifiable {
        case sii = "Sulfur (SII)"
        case ha = "Hydrogen-Alpha (Hα)"
        case oiii = "Oxygen (OIII)"
        var id: String { rawValue }
        var mappedChannelName: String {
            switch self {
            case .sii: return "Red"
            case .ha: return "Green"
            case .oiii: return "Blue"
            }
        }
    }

    private enum Stage: Equatable { case setup, combining, ready, failed }

    @State private var stage: Stage = .setup
    @State private var siiURL: URL?
    @State private var haURL: URL?
    @State private var oiiiURL: URL?
    @State private var alignChannels = true
    @State private var progressText = ""
    @State private var errorMessage: String?

    /// The raw combined result, never mutated — same "adjustments layer on top of an untouched
    /// source" idea `MosaicComposerView.composedImage`/`SingleImagePostProcessingView.originalImage`
    /// already use.
    @State private var composedImage: CGImage?
    @State private var previewImage: CGImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var adjustments = ImageEditor.Adjustments()

    @State private var isPickingProject = false
    @State private var isSaving = false
    @State private var savedImage: ElaboratedImage?
    @State private var saveErrorMessage: String?

    static var fullScreenSize: CGSize { PlanetaryPostProcessingView.fullScreenSize }
    static var minWindowSize: NSSize { PlanetaryPostProcessingView.minWindowSize }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch stage {
            case .setup:
                setupBody
            case .combining:
                Spacer()
                ProgressView(progressText)
                Spacer()
            case .failed:
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.red)
                    Text(errorMessage ?? "Something went wrong.").font(.callout).foregroundStyle(.secondary)
                    Button("Back") { stage = .setup }
                }
                Spacer()
            case .ready:
                readyBody
            }
        }
        .frame(minWidth: Self.minWindowSize.width, maxWidth: .infinity, minHeight: Self.minWindowSize.height, maxHeight: .infinity)
        .background(.background)
        .sheet(isPresented: $isPickingProject) {
            HubblePaletteProjectPickerSheet(candidates: cameraManager.projectsLibrary.activeProjects) { project in
                Task { await save(to: project) }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Hubble Palette").font(.headline)
                Text("Sulfur → Red, Hydrogen-alpha → Green, Oxygen → Blue").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let savedImage {
                Label("Saved as \(savedImage.fileName)", systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Button("Done") { onDismiss() }.keyboardShortcut(.defaultAction)
            } else if stage == .ready {
                if let saveErrorMessage {
                    Text(saveErrorMessage).font(.caption).foregroundStyle(.red)
                }
                Button("Cancel") { onDismiss() }
                Button {
                    isPickingProject = true
                } label: {
                    if isSaving { ProgressView().controlSize(.small) } else { Text("Save to Project…") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(previewImage == nil || isSaving)
            } else {
                Button("Cancel") { onDismiss() }
            }
        }
        .padding(16)
    }

    private var setupBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(ChannelSlot.allCases) { slot in
                    channelPickerRow(slot)
                }
                Toggle("Align channels automatically", isOn: $alignChannels)
                    .help("Cross-correlates SII and OIII against Hα before combining — narrowband channels are usually shot in separate sessions, so they rarely start out pixel-aligned.")
                Text("Each channel can be a single still image (PNG/TIFF/FITS/etc.) or a video/.ser burst — a burst is automatically stacked (aligned + averaged) into one representative frame first. All three must be the same pixel size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Combine") { Task { await combine() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(siiURL == nil || haURL == nil || oiiiURL == nil)
            }
            .padding(20)
            .frame(maxWidth: 520, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func channelPickerRow(_ slot: ChannelSlot) -> some View {
        let url = binding(for: slot)
        VStack(alignment: .leading, spacing: 4) {
            Text("\(slot.rawValue) → \(slot.mappedChannelName) Channel").font(.subheadline.bold())
            HStack {
                Text(url.wrappedValue?.lastPathComponent ?? "No file chosen")
                    .font(.callout)
                    .foregroundStyle(url.wrappedValue == nil ? .secondary : .primary)
                    .lineLimit(1)
                Spacer()
                Button(url.wrappedValue == nil ? "Choose…" : "Change…") { pickFile(for: slot) }
            }
        }
    }

    private func binding(for slot: ChannelSlot) -> Binding<URL?> {
        switch slot {
        case .sii: return $siiURL
        case .ha: return $haURL
        case .oiii: return $oiiiURL
        }
    }

    private func pickFile(for slot: ChannelSlot) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.allowedContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        binding(for: slot).wrappedValue = url
    }

    /// Every still-image kind `MediaImporter` recognizes, plus video and `.ser` — a channel can be
    /// either shape, dispatched on extension by `loadChannel(from:label:)`.
    private static let allowedContentTypes: [UTType] = {
        var types: [UTType] = [.png, .jpeg, .tiff, .heic, .quickTimeMovie, .mpeg4Movie]
        for ext in ["ser", "fits", "fit"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    private var readyBody: some View {
        HSplitView {
            ZStack {
                Color.black
                if let previewImage {
                    Image(decorative: previewImage, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(12)
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                ImageAdjustmentsControls(adjustments: $adjustments, onChange: scheduleRender)
                    .padding(16)
            }
            .frame(width: 320)
        }
    }

    // MARK: - Pipeline

    private enum LoadChannelError: Error, LocalizedError {
        case noFrames(String)
        case stackFailed(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .noFrames(let label): return "\(label) has no readable frames."
            case .stackFailed(let label): return "\(label) couldn't be stacked — no frames scored above the minimum signal threshold."
            case .unreadable(let label): return "\(label) couldn't be read as an image."
            }
        }
    }

    private func combine() async {
        guard let siiURL, let haURL, let oiiiURL else { return }
        stage = .combining
        do {
            progressText = "Loading Sulfur (SII)…"
            let sii = try await loadChannel(from: siiURL, label: "Sulfur (SII)")
            progressText = "Loading Hydrogen-Alpha (Hα)…"
            let ha = try await loadChannel(from: haURL, label: "Hydrogen-Alpha (Hα)")
            progressText = "Loading Oxygen (OIII)…"
            let oiii = try await loadChannel(from: oiiiURL, label: "Oxygen (OIII)")
            progressText = alignChannels ? "Aligning and combining channels…" : "Combining channels…"
            let align = alignChannels
            let stacked = try await Task.detached(priority: .userInitiated) {
                try HubblePaletteCombiner.combine(sii: sii, ha: ha, oiii: oiii, alignChannels: align)
            }.value
            let histogram = PlanetaryPostProcessor.histogram(of: stacked)
            let stretch = DisplayStretch.autoStretch(histogram: histogram)
            guard let rendered = PlanetaryPostProcessor.renderImage(
                stacked, blackPoint: stretch?.blackPoint ?? 0, whitePoint: stretch?.whitePoint ?? 1, logStretchIntensity: nil
            ) else {
                errorMessage = "Couldn't render the combined image."
                stage = .failed
                return
            }
            composedImage = rendered
            previewImage = rendered
            stage = .ready
        } catch {
            errorMessage = error.localizedDescription
            stage = .failed
        }
    }

    /// Reduces one channel's source file to a single normalized-luminance frame — a still image
    /// decodes directly; a video/`.ser` burst is stacked first (align + mean-combine every frame,
    /// no "keep best %" trimming — a narrowband channel's own subs are typically all worth
    /// keeping, unlike a lucky-imaging planetary burst) via the same registration/stacking
    /// pipeline `PlanetaryPostProcessingView` itself uses.
    private func loadChannel(from url: URL, label: String) async throws -> HubblePaletteCombiner.ChannelInput {
        let ext = url.pathExtension.lowercased()
        let isVideo = ext == "ser" || MediaImporter.supportedVideoExtensions.contains(ext)
        if isVideo {
            return try await Task.detached(priority: .userInitiated) {
                let sequence = try PlanetaryPostProcessor.loadSequence(from: url)
                guard !sequence.frames.isEmpty else { throw LoadChannelError.noFrames(label) }
                let registered = PlanetaryPostProcessor.scoreAndRegister(
                    frames: sequence.frames, isColorCamera: sequence.isColorCamera, bayerPattern: sequence.bayerPattern
                )
                guard let stacked = PlanetaryPostProcessor.stack(
                    frames: sequence.frames, registered: registered, isColorCamera: sequence.isColorCamera,
                    bayerPattern: sequence.bayerPattern, keepBestPercent: 100, method: .mean
                ) else { throw LoadChannelError.stackFailed(label) }
                return HubblePaletteCombiner.ChannelInput(
                    luminance: monoLuminance(of: stacked), width: stacked.width, height: stacked.height
                )
            }.value
        } else {
            return try await Task.detached(priority: .userInitiated) {
                guard let image = try? CGImageRenderer.loadDisplayImage(from: url),
                      let (values, width, height) = luminance(of: image)
                else { throw LoadChannelError.unreadable(label) }
                return HubblePaletteCombiner.ChannelInput(luminance: values, width: width, height: height)
            }.value
        }
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let composedImage else { return }
        let adj = adjustments
        renderTask = Task {
            guard !Task.isCancelled else { return }
            previewImage = ImageEditor.render(composedImage, with: adj) ?? composedImage
        }
    }

    private func save(to project: Project) async {
        guard let previewImage else { return }
        isSaving = true
        saveErrorMessage = nil
        defer { isSaving = false }
        do {
            let session = Session.newSession(name: "Hubble Palette", goal: "Combine SII/Hα/OIII into a Hubble Palette composite")
            let updatedProject = try cameraManager.projectsLibrary.addSession(session, to: project)
            savedImage = try cameraManager.saveMosaicResult(
                previewImage, sourceSessionIDs: [session.id], project: updatedProject,
                filePrefix: "HubblePalette", toolLabel: "Hubble Palette"
            )
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}

/// `StackedImage.channels == 3` (mean-stacked from a color camera/RGB24 video) reduces to mono the
/// same way every other RGB→luma step in this app does; already-mono (`channels == 1`) passes
/// through untouched.
private func monoLuminance(of stacked: PlanetaryPostProcessor.StackedImage) -> [Float] {
    guard stacked.channels == 3 else { return stacked.values }
    let count = stacked.width * stacked.height
    var luma = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let o = i * 3
        luma[i] = stacked.values[o] * 0.299 + stacked.values[o + 1] * 0.587 + stacked.values[o + 2] * 0.114
    }
    return luma
}

/// Draws `image` into an 8-bit RGBA context (the same "normalize any `CGImage`, regardless of its
/// own native format" technique `GradientExtractor`'s own sampling already uses) and reduces it to
/// normalized `[0, 1]` luminance.
private func luminance(of image: CGImage) -> (values: [Float], width: Int, height: Int)? {
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { return nil }
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
              space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          )
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let count = width * height
    var luma = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let o = i * 4
        luma[i] = (Float(pixels[o]) * 0.299 + Float(pixels[o + 1]) * 0.587 + Float(pixels[o + 2]) * 0.114) / 255
    }
    return (luma, width, height)
}

private struct HubblePaletteProjectPickerSheet: View {
    let candidates: [Project]
    var onPick: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Save to Project").font(.headline).padding()
            Divider()
            if candidates.isEmpty {
                Text("No projects yet — create one first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(candidates) { project in
                    Button {
                        onPick(project)
                        dismiss()
                    } label: {
                        Text(project.name.isEmpty ? "Untitled Project" : project.name)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()
        }
        .frame(width: 360, height: 420)
    }
}
