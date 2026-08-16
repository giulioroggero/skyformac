import SwiftUI

/// Pushed when a Session page's timeline thumbnail is tapped — a full-width page (no side
/// margins, same as `SessionDetailPane`) showing a larger preview of that one capture, its file
/// info, the session it belongs to (so its context is visible without a trip back), and the same
/// session-level Stats every Session page shows.
struct CaptureDetailPage: View {
    let project: Project
    let session: Session
    let capture: CaptureRecord
    var cameraManager: CameraManager
    /// Pops back to this capture's own Session page.
    var onBack: () -> Void
    /// Steps to the previous/next capture within this same session's timeline (newest first,
    /// matching `TimelineStripView`'s own display order). `nil` — not a no-op closure — when this
    /// is the first/last capture, so the toolbar button is hidden entirely.
    var onPreviousCapture: (() -> Void)?
    var onNextCapture: (() -> Void)?

    @State private var isElaborating = false
    @State private var isPromptingSirilSettings = false

    private var store: ProjectStore { cameraManager.projectStore }

    private var fileURL: URL {
        store.sessionFolderURL(for: session, in: project).appendingPathComponent(capture.fileName)
    }

    private var thumbnailURL: URL? {
        guard let name = capture.thumbnailFileName else { return nil }
        return store.thumbnailsFolderURL(for: session, in: project).appendingPathComponent(name)
    }

    /// `NSImage` decodes PNG/TIFF directly; FITS/SER video/a continuous-recording folder aren't
    /// formats it understands at all, so those fall back to the already-generated thumbnail
    /// instead of silently showing nothing.
    private var previewImage: NSImage? {
        switch capture.kind {
        case .png, .tiff:
            return ThumbnailCache.image(at: fileURL) ?? thumbnailURL.flatMap(ThumbnailCache.image(at:))
        case .fits, .serVideo, .recording:
            return thumbnailURL.flatMap(ThumbnailCache.image(at:))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection {
                    HStack {
                        Spacer(minLength: 0)
                        Group {
                            if let previewImage {
                                Image(nsImage: previewImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 480)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: capture.kind.icon).font(.system(size: 48)).foregroundStyle(.secondary)
                                    Text("No preview available for \(capture.kind.displayName) files")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(height: 240)
                            }
                        }
                        // Directly on/beside the image itself — not just the toolbar's own
                        // Previous/Next Capture buttons, which sit far from what they're actually
                        // stepping through — the same "step through siblings from right where
                        // you're looking at one" idea as a standard photo browser.
                        .overlay(alignment: .leading) {
                            if let onPreviousCapture {
                                captureStepButton(label: "Previous Capture", systemImage: "chevron.left", action: onPreviousCapture)
                            }
                        }
                        .overlay(alignment: .trailing) {
                            if let onNextCapture {
                                captureStepButton(label: "Next Capture", systemImage: "chevron.right", action: onNextCapture)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }

                PageSection(title: "File") {
                    StatsGridView(stats: fileStats)
                    if let note = capture.note, !note.isEmpty {
                        Text(note).font(.callout)
                    }
                    RatingView(rating: capture.rating) { newRating in
                        var updatedSession = session
                        guard let index = updatedSession.captures.firstIndex(where: { $0.id == capture.id }) else { return }
                        updatedSession.captures[index].rating = newRating
                        var updatedProject = project
                        guard let sessionIndex = updatedProject.sessions.firstIndex(where: { $0.id == session.id }) else { return }
                        updatedProject.sessions[sessionIndex] = updatedSession
                        try? cameraManager.projectsLibrary.save(updatedProject)
                    }
                    HStack {
                        // FITS gets the app's own real viewer (black/white-point stretch,
                        // debayer) — nicer than whatever (if anything) the system associates
                        // with the extension. Every other kind (SER, a continuous-recording
                        // folder, PNG/TIFF) opens in whatever the system already handles it
                        // with — "if it's not a capture image ... I want to see it" without
                        // this app needing its own SER/video player.
                        if capture.kind == .fits {
                            Button("Open in Viewer", systemImage: "eye") {
                                cameraManager.openExportedFile(fileURL)
                            }
                        } else {
                            Button("Open", systemImage: "arrow.up.forward.app") {
                                NSWorkspace.shared.open(fileURL)
                            }
                        }
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                        }
                        if elaborationSource != nil {
                            Button("Elaborate…", systemImage: "wand.and.stars") { startElaborating() }
                        }
                    }
                }

                if let cameraSettingsStats {
                    PageSection(title: "Camera Settings") {
                        StatsGridView(stats: cameraSettingsStats)
                    }
                }

                PageSection(title: "Session") {
                    StatsGridView(stats: sessionContextStats)
                }

                if !session.captures.isEmpty {
                    PageSection(title: "Stats") {
                        StatsGridView(stats: sessionCaptureStats)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("\(project.name.isEmpty ? "Untitled Project" : project.name) — \(session.name) — \(capture.fileName)")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back to Session", systemImage: "chevron.left", action: onBack)
            }
            ToolbarItemGroup {
                if let onPreviousCapture {
                    Button("Previous Capture", systemImage: "chevron.up", action: onPreviousCapture)
                }
                if let onNextCapture {
                    Button("Next Capture", systemImage: "chevron.down", action: onNextCapture)
                }
            }
        }
        // FITS's "Open in Viewer" button (above) sets `cameraManager.viewingExportedFile` —
        // `ContentView` already has the equivalent `.sheet` for the live camera view, but this
        // page lives on the Projects-browsing side of the app (`ContentView` only exists while a
        // session is active), so it needs its own.
        .sheet(isPresented: Binding(
            get: { cameraManager.viewingExportedFile != nil },
            set: { if !$0 { cameraManager.viewingExportedFile = nil } }
        )) {
            ExportedFileViewerView(cameraManager: cameraManager)
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
                ) { recipe in
                    try await cameraManager.elaborate(
                        source: source, recipe: recipe, sourceSessionIDs: [session.id],
                        sourceCaptureID: capture.id, project: project
                    )
                }
            }
        }
    }

    /// `nil` when this capture's `kind` isn't something Siril can process further — see
    /// `CameraManager.elaborationSource(forCaptureID:in:project:)`.
    private var elaborationSource: (SirilElaborationService.Source, AcquisitionTarget?)? {
        cameraManager.elaborationSource(forCaptureID: capture.id, in: session, project: project)
    }

    private func startElaborating() {
        if AppSettings.isSirilIntegrationEnabled {
            isElaborating = true
        } else {
            isPromptingSirilSettings = true
        }
    }

    @ViewBuilder
    private func captureStepButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.large)
            .padding(10)
            .background(.thinMaterial, in: Circle())
            .padding(12)
            .help(label)
    }

    private var fileStats: [StatItem] {
        [
            StatItem(label: "File", value: capture.fileName),
            StatItem(label: "Kind", value: capture.kind.displayName),
            StatItem(label: "Date", value: capture.date.formatted(date: .abbreviated, time: .shortened)),
        ]
    }

    /// "All details about camera settings" for this specific capture — `nil` for a capture
    /// recorded before `preset` existed (an older saved session), so the section itself just
    /// doesn't show rather than showing a block of "—" placeholders.
    private var cameraSettingsStats: [StatItem]? {
        guard let preset = capture.preset else { return nil }
        var stats = [StatItem(label: "Mode", value: preset.mode.label)]
        if let gain = preset.gain { stats.append(StatItem(label: "Gain", value: "\(gain)")) }
        if let exposureSeconds = preset.exposureSeconds {
            let formatted = exposureSeconds.formatted(.number.precision(.fractionLength(0...3)))
            stats.append(StatItem(label: "Exposure", value: "\(formatted)s"))
        }
        if let roiWidth = preset.roiWidth, let roiHeight = preset.roiHeight {
            stats.append(StatItem(label: "ROI", value: "\(roiWidth)×\(roiHeight)"))
        }
        if preset.mode.usesLiveStack {
            stats.append(StatItem(label: "Drift Reduction", value: preset.isDriftReductionEnabled ? "On" : "Off"))
            stats.append(StatItem(label: "Smart Live Stack", value: preset.isSmartLiveStackEnabled ? "On" : "Off"))
            if preset.isMeshDriftCorrectionEnabled == true {
                stats.append(StatItem(label: "Mesh Drift Correction", value: "On"))
            }
        }
        if let luckyBurstCount = preset.luckyBurstCount {
            stats.append(StatItem(label: "Lucky Imaging Burst", value: "\(luckyBurstCount) frames"))
        }
        if let serDurationSeconds = preset.serDurationSeconds {
            stats.append(StatItem(label: "SER Duration", value: "\(Int(serDurationSeconds))s"))
        }
        return stats
    }

    private var sessionContextStats: [StatItem] {
        var stats = [
            StatItem(label: "Session", value: session.name),
            StatItem(label: "Aim", value: session.goal.isEmpty ? "—" : session.goal),
            StatItem(label: "Objects", value: session.plannedObjects.isEmpty ? "—" : session.plannedObjects.joined(separator: ", ")),
        ]
        if let location = session.effectiveLocation(inProject: project) {
            stats.append(StatItem(label: "Position", value: location.displayName))
        }
        return stats
    }

    private var sessionCaptureStats: [StatItem] {
        var stats = [StatItem(label: "Total Captures", value: "\(session.captures.count)")]
        for kind in CaptureRecord.Kind.allCases {
            if let count = session.captureCountByKind[kind] {
                stats.append(StatItem(label: kind.displayName, value: "\(count)"))
            }
        }
        return stats
    }
}
