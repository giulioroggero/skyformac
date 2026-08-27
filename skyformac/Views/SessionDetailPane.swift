import SwiftUI

/// A session's own capture Timeline — same "recognize it visually" vs. "compare a lot of them
/// by their actual numbers" tradeoff as `ProjectDetailPane`'s Cards/Table toggle for sessions —
/// the filmstrip for browsing thumbnails, a table for seeing disk usage/kind side by side and
/// multi-selecting for bulk actions.
private enum CapturesViewMode: String {
    case filmstrip
    case table
}

/// The Projects browser's Session page: one session's metadata, its capture timeline, and the
/// controls that make it the active recording destination (`CameraManager.activeSession`). A
/// plain full-width `ScrollView`, not a `Form` — a `Form`'s `.formStyle(.grouped)` centers/caps
/// its content width on macOS, which this page deliberately doesn't want (see `PageSection`).
struct SessionDetailPane: View {
    let project: Project
    let session: Session
    var cameraManager: CameraManager
    /// Pops back to this session's own Project page — the toolbar's explicit "Back to Project"
    /// button, since the drill-down hierarchy this feature is built around means "up" always has
    /// one specific, nameable destination, not just "whatever's previous."
    var onBack: () -> Void
    /// Jumps all the way back to the Projects browser's Home page, regardless of how deep the
    /// navigation stack is. The system's own automatically-inserted back chevron only ever pops
    /// one level (equivalent to `onBack` here), so it's hidden (`.navigationBarBackButtonHidden`)
    /// and replaced with this explicit pair — first "Home", then "Back to Project" — rather than
    /// leaving two chevrons that do the same thing.
    var onHome: () -> Void
    /// Pushes the tapped timeline thumbnail's own full-width Capture page.
    var onSelectCapture: (CaptureRecord) -> Void
    /// Pushes the newly-created session's own page — see "New Session Like This…" below.
    var onSessionCreated: (Session) -> Void
    /// Steps to the previous/next session within this same project, in the order
    /// `ProjectDetailPane`'s own session cards show them (favorites first). `nil` — not a no-op
    /// closure — when this is the first/last session, so the toolbar button is hidden entirely.
    var onPreviousSession: (() -> Void)?
    var onNextSession: (() -> Void)?

    @State private var name: String
    @State private var goal: String
    @State private var plannedObjectsText: String
    @State private var hasPlannedDate: Bool
    @State private var plannedDate: Date
    @State private var isPlanningSession = false
    @State private var isCreatingSessionFromThis = false
    @State private var isDescribingSession = false
    @State private var isSuggestingTags = false
    @State private var isMovingToProject = false
    @State private var moveErrorMessage: String?
    @State private var isElaborating = false
    @State private var isPromptingSirilSettings = false
    @State private var isConfirmingDelete = false
    /// Bumped after deleting a stray file so `strayFilesInSessionFolder` (a plain `FileManager`
    /// directory listing, not something `ProjectsLibrary` tracks/republishes) re-reads the folder.
    @State private var strayFilesRefreshTrigger = 0
    @State private var isBrowsingStrayFiles = false
    @State private var isConfirmingBulkCaptureDelete = false
    /// Persisted like `ProjectDetailPane`'s own Cards/Table toggle for sessions — a view mode
    /// picked once shouldn't reset back to the default every relaunch.
    @AppStorage("sessionCapturesViewMode") private var capturesViewModeRaw = CapturesViewMode.filmstrip.rawValue
    private var capturesViewMode: CapturesViewMode { CapturesViewMode(rawValue: capturesViewModeRaw) ?? .filmstrip }
    /// A `Table`'s own selection — multi-select out of the box (click/⌘-click/shift-click) with
    /// a `Set` binding, same as `ProjectDetailPane`'s own sessions table. Shared with the
    /// filmstrip's own selection (gated by `isSelectingCaptures` there) so the bulk action bar
    /// above the Timeline works the same regardless of which view mode picked the selection.
    @State private var selectedCaptureIDs: Set<CaptureRecord.ID> = []
    /// The filmstrip's own "Select" mode toggle — see `TimelineStripView`'s own doc comment for
    /// why the Table doesn't need an equivalent.
    @State private var isSelectingCaptures = false
    /// "The edit/preview windows can be moved across the screen and resized" — see
    /// `CaptureDetailPage`'s identical property doc comment for why this is a
    /// `DetachedContentWindowController?` rather than the `Bool` + `.sheet` it used to be.
    @State private var postProcessingSelectionWindowController: DetachedContentWindowController?
    /// "Compose Mosaic…" — same windowing reasoning as `postProcessingSelectionWindowController`
    /// above.
    @State private var mosaicComposerWindowController: DetachedContentWindowController?

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }
    /// Files sitting in this session's own folder that AREN'T one of its tracked
    /// `CaptureRecord`s — e.g. `moon_00290.fit` left behind by an external post-processing tool
    /// (Siril/AutoStakkert) pointed at this folder. Excludes the `Thumbnails` subfolder and
    /// `session.json` (the folder's own always-present, non-capture entries) — everything else is
    /// otherwise invisible in-app: not shown by `TimelineStripView` (which only ever lists
    /// `session.captures`, never the folder's actual disk contents) and only reachable before
    /// this via "Show in Finder."
    private var strayFilesInSessionFolder: [URL] {
        _ = strayFilesRefreshTrigger
        let folder = cameraManager.projectStore.sessionFolderURL(for: session, in: project)
        let trackedNames = Set(session.captures.map(\.fileName))
        let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        let unexpectedNames: Set<String> = ["Thumbnails", "session.json"]
        let stray = (contents ?? []).filter { url in
            let name = url.lastPathComponent
            let isExpected = unexpectedNames.contains(name) || trackedNames.contains(name)
            return !isExpected
        }
        return stray.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    /// Combined disk usage of every stray file above — shown right in the "Browse…" button so
    /// there's a sense of how much space these untracked files are actually taking up without
    /// needing to open the browser first.
    private var strayFilesTotalSizeText: String {
        let totalBytes = strayFilesInSessionFolder.reduce(Int64(0)) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            return total + Int64(size ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }
    /// "Move to Project…"'s own candidate list — every other active project, alphabetically;
    /// excludes the current one (nothing to move to) and archived/deleted projects (not
    /// realistically where anyone wants to relocate a session they're actively looking at).
    private var otherProjects: [Project] {
        library.activeProjects
            .filter { $0.id != project.id && !$0.isArchived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(
        project: Project, session: Session, cameraManager: CameraManager,
        onBack: @escaping () -> Void, onHome: @escaping () -> Void,
        onSelectCapture: @escaping (CaptureRecord) -> Void,
        onSessionCreated: @escaping (Session) -> Void,
        onPreviousSession: (() -> Void)? = nil, onNextSession: (() -> Void)? = nil
    ) {
        self.project = project
        self.session = session
        self.cameraManager = cameraManager
        self.onBack = onBack
        self.onHome = onHome
        self.onSelectCapture = onSelectCapture
        self.onSessionCreated = onSessionCreated
        self.onPreviousSession = onPreviousSession
        self.onNextSession = onNextSession
        self._name = State(initialValue: session.name)
        self._goal = State(initialValue: session.goal)
        self._plannedObjectsText = State(initialValue: session.plannedObjects.joined(separator: ", "))
        self._hasPlannedDate = State(initialValue: session.plannedDate != nil)
        self._plannedDate = State(initialValue: session.plannedDate ?? Date())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Row 1: Cover (a small, fixed-width thumbnail editor — see
                // `CoverThumbnailEditor`'s own 120×80 image, it never needed a full-width row of
                // its own) alongside the Session Summary, which takes the rest of the width.
                HStack(alignment: .top, spacing: 16) {
                    PageSection(title: "Cover") {
                        CoverThumbnailEditor(
                            currentURL: cameraManager.projectStore.mostRecentThumbnailURL(for: session, in: project),
                            hasCustom: session.customThumbnailFileName != nil,
                            onPick: { url in
                                guard let name = try? cameraManager.projectStore.importCustomThumbnail(from: url, for: session, in: project) else { return }
                                var updated = session
                                updated.customThumbnailFileName = name
                                applyAndSave(updated)
                            },
                            onRemove: {
                                cameraManager.projectStore.removeCustomThumbnail(for: session, in: project)
                                var updated = session
                                updated.customThumbnailFileName = nil
                                applyAndSave(updated)
                            }
                        )
                    }
                    .frame(width: 280)

                    PageSection(title: "Session Summary") {
                        HStack {
                            TextField("Name", text: $name).onChange(of: name) { _, _ in save() }
                            FavoriteToggleButton(isFavorite: session.isFavorite) {
                                var updated = session
                                updated.isFavorite.toggle()
                                applyAndSave(updated)
                            }
                            RatingView(rating: session.rating) { newRating in
                                var updated = session
                                updated.rating = newRating
                                applyAndSave(updated)
                            }
                        }
                        TextField("Aim", text: $goal, prompt: Text("What is this session for?"), axis: .vertical)
                            .onChange(of: goal) { _, _ in save() }
                        TextField("Objects (comma separated)", text: $plannedObjectsText, prompt: Text("M13, M57, Saturn"))
                            .onChange(of: plannedObjectsText) { _, _ in savePlannedObjects() }
                        Toggle("Planned Date", isOn: $hasPlannedDate)
                            .onChange(of: hasPlannedDate) { _, isOn in savePlannedDate(isOn ? plannedDate : nil) }
                        if hasPlannedDate {
                            DatePicker("Date & Time", selection: $plannedDate, displayedComponents: [.date, .hourAndMinute])
                                .onChange(of: plannedDate) { _, new in savePlannedDate(new) }
                        }
                        LocationEditorView(project: project, session: session, cameraManager: cameraManager)
                        HStack {
                            Button("Run This Session", systemImage: "play.fill") {
                                cameraManager.setActive(project: project, session: session)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .help(session.captures.isEmpty ? "Starts this session — switches the main window to the camera view" : "Resumes capturing into this session")
                            HelpLinkButton(cameraManager: cameraManager, topicID: "config-reference", sectionID: "setting.runSession")
                            Spacer()
                            Button("Recall Parameters…", systemImage: "clock.arrow.circlepath") {
                                cameraManager.isRecallParametersPresented = true
                            }
                            .help("Reuse the camera parameters from a previous action to speed up setting this one up")
                            Button("New Session Like This…", systemImage: "plus.square.on.square") {
                                isCreatingSessionFromThis = true
                            }
                            .help("Create a new session with this one's goal, objects, location, and equipment — without any of its captures")
                            Button("Ask AI to Plan…", systemImage: "sparkles") { isPlanningSession = true }
                            Button("Ask AI to Describe…", systemImage: "text.quote") { isDescribingSession = true }
                                .help("Write a description grounded in what this session has actually planned and captured")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Row 2: History, Equipment, Stats, and Tags side by side — four short reference
                // panels that each used to take a full-width row of their own for a handful of
                // lines.
                HStack(alignment: .top, spacing: 16) {
                    PageSection(title: "History") {
                        StatsGridView(stats: historyStats)
                    }

                    PageSection(title: "Equipment") {
                        Picker("System", selection: Binding(
                            get: { session.equipmentSystemID },
                            set: { newValue in
                                var updated = session
                                updated.equipmentSystemID = newValue
                                applyAndSave(updated)
                            }
                        )) {
                            Text("Inherit from Project\(inheritedEquipmentSuffix)").tag(UUID?.none)
                            ForEach(cameraManager.equipmentLibrary.systems) { system in
                                Text(system.name).tag(UUID?.some(system.id))
                            }
                        }
                        .labelsHidden()
                    }

                    if !session.captures.isEmpty {
                        PageSection(title: "Stats") {
                            StatsGridView(stats: captureStats)
                        }
                    }

                    PageSection(title: "Tags") {
                        VStack(alignment: .leading, spacing: 8) {
                            TagsEditorView(tags: session.tags) { tags in
                                var updated = session
                                updated.tags = tags
                                applyAndSave(updated)
                            }
                            Button("Suggest Tags with AI…", systemImage: "sparkles") { isSuggestingTags = true }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                // Row 3: Timeline.
                PageSection {
                    HStack {
                        Text("Timeline").font(.headline)
                        Spacer()
                        // Only the filmstrip needs an explicit "Select" mode — the Table's own
                        // `Table` selection is already native multi-select (click/⌘-click), no
                        // mode toggle needed there, same reasoning `ProjectsThumbnailGrid`'s own
                        // "Select" button has for its card grid vs. a `Table`.
                        if capturesViewMode == .filmstrip {
                            Button(isSelectingCaptures ? "Done Selecting" : "Select") {
                                isSelectingCaptures.toggle()
                                if !isSelectingCaptures { selectedCaptureIDs.removeAll() }
                            }
                            .buttonStyle(.borderless)
                        }
                        Picker("View", selection: $capturesViewModeRaw) {
                            Label("Filmstrip", systemImage: "square.stack").tag(CapturesViewMode.filmstrip.rawValue)
                            Label("Table", systemImage: "tablecells").tag(CapturesViewMode.table.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.iconOnly)
                        .frame(width: 90)
                    }

                    if !selectedCaptureIDs.isEmpty {
                        capturesBulkActionBar
                    }

                    switch capturesViewMode {
                    case .filmstrip:
                        TimelineStripView(
                            project: project, session: session, store: cameraManager.projectStore,
                            cameraManager: cameraManager, isSelecting: isSelectingCaptures,
                            selectedIDs: $selectedCaptureIDs, onSelect: onSelectCapture,
                            onDelete: { capture in
                                try? library.deleteCapture(capture.id, fromSessionID: session.id, in: project)
                            }
                        )
                    case .table:
                        // The data-dense alternative — every capture's disk usage/kind/object
                        // side by side, sortable, with native multi-select for the bulk action
                        // bar above instead of one context menu at a time.
                        CapturesTableView(
                            project: project, session: session, store: cameraManager.projectStore,
                            selectedIDs: $selectedCaptureIDs, onSelect: onSelectCapture
                        )
                        .frame(minHeight: 240, idealHeight: 360)
                    }
                }

                if !sessionElaboratedImages.isEmpty {
                    PageSection(title: "Elaborated") {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(sessionElaboratedImages) { image in
                                    ElaboratedImageCard(project: project, image: image, cameraManager: cameraManager)
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }

                // Row 4: Notes.
                PageSection(title: "Notes") {
                    VStack(alignment: .leading, spacing: 8) {
                        NotesEditorView(notes: session.notes) { notes in
                            var updated = session
                            updated.notes = notes
                            applyAndSave(updated)
                        }
                        // Reuses "Ask AI to Describe" (already in the toolbar menu below) — its
                        // own "Add as Note" button is what actually appends here; this is just a
                        // second, more discoverable entry point right where notes are shown.
                        Button("Write a Note with AI…", systemImage: "sparkles") { isDescribingSession = true }
                            .buttonStyle(.borderless)
                    }
                }

                if !strayFilesInSessionFolder.isEmpty {
                    PageSection(title: "Other Files in This Folder") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Not tracked captures — likely left behind by an external tool (Siril, AutoStakkert) pointed at this folder.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Button {
                                isBrowsingStrayFiles = true
                            } label: {
                                Label(
                                    "Browse \(strayFilesInSessionFolder.count) File(s) (\(strayFilesTotalSizeText))…",
                                    systemImage: "doc.on.doc"
                                )
                            }
                        }
                    }
                }

                // Row 5: Elaborate, Archive, Move, Delete.
                PageSection {
                    HStack {
                        Button("Open Session in Siril…", systemImage: "wand.and.stars") { startElaborating() }
                            .disabled(elaborationSource == nil)
                            .help(elaborationSource == nil
                                ? "Nothing to elaborate — needs at least one FITS or SER capture in this session."
                                : "Send this session's captures to Siril for stacking/registration/stretching.")
                        Button("Archive Session", systemImage: "archivebox") {
                            try? library.setArchived(true, forSessionID: session.id, in: project)
                        }
                        Button("Move to Project…", systemImage: "folder") { isMovingToProject = true }
                            .disabled(otherProjects.isEmpty)
                        Button("Delete Session", systemImage: "trash", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("\(project.name.isEmpty ? "Untitled Project" : project.name) — \(session.name)")
        // The system's own automatic back chevron only ever pops one level, which would sit right
        // next to `onBack` doing the exact same thing — hidden in favor of the explicit
        // Home/Back pair below.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    Button("Home", systemImage: "house", action: onHome)
                    Button("Back to Project", systemImage: "chevron.left", action: onBack)
                }
            }
            ToolbarItemGroup {
                if let onPreviousSession {
                    Button("Previous Session", systemImage: "chevron.up", action: onPreviousSession)
                }
                if let onNextSession {
                    Button("Next Session", systemImage: "chevron.down", action: onNextSession)
                }
            }
            OpenAssistantToolbarItem(cameraManager: cameraManager)
        }
        // Same reasoning as `ProjectDetailPane`'s own `.onChange(of: project)` — local `@State`
        // for name/goal otherwise goes stale the moment something external (Ask AI to Plan, Ask
        // AI to Describe) changes them.
        .onChange(of: session) { _, updated in
            name = updated.name
            goal = updated.goal
        }
        .sheet(isPresented: $isPlanningSession) {
            AIPlanSessionSheet(project: project, session: session, cameraManager: cameraManager)
        }
        .sheet(isPresented: $isMovingToProject) {
            MoveSessionToProjectSheet(candidates: otherProjects) { destination in
                do {
                    try library.moveSession(session.id, from: project, to: destination)
                    // The session no longer belongs to `project` — this page's own route is now
                    // stale, so pop back to the (still-valid) Project page rather than keep
                    // showing a session that isn't there anymore. Only reached on success — a
                    // failed move must not navigate away as though it worked.
                    onBack()
                } catch {
                    moveErrorMessage = error.localizedDescription
                }
            }
        }
        .alert("Couldn't Move Session", isPresented: Binding(
            get: { moveErrorMessage != nil },
            set: { isPresented in if !isPresented { moveErrorMessage = nil } }
        ), presenting: moveErrorMessage) { _ in
            Button("OK") { moveErrorMessage = nil }
        } message: { message in
            Text(message)
        }
        .confirmationDialog(
            "Delete this session?", isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete \(session.name)", role: .destructive) {
                try? library.deleteSession(session.id, in: project)
                // The session this page is showing no longer exists — its own route is now
                // stale, same reasoning as the "Move to Project…" success handler above, so pop
                // back to the (still-valid) Project page.
                onBack()
            }
        } message: {
            Text("This removes \(session.captures.count) capture\(session.captures.count == 1 ? "" : "s") and everything else in this session from disk — this can't be undone.")
        }
        .sheet(isPresented: $isCreatingSessionFromThis) {
            NewSessionFromExistingSheet(session: session) { name, plannedDate in
                let newSession = session.duplicatedForReuse(name: name, plannedDate: plannedDate)
                if let updated = try? library.addSession(newSession, to: project),
                   let created = updated.sessions.first(where: { $0.id == newSession.id }) {
                    onSessionCreated(created)
                }
            }
        }
        .sheet(isPresented: $isDescribingSession) {
            AIDescribeSheet(
                title: "Ask AI to Describe This Session",
                context: AIDescriptionContext.forSession(session, project: project) { cameraManager.equipmentLibrary.system(withID: $0)?.name },
                cameraManager: cameraManager,
                onSetAim: { text in
                    var updated = session
                    updated.goal = text
                    applyAndSave(updated)
                },
                onAddNote: { text in
                    var updated = session
                    updated.notes.append(Annotation(date: Date(), text: text))
                    applyAndSave(updated)
                }
            )
        }
        .sheet(isPresented: $isSuggestingTags) {
            AISuggestTagsSheet(
                title: "Suggest Tags for This Session",
                context: AIDescriptionContext.forSession(session, project: project) { cameraManager.equipmentLibrary.system(withID: $0)?.name },
                existingTags: session.tags,
                cameraManager: cameraManager,
                onAddTags: { newTags in
                    var updated = session
                    updated.tags.append(contentsOf: newTags)
                    applyAndSave(updated)
                }
            )
        }
        .sheet(isPresented: $isPromptingSirilSettings) {
            SirilDisabledPrompt(onOpenSettings: { cameraManager.isSettingsPresented = true })
        }
        .sheet(isPresented: $isBrowsingStrayFiles) {
            SessionStrayFilesBrowserView(
                cameraManager: cameraManager, files: strayFilesInSessionFolder,
                onChanged: { strayFilesRefreshTrigger &+= 1 }
            )
        }
        .sheet(isPresented: $isElaborating) {
            if let (source, target) = elaborationSource {
                ElaborateSheet(
                    source: source,
                    suggestedRecipe: SirilElaborationService.resolveRecipe(for: source, target: target),
                    sourceDescription: "Elaborating this session's captures (\(session.name))."
                ) { recipe, parameters, onLog in
                    try await cameraManager.elaborate(
                        source: source, recipe: recipe, sourceSessionIDs: [session.id],
                        sourceCaptureID: nil, project: project, parameters: parameters, onLog: onLog
                    )
                }
            }
        }
    }

    private func openPostProcessingSelectionWindow() {
        let urls = selectedSERCaptures.map {
            cameraManager.projectStore.sessionFolderURL(for: session, in: project).appendingPathComponent($0.fileName)
        }
        guard !urls.isEmpty else { return }
        let description = urls.count == 1
            ? "Post-processing \(urls[0].lastPathComponent)."
            : "Post-processing \(urls.count) captures together."
        postProcessingSelectionWindowController = DetachedContentWindowController(
            title: "Planetary Post-Processing", contentSize: PlanetaryPostProcessingView.fullScreenSize,
            minSize: PlanetaryPostProcessingView.minWindowSize,
            onClose: { postProcessingSelectionWindowController = nil }
        ) {
            PlanetaryPostProcessingView(
                sourceURLs: urls,
                sourceDescription: description,
                onSave: { cgImage, title, notes, settings in
                    try cameraManager.savePlanetaryPostProcessingResult(
                        cgImage, sourceSessionIDs: [session.id], sourceCaptureID: nil, project: project,
                        title: title, notes: notes, settings: settings
                    )
                },
                onOverwrite: { cgImage, existing, title, notes, settings in
                    try cameraManager.overwritePlanetaryPostProcessingResult(
                        cgImage, existing: existing, project: project, title: title, notes: notes, settings: settings
                    )
                },
                resolveGraXpertInputURL: { image in
                    cameraManager.projectStore.elaboratedImagesFolderURL(for: project).appendingPathComponent(image.fileName)
                },
                onSendToGraXpert: { inputURL, operation, parameters, onLog in
                    try await cameraManager.sendToGraXpert(
                        inputURL: inputURL, operation: operation, sourceSessionIDs: [session.id],
                        sourceCaptureID: nil, project: project, parameters: parameters, onLog: onLog
                    )
                },
                onOpenGraXpertSettings: { cameraManager.isSettingsPresented = true },
                onDismiss: { postProcessingSelectionWindowController?.close() }
            )
        }
        postProcessingSelectionWindowController?.showWindow(nil)
    }

    /// `nil` when this session has nothing Siril can process — see
    /// `CameraManager.elaborationSource(for:project:)`.
    private var elaborationSource: (SirilElaborationService.Source, AcquisitionTarget?)? {
        cameraManager.elaborationSource(for: session, project: project)
    }

    /// Only this session's own results — the project page shows every elaborated image across all
    /// sessions, but here (and on `CaptureDetailPage`'s own capture-scoped equivalent) narrower is
    /// more useful: "what came out of *this* session," not the whole project's history.
    private var sessionElaboratedImages: [ElaboratedImage] {
        project.elaboratedImages
            .filter { $0.sourceSessionIDs.contains(session.id) }
            .sorted { $0.date > $1.date }
    }

    private func startElaborating() {
        if AppSettings.isSirilIntegrationEnabled {
            isElaborating = true
        } else {
            isPromptingSirilSettings = true
        }
    }

    private func save() {
        var updated = session
        updated.name = name
        updated.goal = goal
        applyAndSave(updated)
    }

    private func savePlannedObjects() {
        var updated = session
        updated.plannedObjects = plannedObjectsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        applyAndSave(updated)
    }

    private func savePlannedDate(_ date: Date?) {
        var updated = session
        updated.plannedDate = date
        applyAndSave(updated)
    }

    private func applyAndSave(_ updatedSession: Session) {
        var updatedProject = project
        guard let index = updatedProject.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        updatedProject.sessions[index] = updatedSession
        try? library.save(updatedProject)
    }

    /// Shown above the capture Timeline the moment the table's selection is non-empty — "N
    /// selected," Delete acting on the whole set at once (behind a confirmation — this deletes
    /// the actual files, not a 30-day-grace-period soft delete the way a session/project's own
    /// Danger Zone works), and Clear. Loops the same single-capture
    /// `ProjectsLibrary.deleteCapture` the filmstrip's own per-thumbnail context menu already
    /// uses (which asks per-capture rather than needing this dialog, since there's only ever one
    /// capture in play there).
    private var capturesBulkActionBar: some View {
        HStack {
            Text("\(selectedCaptureIDs.count) selected").font(.subheadline)
            Spacer()
            // "I want to combine several different captures and stack it" — pools every selected
            // `.ser`'s own frames into one registration/stack run (see `PlanetaryPostProcessor
            // .loadSequence(from: [URL])`). Ignores a non-`.ser` in the same selection rather than
            // disabling the button outright — deleting captures works fine on a mixed-kind
            // selection, no reason post-processing needs an all-or-nothing kind match either.
            if !selectedSERCaptures.isEmpty {
                Button("Post-Process Together…", systemImage: "sparkles.tv") { openPostProcessingSelectionWindow() }
            }
            // "Different parts of the Moon to get a full Moon, or different captures of Andromeda,
            // composed together" — real star-pattern tile registration (`MosaicComposer`), not
            // same-field-of-view stacking, so this only makes sense for 2+ finished stills.
            if selectedImageCaptures.count >= 2 {
                Button("Compose Mosaic…", systemImage: "square.grid.3x3") { openMosaicComposerWindow() }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                isConfirmingBulkCaptureDelete = true
            }
            Button("Clear") { selectedCaptureIDs.removeAll() }
        }
        .padding(.vertical, 6)
        .confirmationDialog(
            "Delete \(selectedCaptureIDs.count) capture\(selectedCaptureIDs.count == 1 ? "" : "s")?",
            isPresented: $isConfirmingBulkCaptureDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                for id in selectedCaptureIDs {
                    try? library.deleteCapture(id, fromSessionID: session.id, in: project)
                }
                selectedCaptureIDs.removeAll()
            }
        } message: {
            Text("This removes the file(s) and their thumbnails from disk — this can't be undone.")
        }
    }

    private var selectedSERCaptures: [CaptureRecord] {
        session.captures.filter { selectedCaptureIDs.contains($0.id) && $0.kind == .serVideo }
    }

    /// A mosaic tile is always a finished still (the same three kinds `CaptureDetailPage`'s own
    /// full-screen preview opens for) — a `.serVideo`/`.recording` isn't a single image at all,
    /// nothing to detect stars in directly.
    private var selectedImageCaptures: [CaptureRecord] {
        session.captures.filter {
            selectedCaptureIDs.contains($0.id) && ($0.kind == .png || $0.kind == .tiff || $0.kind == .fits)
        }
    }

    private func openMosaicComposerWindow() {
        let captures = selectedImageCaptures
        let urls = captures.map {
            cameraManager.projectStore.sessionFolderURL(for: session, in: project).appendingPathComponent($0.fileName)
        }
        guard urls.count >= 2 else { return }
        mosaicComposerWindowController = DetachedContentWindowController(
            title: "Mosaic Composer", contentSize: MosaicComposerView.fullScreenSize,
            minSize: MosaicComposerView.minWindowSize,
            onClose: { mosaicComposerWindowController = nil }
        ) {
            MosaicComposerView(
                sourceURLs: urls,
                sourceDescription: "Composing \(urls.count) captures into a mosaic.",
                elaboratedImagesFolderURL: cameraManager.projectStore.elaboratedImagesFolderURL(for: project),
                onSave: { cgImage in
                    try cameraManager.saveMosaicResult(cgImage, sourceSessionIDs: [session.id], project: project)
                },
                onDismiss: { mosaicComposerWindowController?.close() }
            )
        }
        mosaicComposerWindowController?.showWindow(nil)
    }

    /// The historical record this page is actually for — when it was planned/created/captured,
    /// where, and what for — using the same vocabulary ("Aim," "Objects," "Position") the rest of
    /// the Projects feature does, not just the raw model field names.
    private var historyStats: [StatItem] {
        var stats = [StatItem(label: "Created", value: session.createdDate.formatted(date: .abbreviated, time: .shortened))]
        if let planned = session.plannedDate {
            stats.append(StatItem(label: "Planned", value: planned.formatted(date: .abbreviated, time: .shortened)))
        }
        if let first = session.firstCaptureDate {
            stats.append(StatItem(label: "First Capture", value: first.formatted(date: .abbreviated, time: .shortened)))
        }
        if let last = session.lastCaptureDate {
            stats.append(StatItem(label: "Last Capture", value: last.formatted(date: .abbreviated, time: .shortened)))
        }
        if let duration = session.duration, let formatted = Self.durationFormatter.string(from: duration) {
            stats.append(StatItem(label: "Duration", value: formatted))
        }
        if let location = session.effectiveLocation(inProject: project) {
            stats.append(StatItem(label: "Position", value: location.displayName))
        }
        stats.append(StatItem(label: "Aim", value: session.goal.isEmpty ? "—" : session.goal))
        stats.append(StatItem(label: "Objects", value: session.plannedObjects.isEmpty ? "—" : session.plannedObjects.joined(separator: ", ")))
        let equipmentName = cameraManager.equipmentLibrary.system(withID: session.effectiveEquipmentSystemID(inProject: project))?.name
        stats.append(StatItem(label: "Equipment", value: equipmentName ?? "None"))
        return stats
    }

    /// Shown next to "Inherit from Project" in the Equipment picker so the resolved system is
    /// visible without having to go check the project's own page — "" when there's nothing to
    /// inherit, rather than a confusing "(None)" suffix.
    private var inheritedEquipmentSuffix: String {
        guard let name = cameraManager.equipmentLibrary.system(withID: project.equipmentSystemID)?.name else { return "" }
        return " (\(name))"
    }

    /// How much has actually been captured, broken down by kind — hidden entirely for a session
    /// with nothing yet, since an all-zero breakdown says nothing useful.
    private var captureStats: [StatItem] {
        var stats = [StatItem(label: "Total Captures", value: "\(session.captures.count)")]
        for kind in CaptureRecord.Kind.allCases {
            if let count = session.captureCountByKind[kind] {
                stats.append(StatItem(label: kind.displayName, value: "\(count)"))
            }
        }
        let diskUsage = cameraManager.projectStore.diskUsage(for: session, in: project)
        stats.append(StatItem(label: "Disk Usage", value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file)))
        return stats
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}

/// "New Session Like This…" — just a name (and optional planned date) for the reused copy;
/// everything else (goal, objects, location, tags, equipment) already carries over via
/// `Session.duplicatedForReuse(name:plannedDate:)`, so this sheet stays as small as
/// `NewProjectSheet`'s own "just the name" scope.
private struct NewSessionFromExistingSheet: View {
    let session: Session
    var onCreate: (String, Date?) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var hasPlannedDate = false
    @State private var plannedDate = Date()

    init(session: Session, onCreate: @escaping (String, Date?) -> Void) {
        self.session = session
        self.onCreate = onCreate
        self._name = State(initialValue: "\(session.name) (Copy)")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Session Like \"\(session.name)\"").font(.headline)
            Text("Reuses its goal, objects, location, and equipment — starts with no captures.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name, prompt: Text("Session name")).onSubmit(create)
            Toggle("Planned Date", isOn: $hasPlannedDate)
            if hasPlannedDate {
                DatePicker("Date & Time", selection: $plannedDate, displayedComponents: [.date, .hourAndMinute])
            }
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(width: 360, height: 220)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName, hasPlannedDate ? plannedDate : nil)
        dismiss()
    }
}

/// "Move to Project…" — a plain pick-one list rather than a full project browser, since the
/// only decision here is *which* project, not any of that project's own details.
private struct MoveSessionToProjectSheet: View {
    let candidates: [Project]
    var onMove: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Move Session to Project").font(.headline).padding()
            Divider()
            List(candidates) { candidate in
                Button {
                    onMove(candidate)
                    dismiss()
                } label: {
                    HStack {
                        Text(candidate.name.isEmpty ? "Untitled Project" : candidate.name)
                        Spacer()
                        Text("\(candidate.sessions.count) session\(candidate.sessions.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
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

/// A full browser modal for the files the session folder actually contains that
/// `session.captures` doesn't know about — e.g. a Siril/AutoStakkert result
/// (`moon_00290.fit`) dropped straight into the folder by an external tool. Multi-selectable
/// (native `List` selection — ⌘/⇧-click, or "Select All" below) with a live preview pane and
/// bulk actions (Delete, Show in Finder) over however many files are selected at once, rather
/// than the previous one-row-at-a-time inline list.
struct SessionStrayFilesBrowserView: View {
    var cameraManager: CameraManager
    let files: [URL]
    /// Called once, on dismiss, if anything was actually deleted — lets
    /// `SessionDetailPane.strayFilesInSessionFolder` re-read the folder for next time this
    /// browser is opened (this view manages its own local list live in the meantime, so nothing
    /// needs to observe it while it's open).
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentFiles: [URL] = []
    @State private var selection: Set<URL> = []
    @State private var previewImage: CGImage?
    @State private var isLoadingPreview = false
    @State private var isConfirmingDelete = false
    @State private var didDeleteAnything = false

    private var selectedFiles: [URL] { currentFiles.filter { selection.contains($0) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                fileList
                    .frame(minWidth: 260, idealWidth: 300)
                previewPane
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 860, minHeight: 480, idealHeight: 560)
        .onAppear { currentFiles = files }
        .onChange(of: selection) { _, _ in loadPreview() }
        .onDisappear {
            if didDeleteAnything { onChanged() }
        }
        .confirmationDialog(
            "Delete \(selection.count) file\(selection.count == 1 ? "" : "s")?",
            isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text("This removes the file(s) from disk — this can't be undone.")
        }
    }

    private var header: some View {
        HStack {
            Label("Other Files in This Folder", systemImage: "doc.on.doc").font(.headline)
            Spacer()
            Text("\(currentFiles.count) file(s)").font(.caption).foregroundStyle(.secondary)
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var fileList: some View {
        List(currentFiles, id: \.self, selection: $selection) { url in
            HStack {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.callout).lineLimit(1)
                    Text(fileSizeText(for: url)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            // Multi-select is List's own native ⌘/⇧-click handling via the `selection:` binding
            // above — no manual checkbox state needed.
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        ZStack {
            Color.black.opacity(0.03)
            if selection.isEmpty {
                Text("Select a file to preview it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if selection.count > 1 {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("\(selection.count) files selected")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if isLoadingPreview {
                ProgressView()
            } else if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else if let url = selectedFiles.first {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No in-app preview for \(url.pathExtension.uppercased()) — try \"Show in Finder\" and open it with whatever handles that format.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button(selection.count == currentFiles.count ? "Deselect All" : "Select All") {
                selection = selection.count == currentFiles.count ? [] : Set(currentFiles)
            }
            .disabled(currentFiles.isEmpty)
            Spacer()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(selectedFiles)
            }
            .disabled(selection.isEmpty)
            Button("View") {
                guard let url = selectedFiles.first else { return }
                cameraManager.openExportedFile(url)
            }
            .disabled(selection.count != 1)
            Button("Delete…", role: .destructive) { isConfirmingDelete = true }
                .disabled(selection.isEmpty)
        }
        .padding()
    }

    private func deleteSelected() {
        for url in selectedFiles {
            try? FileManager.default.removeItem(at: url)
        }
        currentFiles.removeAll { selection.contains($0) }
        selection.removeAll()
        didDeleteAnything = true
    }

    private func loadPreview() {
        previewImage = nil
        guard selection.count == 1, let url = selectedFiles.first else { return }
        isLoadingPreview = true
        Task {
            let image = try? await Task.detached(priority: .userInitiated) {
                try CGImageRenderer.loadDisplayImage(from: url)
            }.value
            isLoadingPreview = false
            // The user may have changed the selection while this was loading — only apply a
            // preview that's still actually relevant.
            guard selection.count == 1, selectedFiles.first == url else { return }
            previewImage = image
        }
    }

    private func fileSizeText(for url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        return ByteCountFormatter.string(fromByteCount: Int64(size ?? 0), countStyle: .file)
    }
}

/// The data-dense alternative to `TimelineStripView`'s filmstrip — every capture in this session
/// as a table row, sortable by any column, for comparing disk usage/kind side by side and
/// multi-selecting for the bulk action bar above (`SessionDetailPane.capturesBulkActionBar`)
/// instead of one context menu at a time. Mirrors `ProjectDetailPane`'s own `SessionsTableView`
/// (which itself mirrors `ProjectsBrowserView`'s `ProjectsTableView`) for the same
/// Cards/Table-style tradeoff one level down.
private struct CapturesTableView: View {
    let project: Project
    let session: Session
    let store: ProjectStore
    /// A `Table`'s own selection is multi-select out of the box with a `Set` binding (click,
    /// ⌘-click, shift-click) — no separate "select mode" needed the way a filmstrip thumbnail's
    /// plain tap does, since a single click here already just selects rather than opening.
    @Binding var selectedIDs: Set<CaptureRecord.ID>
    var onSelect: (CaptureRecord) -> Void

    @State private var sortOrder = [KeyPathComparator(\CaptureRecord.date, order: .reverse)]

    private var sortedCaptures: [CaptureRecord] {
        session.captures.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedCaptures, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.date) { capture in
                Text(capture.date.formatted(date: .abbreviated, time: .shortened))
            }
            .width(150)
            TableColumn("File", value: \.fileName)
            TableColumn("Kind") { Text($0.kind.displayName) }
                .width(80)
            TableColumn("Object") { Text($0.object ?? "—") }
                .width(100)
            TableColumn("Disk Usage") { capture in
                Text(ByteCountFormatter.string(fromByteCount: store.diskUsage(for: capture, in: session, project: project), countStyle: .file))
            }
            .width(90)
            TableColumn("Note") { Text($0.note ?? "—") }
        }
        .contextMenu(forSelectionType: CaptureRecord.ID.self) { _ in
            // No per-row menu items yet — Show in Finder/Open in Siril/Delete live on the
            // filmstrip's own context menu, and the bulk action bar above covers Delete for a
            // selection.
        } primaryAction: { ids in
            guard let id = ids.first, let capture = session.captures.first(where: { $0.id == id }) else { return }
            onSelect(capture)
        }
    }
}
