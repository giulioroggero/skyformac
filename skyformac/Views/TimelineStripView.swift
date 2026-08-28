import SwiftUI

/// A horizontal filmstrip of a session's captures — the iMovie-style "timeline with thumbnails"
/// the Projects feature is built around. Tapping a thumbnail pushes that capture's own full-width
/// Capture page (`onSelect`); each one's context menu also offers "Delete" (`onDelete`), for
/// reclaiming disk space one capture at a time without deleting the whole session — captures
/// otherwise still arrive in, and stay in, capture order. While `isSelecting` is on (the same
/// "Select" toggle `ProjectsThumbnailGrid` uses), tapping toggles `selectedIDs` instead of
/// opening — "allow the user to select more than one (on timeline and table view)," feeding the
/// same bulk-action bar/multi-capture selection `CapturesTableView`'s native `Table` selection
/// already does.
struct TimelineStripView: View {
    let project: Project
    let session: Session
    let store: ProjectStore
    var cameraManager: CameraManager
    var isSelecting: Bool
    @Binding var selectedIDs: Set<CaptureRecord.ID>
    var onSelect: (CaptureRecord) -> Void
    var onDelete: (CaptureRecord) -> Void

    var body: some View {
        if session.captures.isEmpty {
            ContentUnavailableView(
                "No Captures Yet", systemImage: "film",
                description: Text("Frames exported or recorded while this session is active will show up here.")
            )
            .frame(height: 140)
        } else {
            // Oldest first, left to right — matches `ObservationTimelineView`'s own convention on
            // the Home page (most recent capture on the right, `.defaultScrollAnchor(.trailing)`
            // there too), which this previously disagreed with by sorting the opposite way.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(session.captures.sorted(by: { $0.date < $1.date })) { capture in
                        TimelineThumbnailView(
                            project: project, session: session, capture: capture, store: store,
                            cameraManager: cameraManager, isSelecting: isSelecting,
                            isSelected: selectedIDs.contains(capture.id), onDelete: onDelete
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if isSelecting {
                                if selectedIDs.contains(capture.id) { selectedIDs.remove(capture.id) }
                                else { selectedIDs.insert(capture.id) }
                            } else {
                                onSelect(capture)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .defaultScrollAnchor(.trailing)
            .frame(height: 190)
        }
    }
}

private struct TimelineThumbnailView: View {
    let project: Project
    let session: Session
    let capture: CaptureRecord
    let store: ProjectStore
    var cameraManager: CameraManager
    var isSelecting: Bool
    var isSelected: Bool
    var onDelete: (CaptureRecord) -> Void

    @State private var isConfirmingDelete = false
    @State private var isElaborating = false
    @State private var isPromptingSirilSettings = false
    /// "If the user press on the icon she can post process the capture" — the kind badge's own
    /// tap target, bypassing the Capture page entirely for the common "just process this" case.
    /// "The edit/preview windows can be moved across the screen and resized" — see
    /// `CaptureDetailPage`'s identical property doc comment for why this is a
    /// `DetachedContentWindowController?` rather than the `Bool` + `.sheet` these used to be.
    @State private var postProcessingWindowController: DetachedContentWindowController?
    @State private var editingImageWindowController: DetachedContentWindowController?

    private var fileURL: URL {
        store.sessionFolderURL(for: session, in: project).appendingPathComponent(capture.fileName)
    }

    private var thumbnailURL: URL? {
        guard let name = capture.thumbnailFileName else { return nil }
        return store.thumbnailsFolderURL(for: session, in: project).appendingPathComponent(name)
    }

    private var diskUsageText: String {
        ByteCountFormatter.string(fromByteCount: store.diskUsage(for: capture, in: session, project: project), countStyle: .file)
    }

    /// Suppressed while selecting — this tap target jumping straight into single-capture
    /// post-processing would fight with "pick several, then act." A separate property (not a
    /// ternary inline in `thumbnail` below) since that inline form was part of what made the type
    /// checker choke on the whole view (see `thumbnail`'s own doc comment).
    private var kindBadgeAction: (() -> Void)? {
        if isSelecting { return nil }
        return { startPostProcessing() }
    }

    /// Pulled out of `body` as its own property — chaining `.overlay` for both the kind badge and
    /// the selection checkmark directly inside `body`'s own `VStack` made the whole expression
    /// too complex for the type checker to solve ("failed to produce diagnostic for expression").
    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let thumbnailURL, let image = ThumbnailCache.image(at: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: capture.kind.icon)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 130, height: 90)
        .overlay(alignment: .bottomTrailing) {
            CaptureKindBadge(kind: capture.kind, action: kindBadgeAction)
                .padding(4)
        }
        .overlay(alignment: .topLeading) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .background(Circle().fill(.background))
                    .padding(4)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            thumbnail

            Text(capture.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(capture.kind.displayName)
                Text("·")
                Text(diskUsageText)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            // The plain-English "what actually happened" note `CameraManager` records alongside
            // the file itself (see `CameraManager.captureActionNote`) — shown right on the
            // timeline, not just on the capture's own full-width page, since it's the whole point
            // of a timeline: recognizing what happened without opening each entry.
            if let note = capture.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(width: 130, alignment: .leading)
        .help(capture.note ?? capture.fileName)
        .contextMenu {
            Button("Show in Finder") {
                let url = store.sessionFolderURL(for: session, in: project).appendingPathComponent(capture.fileName)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if elaborationSource != nil {
                Button("Open in Siril…", systemImage: "wand.and.stars") { startElaborating() }
            }
            Button("Delete…", systemImage: "trash", role: .destructive) {
                isConfirmingDelete = true
            }
        }
        .confirmationDialog(
            "Delete this capture?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete \(capture.fileName)", role: .destructive) { onDelete(capture) }
        } message: {
            Text("This removes the file (\(diskUsageText)) and its thumbnail from disk — this can't be undone.")
        }
        .sheet(isPresented: $isPromptingSirilSettings) {
            SirilDisabledPrompt(onOpenSettings: { cameraManager.isSettingsPresented = true })
        }
        .sheet(isPresented: $isElaborating) {
            if let (source, target) = elaborationSource {
                ElaborateSheet(
                    source: source,
                    suggestedRecipe: SirilElaborationService.resolveRecipe(for: source, target: target),
                    sourceDescription: "Elaborating \(capture.fileName)."
                ) { recipe, parameters, onLog in
                    try await cameraManager.elaborate(
                        source: source, recipe: recipe, sourceSessionIDs: [session.id],
                        sourceCaptureID: capture.id, project: project, parameters: parameters, onLog: onLog
                    )
                }
            }
        }
    }

    /// `nil` when this capture's `kind` isn't something Siril can process further (a `.png`/
    /// `.tiff` export is already debayered/stretched) — see
    /// `CameraManager.elaborationSource(forCaptureID:in:project:)`.
    private var elaborationSource: (SirilElaborationService.Source, AcquisitionTarget?)? {
        cameraManager.elaborationSource(forCaptureID: capture.id, in: session, project: project)
    }

    /// `CaptureKindBadge`'s tap target — the same two Skyformac tools `CaptureDetailPage`'s own
    /// Process group offers, routed by kind (`.serVideo` → Planetary Post-Processing, a still
    /// image → Edit Image); `CaptureKindBadge` itself never offers a tap for anything else.
    private func startPostProcessing() {
        switch capture.kind {
        case .serVideo: openPostProcessingWindow()
        case .fits, .png, .tiff: openEditingImageWindow()
        case .recording, .video: break
        }
    }

    private func openPostProcessingWindow() {
        postProcessingWindowController = DetachedContentWindowController(
            title: "Planetary Post-Processing — \(capture.fileName)", contentSize: PlanetaryPostProcessingView.fullScreenSize,
            minSize: PlanetaryPostProcessingView.minWindowSize,
            onClose: { postProcessingWindowController = nil }
        ) {
            PlanetaryPostProcessingView(
                sourceURLs: [fileURL],
                sourceDescription: "Post-processing \(capture.fileName).",
                onSave: { cgImage, title, notes, settings in
                    try cameraManager.savePlanetaryPostProcessingResult(
                        cgImage, sourceSessionIDs: [session.id], sourceCaptureID: capture.id, project: project,
                        title: title, notes: notes, settings: settings
                    )
                },
                onOverwrite: { cgImage, existing, title, notes, settings in
                    try cameraManager.overwritePlanetaryPostProcessingResult(
                        cgImage, existing: existing, project: project, title: title, notes: notes, settings: settings
                    )
                },
                resolveGraXpertInputURL: { image in
                    store.elaboratedImagesFolderURL(for: project).appendingPathComponent(image.fileName)
                },
                onSendToGraXpert: { inputURL, operation, parameters, onLog in
                    try await cameraManager.sendToGraXpert(
                        inputURL: inputURL, operation: operation, sourceSessionIDs: [session.id],
                        sourceCaptureID: capture.id, project: project, parameters: parameters, onLog: onLog
                    )
                },
                onOpenGraXpertSettings: { cameraManager.isSettingsPresented = true },
                onDismiss: { postProcessingWindowController?.close() }
            )
        }
        postProcessingWindowController?.showWindow(nil)
    }

    private func openEditingImageWindow() {
        editingImageWindowController = DetachedContentWindowController(
            title: "Edit Image — \(capture.fileName)", contentSize: SingleImagePostProcessingView.fullScreenSize,
            minSize: SingleImagePostProcessingView.minWindowSize,
            onClose: { editingImageWindowController = nil }
        ) {
            SingleImagePostProcessingView(
                sourceURL: fileURL,
                sourceDescription: "Editing \(capture.fileName).",
                elaboratedImagesFolderURL: store.elaboratedImagesFolderURL(for: project),
                onSave: { cgImage in
                    try cameraManager.saveImageEditResult(
                        cgImage, sourceSessionIDs: [session.id], sourceCaptureID: capture.id, project: project
                    )
                },
                onDismiss: { editingImageWindowController?.close() }
            )
        }
        editingImageWindowController?.showWindow(nil)
    }

    private func startElaborating() {
        if AppSettings.isSirilIntegrationEnabled {
            isElaborating = true
        } else {
            isPromptingSirilSettings = true
        }
    }
}
