import AppKit
import SwiftUI

/// Composes several overlapping-but-offset captures (different tiles of the Moon swept across
/// its disk, adjacent fields of a wide object like Andromeda) into one larger image via real
/// star-pattern tile registration (`MosaicComposer`) — distinct from `PlanetaryPostProcessingView`
/// (which stacks a `.ser` burst all sharing the *same* field of view) and
/// `SingleImagePostProcessingView` (a single still, no compositing at all). Reuses
/// `ImageAdjustmentsControls`/`ImageEditor` for the same touch-up pass every other post-processing
/// screen already offers, once the tiles themselves are stitched together.
struct MosaicComposerView: View {
    /// `.mosaic` stitches deliberately-offset tiles side by side into a wider frame
    /// (`MosaicComposer`); `.stack` instead aligns and averages captures that already share
    /// (roughly) the same field of view (`StillImageStacker`) — the same "combine several
    /// captures" screen either way, just a different compose function and a couple of labels.
    enum Mode { case mosaic, stack }

    let mode: Mode
    let sourceURLs: [URL]
    let sourceDescription: String
    /// See `SingleImagePostProcessingView`'s own doc comment on this — just enough for the
    /// "Saved as…" banner's "Publish to AstroBin…" button to point at the right file.
    let elaboratedImagesFolderURL: URL
    var onSave: (CGImage) async throws -> ElaboratedImage
    /// Closes this view's own window — see `SingleImagePostProcessingView.onDismiss`'s own doc
    /// comment for why this is a plain closure, not `@Environment(\.dismiss)`.
    var onDismiss: () -> Void

    private enum Stage: Equatable { case composing, ready, failed }
    @State private var stage: Stage = .composing
    @State private var progressText = "Detecting stars…"
    @State private var errorMessage: String?

    /// The raw stitched result, never mutated — `ImageAdjustmentsControls`' sliders all render
    /// from this, the same "adjustments layer on top of an untouched source" idea
    /// `SingleImagePostProcessingView.originalImage`/`workingImage` already use.
    @State private var composedImage: CGImage?
    @State private var previewImage: CGImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var adjustments = ImageEditor.Adjustments()
    /// One line per tile left out of the result and why — either it failed to load (a corrupt/
    /// incomplete capture) or, `.stack` mode only, it didn't share enough stars with the
    /// reference to align — rather than failing the whole compose, as long as enough tiles
    /// remain to actually produce something.
    @State private var skippedTileNotes: [String] = []

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
            case .composing:
                Spacer()
                ProgressView(progressText)
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
        .frame(minWidth: Self.minWindowSize.width, maxWidth: .infinity, minHeight: Self.minWindowSize.height, maxHeight: .infinity)
        .background(.background)
        .task { await compose() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(mode == .mosaic ? "Mosaic Composer" : "Stack Captures").font(.headline)
                Text(sourceDescription).font(.caption).foregroundStyle(.secondary)
                ForEach(skippedTileNotes, id: \.self) { note in
                    Text("⚠️ Skipped \(note)").font(.caption).foregroundStyle(.orange)
                }
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

    private func compose() async {
        let urls = sourceURLs
        do {
            // A tile that fails to load (a corrupt/truncated file — e.g. a capture whose write
            // got interrupted) is skipped rather than failing the whole compose; only bail out
            // here if too few loadable tiles are left, which `MosaicComposer`/`StillImageStacker`
            // would reject as `.tooFewTiles` anyway. `tileNames` tracks alongside `tiles` so a
            // later stack-alignment skip (see the `.stack` case below) can still be reported by
            // filename, not just a bare index.
            let (tiles, tileNames, loadFailures) = try await Task.detached(priority: .userInitiated) {
                var tiles: [CGImage] = []
                var tileNames: [String] = []
                var loadFailures: [String] = []
                for url in urls {
                    if let image = try? CGImageRenderer.loadDisplayImage(from: url) {
                        tiles.append(image)
                        tileNames.append(url.lastPathComponent)
                    } else {
                        loadFailures.append(url.lastPathComponent)
                    }
                }
                return (tiles, tileNames, loadFailures)
            }.value
            var notes = loadFailures.map { "\($0) — couldn't be read" }
            skippedTileNotes = notes
            guard tiles.count >= 2 else { throw MosaicComposer.ComposeError.tooFewTiles }

            let sink = MosaicProgressSink { text in progressText = text }
            let composed: CGImage
            switch mode {
            case .mosaic:
                composed = try await Task.detached(priority: .userInitiated) {
                    try MosaicComposer.compose(tiles: tiles) { index, total in
                        sink.report(tileIndex: index, total: total)
                    }
                }.value
            case .stack:
                let result = try await Task.detached(priority: .userInitiated) {
                    try StillImageStacker.stack(tiles: tiles) { index, total in
                        sink.report(tileIndex: index, total: total)
                    }
                }.value
                composed = result.image
                notes.append(contentsOf: result.skippedTileIndices.map {
                    "\(tileNames[$0]) — doesn't share enough stars with the first capture to align"
                })
                skippedTileNotes = notes
            }
            composedImage = composed
            previewImage = composed
            stage = .ready
        } catch let error as MosaicComposer.ComposeError {
            errorMessage = Self.describe(error, mode: mode)
            stage = .failed
        } catch {
            errorMessage = "Couldn't compose these captures: \(error.localizedDescription)"
            stage = .failed
        }
    }

    private static func describe(_ error: MosaicComposer.ComposeError, mode: Mode) -> String {
        switch error {
        case .tooFewTiles:
            return mode == .mosaic
                ? "A mosaic needs at least two loadable captures to compose together."
                : "A stack needs at least two captures that both load and align with each other — either too few loaded, or none of the others shared enough stars with the first capture to combine."
        case .insufficientOverlap(let tileIndex):
            return mode == .mosaic
                ? "Tile \(tileIndex + 1) doesn't share enough stars with the tile before it to line up — they may not actually overlap, or the field is too sparse to register."
                : "Capture \(tileIndex + 1) doesn't share enough stars with the first capture to align — they may not actually be the same field, or the field is too sparse to register."
        case .renderFailed:
            return "Couldn't render the result."
        }
    }

    /// See `SingleImagePostProcessingView.scheduleRender`'s own doc comment for why this runs
    /// directly inside a plain `Task` rather than detaching — the same reasoning applies verbatim
    /// (`ImageEditor.render` is GPU-backed and cheap; `CGImage` isn't `Sendable`-annotated).
    private func scheduleRender() {
        renderTask?.cancel()
        guard let composedImage else { return }
        let adj = adjustments
        renderTask = Task {
            guard !Task.isCancelled else { return }
            previewImage = ImageEditor.render(composedImage, with: adj) ?? composedImage
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
}

/// Bridges `MosaicComposer.compose`'s `nonisolated` background-thread progress callback to the
/// main actor — the same "final class wrapping a `Task { @MainActor in ... }` hop" shape
/// `PlanetaryPostProcessingView`'s own `ProgressSink` already uses, scoped down to the one line
/// this view actually shows.
private final class MosaicProgressSink: Sendable {
    private let update: @MainActor (String) -> Void

    init(update: @escaping @MainActor (String) -> Void) {
        self.update = update
    }

    nonisolated func report(tileIndex: Int, total: Int) {
        Task { @MainActor in
            update("Registering tile \(tileIndex + 1) of \(total)…")
        }
    }
}
