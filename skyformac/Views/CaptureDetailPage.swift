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
    /// Jumps all the way back to the Projects browser's Home page, regardless of how deep the
    /// navigation stack is — see `SessionDetailPane.onHome`'s doc comment for the full reasoning.
    var onHome: () -> Void
    /// Steps to the previous/next capture within this same session's timeline (newest first,
    /// matching `TimelineStripView`'s own display order). `nil` — not a no-op closure — when this
    /// is the first/last capture, so the toolbar button is hidden entirely.
    var onPreviousCapture: (() -> Void)?
    var onNextCapture: (() -> Void)?

    @State private var isElaborating = false
    /// "The edit/preview windows can be moved across the screen and resized" — each of these
    /// three opens a real `NSWindow` via `DetachedContentWindowController` (not a `.sheet`, which
    /// is permanently attached below this page's own window and can never be dragged/resized
    /// independently), so a plain optional controller replaces what used to be a `Bool` +
    /// `.sheet(isPresented:)`.
    @State private var postProcessingWindowController: DetachedContentWindowController?
    /// "Show a loader until the modal is shown — for GB files it takes some time" — the
    /// prominent "Post-Process…" button's own busy state while its window opens.
    @State private var isOpeningPostProcessingWindow = false
    @State private var editingImageWindowController: DetachedContentWindowController?
    @State private var viewingFullScreenWindowController: DetachedContentWindowController?
    @State private var isPromptingSirilSettings = false
    @State private var isConfirmingDelete = false
    @State private var isMovingToSession = false
    @State private var isSplittingSession = false
    @State private var actionErrorMessage: String?
    /// Keyed to a focusable modifier on the page itself — arrow-key stepping (`onKeyPress` below)
    /// only receives events while this view actually holds keyboard focus, which nothing else on
    /// this page competes for (there's no text field), so it's claimed unconditionally on appear.
    @FocusState private var isFocused: Bool

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
                // Row 1: the image itself.
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
                    HStack {
                        Spacer(minLength: 0)
                        primaryActionButton
                        Spacer(minLength: 0)
                    }
                }

                // Row 2: everything else about this capture — File, Camera Settings, and Session
                // side by side, instead of each taking a full-width row of their own. No
                // session-wide "Stats" (total captures, counts by kind) here — that's the
                // session's own aggregate, not a property of this one capture; see the Session
                // page for that.
                HStack(alignment: .top, spacing: 16) {
                    PageSection {
                        sectionHeader("File", copying: fileStats)
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
                        actionsList
                    }

                    if let cameraSettingsStats {
                        PageSection {
                            sectionHeader("Camera Settings", copying: cameraSettingsStats)
                            StatsGridView(stats: cameraSettingsStats)
                            if let preset = capture.preset {
                                Button("Use These Settings & Open Live", systemImage: "video.fill") {
                                    cameraManager.recallParameters(preset)
                                    cameraManager.setActive(project: project, session: session)
                                }
                                .help("Applies this capture's camera settings (or holds them until a camera connects) and opens \(session.name) live.")
                            }
                        }
                    }

                    PageSection {
                        sectionHeader("Session", copying: sessionContextStats)
                        StatsGridView(stats: sessionContextStats)
                    }
                }

                if !captureElaboratedImages.isEmpty {
                    PageSection(title: "Elaborated") {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(captureElaboratedImages) { image in
                                    ElaboratedImageCard(project: project, image: image, cameraManager: cameraManager)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("\(project.name.isEmpty ? "Untitled Project" : project.name) — \(session.name) — \(capture.fileName)")
        // Left/right arrows step through the timeline the same way clicking the on-image
        // Previous/Next controls does — a plain photo-browser convention, and free once the
        // sibling closures already exist for those buttons. `onKeyPress` only fires while this
        // view holds keyboard focus, hence `.focusable()` + claiming it on appear below.
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(.leftArrow) {
            guard let onPreviousCapture else { return .ignored }
            onPreviousCapture()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard let onNextCapture else { return .ignored }
            onNextCapture()
            return .handled
        }
        // The system's own automatic back chevron only ever pops one level, which would sit right
        // next to `onBack` doing the same thing — hidden in favor of the explicit Home/Back pair
        // below (see `SessionDetailPane`'s identical modifier for the full reasoning).
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Button("Home", systemImage: "house", action: onHome)
                    Button("Back to Session", systemImage: "chevron.left", action: onBack)
                }
            }
            ToolbarItemGroup {
                if let onPreviousCapture {
                    Button("Previous Capture", systemImage: "chevron.up", action: onPreviousCapture)
                }
                if let onNextCapture {
                    Button("Next Capture", systemImage: "chevron.down", action: onNextCapture)
                }
            }
            OpenAssistantToolbarItem(cameraManager: cameraManager)
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
                ) { recipe, parameters, onLog in
                    try await cameraManager.elaborate(
                        source: source, recipe: recipe, sourceSessionIDs: [session.id],
                        sourceCaptureID: capture.id, project: project, parameters: parameters, onLog: onLog
                    )
                }
            }
        }
        .confirmationDialog(
            "Delete this capture?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete \(capture.fileName)", role: .destructive) {
                try? cameraManager.projectsLibrary.deleteCapture(capture.id, fromSessionID: session.id, in: project)
                // The capture this page is showing no longer exists — its own route is now
                // stale, same reasoning as `MoveSessionToProjectSheet`'s success handler in
                // `SessionDetailPane`, so pop back to the (still-valid) Session page.
                onBack()
            }
        } message: {
            let diskUsage = ByteCountFormatter.string(
                fromByteCount: store.diskUsage(for: capture, in: session, project: project), countStyle: .file
            )
            Text("This removes the file (\(diskUsage)) and its thumbnail from disk — this can't be undone.")
        }
        .sheet(isPresented: $isMovingToSession) {
            MoveCaptureToSessionSheet(candidates: moveSessionCandidates) { candidate in
                do {
                    try cameraManager.projectsLibrary.moveCapture(
                        capture.id, fromSessionID: session.id, toSessionID: candidate.session.id,
                        from: project, to: candidate.project
                    )
                    // This capture no longer lives under this session/project — its own route is
                    // now stale, same reasoning as the delete confirmation above.
                    onBack()
                } catch {
                    actionErrorMessage = error.localizedDescription
                }
            }
        }
        .sheet(isPresented: $isSplittingSession) {
            SplitSessionSheet(session: session) { newName in
                do {
                    try cameraManager.projectsLibrary.splitSession(
                        session, atCaptureID: capture.id, newSessionName: newName, in: project
                    )
                    // This capture (and everything after it) just moved to the new session.
                    onBack()
                } catch {
                    actionErrorMessage = error.localizedDescription
                }
            }
        }
        .alert("Couldn't Complete That", isPresented: Binding(
            get: { actionErrorMessage != nil },
            set: { isPresented in if !isPresented { actionErrorMessage = nil } }
        ), presenting: actionErrorMessage) { _ in
            Button("OK") { actionErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    /// Every other active, non-archived session across every project — "Move to Session…"'s own
    /// candidate list, one flat list rather than a two-step project-then-session picker (the same
    /// flattening `RecallParametersView` already uses for "every capture across every session").
    /// Excludes this capture's own current session (nothing to move to).
    fileprivate struct SessionCandidate: Identifiable {
        var id: Session.ID { session.id }
        let project: Project
        let session: Session
    }

    private var moveSessionCandidates: [SessionCandidate] {
        cameraManager.projectsLibrary.activeProjects.flatMap { candidateProject in
            candidateProject.sessions
                .filter { !$0.isArchived && $0.id != session.id }
                .map { SessionCandidate(project: candidateProject, session: $0) }
        }
        // By session name first — that's the prominent label `MoveCaptureToSessionSheet` actually
        // shows (project name is only the small secondary caption underneath), so sorting by
        // project name first left the visible session names looking unsorted, only alphabetical
        // within each project's own run.
        .sorted { ($0.session.name, $0.project.name) < ($1.session.name, $1.project.name) }
    }

    /// `nil` when this capture's `kind` isn't something Siril can process further — see
    /// `CameraManager.elaborationSource(forCaptureID:in:project:)`.
    private var elaborationSource: (SirilElaborationService.Source, AcquisitionTarget?)? {
        cameraManager.elaborationSource(forCaptureID: capture.id, in: session, project: project)
    }

    /// Only results that came from *this* capture specifically — narrower than the session-level
    /// listing on `SessionDetailPane`, which also includes whole-session elaborations with no
    /// single owning capture (`sourceCaptureID == nil`).
    private var captureElaboratedImages: [ElaboratedImage] {
        project.elaboratedImages
            .filter { $0.sourceCaptureID == capture.id }
            .sorted { $0.date > $1.date }
    }

    private func startElaborating() {
        if AppSettings.isSirilIntegrationEnabled {
            isElaborating = true
        } else {
            isPromptingSirilSettings = true
        }
    }

    private func startPostProcessing() {
        // A GB-scale `.ser` capture's own load can take a visible moment — this state change
        // (and the deferred dispatch below) exists purely to guarantee the button's spinner
        // actually gets one real render frame *before* window construction starts, rather than
        // both happening within the same synchronous call and SwiftUI coalescing away the
        // intermediate "loading" state with nothing ever drawn.
        isOpeningPostProcessingWindow = true
        DispatchQueue.main.async {
            startPostProcessingWindow()
            isOpeningPostProcessingWindow = false
        }
    }

    private func startPostProcessingWindow() {
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

    private func startEditingImage() {
        editingImageWindowController = DetachedContentWindowController(
            title: "Edit Image — \(capture.fileName)", contentSize: SingleImagePostProcessingView.fullScreenSize,
            minSize: SingleImagePostProcessingView.minWindowSize,
            onClose: { editingImageWindowController = nil }
        ) {
            SingleImagePostProcessingView(
                sourceURL: fileURL,
                sourceDescription: "Editing \(capture.fileName).",
                elaboratedImagesFolderURL: cameraManager.projectStore.elaboratedImagesFolderURL(for: project),
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

    private func startViewingFullScreen() {
        guard let image = NSImage(contentsOf: fileURL) else { return }
        viewingFullScreenWindowController = DetachedContentWindowController(
            title: capture.fileName, contentSize: PlanetaryPostProcessingView.fullScreenSize,
            minSize: PlanetaryPostProcessingView.minWindowSize,
            onClose: { viewingFullScreenWindowController = nil }
        ) {
            FullScreenImageViewer(
                image: image, fileURL: fileURL, onSetAsThumbnail: setSessionThumbnailFromThisCapture,
                moreMenuItems: { AnyView(fullScreenMoreMenuItems) },
                onDismiss: { viewingFullScreenWindowController?.close() }
            )
        }
        viewingFullScreenWindowController?.showWindow(nil)
    }

    /// This viewer only ever opens for `.png`/`.tiff` captures (see `startViewingFullScreen`'s own
    /// call site in `actionsList`), so this doesn't need to gate on `capture.kind` the way
    /// `actionsList` itself does. "Edit Image…" leads, matching the elaborated-image preview's own
    /// "More" menu ordering (`ProjectDetailPane.fullScreenMoreMenuItems`) — previously this menu
    /// wasn't wired up at all here, so a raw capture's own full-screen preview had no "More" button,
    /// and no way to jump straight to Edit Image from it.
    @ViewBuilder
    private var fullScreenMoreMenuItems: some View {
        Button("Edit Image…", systemImage: "slider.horizontal.3") {
            viewingFullScreenWindowController?.close()
            startEditingImage()
        }
        Divider()
        Button("Show in Finder", systemImage: "folder") {
            viewingFullScreenWindowController?.close()
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
        Button("Publish to AstroBin…", systemImage: "arrow.up.forward.app") {
            viewingFullScreenWindowController?.close()
            AstroBinPublisher.publish(fileURL)
        }
        if elaborationSource != nil {
            Divider()
            Button("Open in Siril…", systemImage: "wand.and.stars") {
                viewingFullScreenWindowController?.close()
                startElaborating()
            }
        }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) {
            viewingFullScreenWindowController?.close()
            isConfirmingDelete = true
        }
    }

    /// `FullScreenImageViewer`'s "Set as Thumbnail" for a capture — session-scoped (not
    /// project-scoped), matching `SessionDetailPane`'s own `CoverThumbnailEditor`, since this is
    /// exactly what that editor already writes, just triggered from the viewer instead of a file
    /// picker.
    private func setSessionThumbnailFromThisCapture() {
        guard let name = try? store.importCustomThumbnail(from: fileURL, for: session, in: project) else { return }
        var updatedSession = session
        updatedSession.customThumbnailFileName = name
        var updatedProject = project
        guard let index = updatedProject.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        updatedProject.sessions[index] = updatedSession
        try? cameraManager.projectsLibrary.save(updatedProject)
    }

    @ViewBuilder
    private func captureStepButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                // A fixed frame, not just the glyph's own intrinsic size — this is what actually
                // makes the whole visible circle clickable, not just wherever the glyph itself
                // happens to render within it.
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.borderless)
        .background(.thinMaterial, in: Circle())
        .contentShape(Circle())
        .padding(12)
        .help(label)
        .accessibilityLabel(label)
    }

    private var fileStats: [StatItem] {
        [
            StatItem(label: "File", value: capture.fileName),
            StatItem(label: "Kind", value: capture.kind.displayName),
            StatItem(label: "Date", value: capture.date.formatted(date: .abbreviated, time: .shortened)),
            StatItem(
                label: "Disk Usage",
                value: ByteCountFormatter.string(
                    fromByteCount: store.diskUsage(for: capture, in: session, project: project), countStyle: .file
                )
            ),
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
        // `capture.equipmentSystemID`, not `session.effectiveEquipmentSystemID(inProject:)` — a
        // snapshot of what was actually in use *at capture time* (see its own doc comment), same
        // as every other field here already reflects the moment of capture, not the session's
        // current (possibly since-changed) assignment.
        let equipmentName = cameraManager.equipmentLibrary.system(withID: capture.equipmentSystemID)?.name
        stats.append(StatItem(label: "Equipment", value: equipmentName ?? "None"))
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

    /// This capture's own single most likely next action — "Post-Process…" for a `.serVideo`
    /// burst, "Edit Image…" for a finished `.fits`/`.png`/`.tiff` frame — as a prominent button
    /// directly under the image itself, not a line item buried inside `actionsList` alongside
    /// Show in Finder/Move to Session/Delete. `nil` for `.recording` (no in-app processing exists
    /// for a continuous-recording folder), matching `actionsList`'s own kind gating.
    @ViewBuilder
    private var primaryActionButton: some View {
        if capture.kind == .serVideo {
            Button {
                startPostProcessing()
            } label: {
                if isOpeningPostProcessingWindow {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Post-Process…", systemImage: "sparkles.tv")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isOpeningPostProcessingWindow)
        } else if capture.kind == .fits || capture.kind == .png || capture.kind == .tiff {
            Button("Edit Image…", systemImage: "slider.horizontal.3") { startEditingImage() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    /// Every action this page offers on the capture itself, grouped under small labeled
    /// sub-headers instead of one long flat stack of buttons — "View", "Process", "Third-Party
    /// Tools", "Share", "Organize", then Delete on its own. A flat list here had grown to 8-9
    /// buttons (Open, Show in Finder, Publish to AstroBin, Open in Siril, Post-Process, Edit
    /// Image, Move to Session, Split into New Session, Copy All Details, Delete, depending on
    /// `capture.kind`) with nothing to visually separate "where do I click to just look at this"
    /// from "where do I click to reprocess it," and "Process" itself mixed Skyformac's own
    /// in-app tools with a hand-off to Siril as if they were interchangeable. Grouping by what
    /// each action actually *does* — and splitting "stays in this app" from "leaves this app" —
    /// makes scanning for one specific action faster than reading top-to-bottom every time.
    @ViewBuilder
    private var actionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            actionGroupLabel("View")
            // FITS gets the app's own real viewer (black/white-point stretch, debayer) — nicer
            // than whatever (if anything) the system associates with the extension. Every other
            // kind (SER, a continuous-recording folder, PNG/TIFF) opens in whatever the system
            // already handles it with — "if it's not a capture image ... I want to see it"
            // without this app needing its own SER/video player.
            if capture.kind == .fits {
                Button("Open in Viewer", systemImage: "eye") {
                    cameraManager.openExportedFile(fileURL)
                }
            } else if capture.kind == .png || capture.kind == .tiff {
                // A real image `NSImage` can decode — opens in-app, full screen, with zoom,
                // rather than handing off to whatever the system associates with the extension.
                Button("Open", systemImage: "arrow.up.left.and.arrow.down.right") {
                    startViewingFullScreen()
                }
            } else {
                Button("Open", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(fileURL)
                }
            }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }

            // Post-Process…/Edit Image… — this page's own single most likely next action for a
            // capture — is now a prominent button right under the image itself (`primaryActionButton`
            // in Row 1) instead of buried down here alongside Show in Finder/Move to Session/Delete.

            if elaborationSource != nil {
                Divider()
                actionGroupLabel("Third-Party Tools")
                Button("Open in Siril…", systemImage: "wand.and.stars") { startElaborating() }
            }

            Divider()
            actionGroupLabel("Share")
            if capture.kind == .fits || capture.kind == .png || capture.kind == .tiff {
                Button("Publish to AstroBin…", systemImage: "arrow.up.forward.app") {
                    AstroBinPublisher.publish(fileURL)
                }
                .help("Reveals the file in Finder and opens AstroBin's uploader in your browser — see AstroBinPublisher's own doc comment for why this isn't a direct in-app upload.")
            }
            Button("Copy All Details", systemImage: "doc.on.doc") {
                copyToClipboard(copyAllDetailsText)
            }
            .help("Copies File, Camera Settings, and Session — everything on this page — as one block of plain text.")

            Divider()
            actionGroupLabel("Organize")
            Button("Move to Session…", systemImage: "folder") {
                isMovingToSession = true
            }
            .disabled(moveSessionCandidates.isEmpty)
            Button("Split into New Session…", systemImage: "scissors") {
                isSplittingSession = true
            }

            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive) {
                isConfirmingDelete = true
            }
        }
    }

    private func actionGroupLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    /// One section's own `title` + its `StatsGridView` header row — a Copy button next to the
    /// title, matching `ProjectDetailPane`'s own "title-less `PageSection` + manual header
    /// `HStack`" pattern for whenever a section needs a trailing control the plain `title:`
    /// convenience initializer has no room for.
    @ViewBuilder
    private func sectionHeader(_ title: String, copying stats: [StatItem]) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button {
                copyToClipboard(Self.plainText(title: title, stats: stats))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("Copy \(title)")
        }
    }

    /// "Label: Value" per line, a leading title line — plain enough to paste straight into a
    /// forum post, a Discord message, or a bug report, which is the actual point of copying any
    /// of this rather than a screenshot.
    private static func plainText(title: String, stats: [StatItem]) -> String {
        ([title] + stats.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "Copy All Details" — every section on the page in one paste-able block, blank-line
    /// separated, in the same top-to-bottom order they're shown. Includes the capture's own note
    /// (not a `StatsGridView` field) since that's real shareable content too.
    private var copyAllDetailsText: String {
        var blocks = [Self.plainText(title: "File", stats: fileStats)]
        if let note = capture.note, !note.isEmpty {
            blocks.append("Note: \(note)")
        }
        if let cameraSettingsStats {
            blocks.append(Self.plainText(title: "Camera Settings", stats: cameraSettingsStats))
        }
        blocks.append(Self.plainText(title: "Session", stats: sessionContextStats))
        return blocks.joined(separator: "\n\n")
    }
}

/// "Move to Session…" — a flat pick-one list of every other session across every project, each
/// row showing which project it belongs to since the same session name could plausibly repeat
/// across different projects. Same plain-`List`-of-`Button`s shape as `MoveSessionToProjectSheet`
/// (`SessionDetailPane.swift`), just one level deeper (project *and* session per row) since a
/// capture's destination genuinely needs both, unlike a whole session's move (which only ever
/// needs a project — the session keeps its own identity).
private struct MoveCaptureToSessionSheet: View {
    let candidates: [CaptureDetailPage.SessionCandidate]
    var onMove: (CaptureDetailPage.SessionCandidate) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move to Session").font(.headline).padding()
            Divider()
            if candidates.isEmpty {
                Text("No other sessions to move this to yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(candidates) { candidate in
                    Button {
                        onMove(candidate)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.session.name)
                            Text(candidate.project.name.isEmpty ? "Untitled Project" : candidate.project.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

/// "Split into New Session…" — the user changed target partway through this session, so this
/// capture and everything captured after it should move to a fresh session instead. Just a name
/// prompt (unlike `NewSessionFromExistingSheet`'s extra planned-date field — a split session
/// starts *now*, at this capture's own date, not some future planned date) since everything else
/// about the new session (goal, objects, location, equipment) is inherited from the one it's
/// splitting off from.
private struct SplitSessionSheet: View {
    let session: Session
    var onSplit: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(session: Session, onSplit: @escaping (String) -> Void) {
        self.session = session
        self.onSplit = onSplit
        self._name = State(initialValue: "\(session.name) (New Target)")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split into New Session").font(.headline)
            Text("Moves this capture, and every capture after it in \"\(session.name)\", into a new session with this name — reusing its goal, objects, location, and equipment.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name, prompt: Text("Session name")).onSubmit(split)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Split") { split() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(width: 380, height: 200)
    }

    private func split() {
        guard !trimmedName.isEmpty else { return }
        onSplit(trimmedName)
        dismiss()
    }
}
