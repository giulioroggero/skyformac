import SwiftUI

/// In-app viewer for a FITS/PNG/TIFF file opened via `CameraManager.openExportedFile(_:)` — the
/// "elaborate them" half of the Exported Files section: not just a launchpad to Finder/another
/// tool, but somewhere to actually look at a file (with the same debayer/stretch pipeline the
/// live preview uses, for a raw FITS frame) without leaving the app. Deliberately stops there —
/// no editing, no re-stacking, no plate solving; that's the same scope line this app already
/// draws everywhere else (see `docs/design-notes.md`'s running list of what's intentionally left
/// to dedicated tools like PixInsight/Siril/AutoStakkert!3).
struct ExportedFileViewerView: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    @State private var blackPoint: Double = 0
    @State private var whitePoint: Double = 1
    @State private var isColorOverride: Bool?
    @State private var bayerPatternOverride: ASI_BAYER_PATTERN = ASI_BAYER_RG

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(minWidth: 640, minHeight: 480)
                .background(Color.black)

            Divider()
            footer
                .padding(10)
        }
        .frame(minWidth: 680, minHeight: 560)
        .onAppear { resetControlsForCurrentFile() }
    }

    @ViewBuilder
    private var content: some View {
        switch cameraManager.viewingExportedFile {
        case .rawFrame(let parsed, _):
            rawFrameView(parsed)
        case .image(let image, _):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .error(let message):
            ContentUnavailableView(
                "Couldn't Open File", systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
            .foregroundStyle(.white)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private func rawFrameView(_ parsed: FITSReader.ParsedFITS) -> some View {
        VStack(spacing: 0) {
            if let rendered = renderedImage(parsed) {
                Image(decorative: rendered, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ContentUnavailableView("Couldn't Render This Frame", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Black Point").font(.caption).frame(width: 80, alignment: .leading)
                    Slider(value: $blackPoint, in: 0...max(whitePoint - 0.001, 0.001))
                    Text(String(format: "%.1f%%", blackPoint * 100)).font(.caption.monospacedDigit()).frame(width: 50)
                }
                HStack {
                    Text("White Point").font(.caption).frame(width: 80, alignment: .leading)
                    Slider(value: $whitePoint, in: min(blackPoint + 0.001, 0.999)...1)
                    Text(String(format: "%.1f%%", whitePoint * 100)).font(.caption.monospacedDigit()).frame(width: 50)
                }
                HStack {
                    Toggle("Debayer as color", isOn: Binding(
                        get: { isColorOverride ?? parsed.isColorCamera },
                        set: { isColorOverride = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    if isColorOverride ?? parsed.isColorCamera {
                        Picker("Pattern", selection: $bayerPatternOverride) {
                            Text("RGGB").tag(ASI_BAYER_RG)
                            Text("BGGR").tag(ASI_BAYER_BG)
                            Text("GRBG").tag(ASI_BAYER_GR)
                            Text("GBRG").tag(ASI_BAYER_GB)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 220)
                    }
                    Spacer()
                }
                .font(.caption)
            }
            .padding(10)
            .background(.black.opacity(0.6))
            .foregroundStyle(.white)
        }
    }

    private func renderedImage(_ parsed: FITSReader.ParsedFITS) -> CGImage? {
        let stretch = DisplayStretch(blackPoint: blackPoint, whitePoint: max(whitePoint, blackPoint + 0.001))
        return CGImageRenderer.makeDisplayImage(
            from: parsed.frame,
            isColorCamera: isColorOverride ?? parsed.isColorCamera,
            bayerPattern: bayerPatternOverride,
            stretch: stretch
        )
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            if let url = currentFileURL {
                Text(url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Spacer()
            Button("Done") {
                cameraManager.viewingExportedFile = nil
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var currentFileURL: URL? {
        switch cameraManager.viewingExportedFile {
        case .rawFrame(_, let url), .image(_, let url): return url
        case .error, nil: return nil
        }
    }

    /// Re-derives a sensible starting stretch (and resets the color override) every time a
    /// *different* file is opened — without this, black/white point sliders left from a
    /// previously-viewed file would carry over and likely render the next one solid black/white.
    private func resetControlsForCurrentFile() {
        isColorOverride = nil
        guard case .rawFrame(let parsed, _) = cameraManager.viewingExportedFile else { return }
        bayerPatternOverride = parsed.bayerPattern
        if let auto = DisplayStretch.autoStretch(histogram: HistogramComputer.histogram(for: parsed.frame)) {
            blackPoint = auto.blackPoint
            whitePoint = auto.whitePoint
        } else {
            blackPoint = 0
            whitePoint = 1
        }
    }
}
