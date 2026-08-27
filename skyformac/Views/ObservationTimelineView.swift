import SwiftUI

/// One capture, plus which project/session it came from — the thing `ObservationTimelineView`
/// actually plots. Every other list in this app (`TimelineStripView`, `ProjectDetailPane`'s
/// Sessions list) walks one project or one session at a time; this is the one place that flattens
/// every session across every project into a single interleaved sequence, so it needs to carry
/// that context back with each capture in order to resolve a thumbnail (`ProjectStore` needs both
/// `project` and `session` to find the right folder) and to navigate to it (Home has to push all
/// three levels — project, session, capture — at once, since it starts from zero).
struct TimelineEntry: Identifiable {
    var id: CaptureRecord.ID { capture.id }
    let project: Project
    let session: Session
    let capture: CaptureRecord
}

/// Every capture from every session across every project, merged into one chronological, zoomable
/// timeline. Spacing between thumbnails is purely index-based — one fixed "per-thumbnail" width
/// at a time, not proportional to how much real time separates two captures — so the strip's
/// scale depends only on how many captures there are, and there's never any dead, empty stretch
/// between two thumbnails just because a lot of real time passed between them. Zooming in spreads
/// everything apart until individual captures become easier to tap; zooming out packs them
/// tighter, letting nearby ones visually overlap the same way a crowded film strip would. Placed
/// on the Home page, above "Recent Projects."
struct ObservationTimelineView: View {
    let projects: [Project]
    var cameraManager: CameraManager
    var onSelect: (Project, Session, CaptureRecord) -> Void

    private let entries: [TimelineEntry]
    private let defaultPixelsPerThumbnail: Double
    @State private var pixelsPerThumbnail: Double
    /// Tracked live via `.scrollPosition(id:)` below — whichever entry is currently at the
    /// scroll view's own anchor point. Drives the big date header (so it reflects whatever's
    /// actually on screen, not always the single most recent capture) and doubles as the anchor
    /// `rezoom(to:)` re-scrolls back to after a zoom change, instead of leaving the view to land
    /// wherever the new (often much narrower or wider) content width happens to clamp the old
    /// absolute scroll offset to — previously, that was usually the very first, oldest thumbnail.
    @State private var visibleEntryID: CaptureRecord.ID?
    /// "If the user press on the icon she can post process the capture" — `CaptureKindBadge`'s
    /// own tap target, bypassing the full Capture page (this timeline flattens every project's
    /// own sessions, so there's no single `project`/`session` this view already has in scope the
    /// way `TimelineStripView`'s per-session version does — each entry carries its own).
    /// "The edit/preview windows can be moved across the screen and resized" — see
    /// `CaptureDetailPage`'s identical property doc comment for why this is a
    /// `DetachedContentWindowController?` rather than the `TimelineEntry?` + `.sheet(item:)`
    /// these used to be.
    @State private var postProcessingWindowController: DetachedContentWindowController?
    @State private var editingImageWindowController: DetachedContentWindowController?

    /// `nonisolated` on these plain constants (not just the functions that read them) — `View`
    /// conformance infers this whole type's static members as `@MainActor` by default, and
    /// `defaultPixelsPerThumbnail(count:)` below (itself `nonisolated` so it's callable from
    /// `init`/off the main actor) reads `columnWidth`/`targetInitialWidth` directly. Xcode 16.4's
    /// Swift 6 checker flags that cross-isolation read even though these are just constants with
    /// no actual actor affinity — a newer toolchain's checker apparently doesn't require this,
    /// which is why it didn't reproduce locally.
    private nonisolated static let thumbnailSize: CGFloat = 72
    private nonisolated static let laneHeight: CGFloat = thumbnailSize + 88
    /// A thumbnail column's total footprint (`thumbnailView`'s own `.frame(width:)` below) — the
    /// spacing `showsText(forVisibleIndices:pixelsPerThumbnail:columnWidth:)` compares against to
    /// decide how many thumbnails apart a text label can safely appear.
    private nonisolated static let columnWidth: CGFloat = thumbnailSize + 16
    /// The whole strip is scaled to roughly this many points wide at the default zoom, however
    /// many captures there are — wide enough to read as a real timeline without opening already
    /// fully zoomed in.
    private nonisolated static let targetInitialWidth: CGFloat = 1400
    /// Below this per-thumbnail spacing, `visibleIndices(count:pixelsPerThumbnail:minVisibleWidth:)`
    /// starts hiding some thumbnails entirely (not just their text) so every thumbnail that *is*
    /// shown still gets at least this many points — packing them any tighter than this stops
    /// reading as individual images at all. Zooming back in re-reveals them, since which indices
    /// are visible is recomputed fresh from `pixelsPerThumbnail` on every render.
    private nonisolated static let minVisibleThumbnailWidth: CGFloat = 25

    init(projects: [Project], cameraManager: CameraManager, onSelect: @escaping (Project, Session, CaptureRecord) -> Void) {
        self.projects = projects
        self.cameraManager = cameraManager
        self.onSelect = onSelect

        let built = Self.mergedEntries(from: projects)
        self.entries = built
        let initial = Self.defaultPixelsPerThumbnail(count: built.count)
        self.defaultPixelsPerThumbnail = initial
        self._pixelsPerThumbnail = State(initialValue: initial)
    }

    /// Every capture from every session across every project, interleaved chronologically —
    /// pulled out as a pure static function (rather than inline in `init`) so the merge/sort logic
    /// itself is unit-testable without constructing a `CameraManager`/SwiftUI view. `nonisolated`
    /// because `View` conformance otherwise infers this whole type (including its static members)
    /// as `@MainActor` — these three are pure functions with no view state, and a test calling
    /// them off the main actor would otherwise trip a MainActor-isolation crash at runtime.
    nonisolated static func mergedEntries(from projects: [Project]) -> [TimelineEntry] {
        projects.flatMap { project in
            project.sessions.flatMap { session in
                session.captures.map { TimelineEntry(project: project, session: session, capture: $0) }
            }
        }.sorted { $0.capture.date < $1.capture.date }
    }

    /// Fits `count` thumbnails, evenly spaced by index, into roughly `targetInitialWidth` points
    /// — "the scale of the timeline ... depends on how many thumbnails are present," not on how
    /// much real time separates them. At least 1pt so a single/no-capture timeline doesn't divide
    /// by zero.
    nonisolated static func defaultPixelsPerThumbnail(count: Int) -> Double {
        guard count > 1 else { return Double(columnWidth) }
        return max(Double(targetInitialWidth) / Double(count - 1), 1)
    }

    /// Lower bound stays relative to `defaultPixelsPerThumbnail` (zooming *out* only ever needs
    /// to relate to how wide the actual strip already is at its default scale). The upper bound
    /// has an absolute floor too (three column-widths) so zooming in always reaches a spacing
    /// wide enough to fully separate every thumbnail, however many there are.
    private var minPixelsPerThumbnail: Double { max(defaultPixelsPerThumbnail * 0.1, 1) }
    private var maxPixelsPerThumbnail: Double { max(defaultPixelsPerThumbnail * 10, Double(Self.columnWidth) * 3) }

    /// "MM.dd.yy" — the big-number date header above the timeline, styled like a calendar page
    /// heading rather than a plain sentence date.
    private static let bigDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM.dd.yy"
        return formatter
    }()

    /// Whichever entry the header should show the date of — `visibleEntryID` once the user has
    /// scrolled/zoomed at all, otherwise the most recent capture (matching where the strip
    /// actually opens, `.defaultScrollAnchor(.trailing)` below).
    private var headerDate: Date? {
        (entries.first(where: { $0.id == visibleEntryID }) ?? entries.last)?.capture.date
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                Text("No captures yet — once you've captured something, it shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if let headerDate {
                    Text(Self.bigDateFormatter.string(from: headerDate))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                ScrollViewReader { proxy in
                    zoomControl(proxy: proxy)
                    ScrollView(.horizontal) {
                        timelineCanvas
                    }
                    .scrollPosition(id: $visibleEntryID)
                    .frame(height: Self.laneHeight)
                    .defaultScrollAnchor(.trailing)
                    .onChange(of: pixelsPerThumbnail) { _, _ in
                        rezoom(proxy: proxy)
                    }
                }
            }
        }
    }

    private func fileURL(for entry: TimelineEntry) -> URL {
        cameraManager.projectStore.sessionFolderURL(for: entry.session, in: entry.project)
            .appendingPathComponent(entry.capture.fileName)
    }

    /// `CaptureKindBadge`'s tap target — same routing as `TimelineStripView`'s own
    /// `startPostProcessing()`.
    private func startPostProcessing(for entry: TimelineEntry) {
        switch entry.capture.kind {
        case .serVideo: openPostProcessingWindow(for: entry)
        case .fits, .png, .tiff: openEditingImageWindow(for: entry)
        case .recording: break
        }
    }

    private func openPostProcessingWindow(for entry: TimelineEntry) {
        postProcessingWindowController = DetachedContentWindowController(
            title: "Planetary Post-Processing", contentSize: PlanetaryPostProcessingView.fullScreenSize,
            minSize: PlanetaryPostProcessingView.minWindowSize,
            onClose: { postProcessingWindowController = nil }
        ) {
            PlanetaryPostProcessingView(
                sourceURLs: [fileURL(for: entry)],
                sourceDescription: "Post-processing \(entry.capture.fileName).",
                onSave: { cgImage, title, notes, settings in
                    try cameraManager.savePlanetaryPostProcessingResult(
                        cgImage, sourceSessionIDs: [entry.session.id], sourceCaptureID: entry.capture.id,
                        project: entry.project, title: title, notes: notes, settings: settings
                    )
                },
                onOverwrite: { cgImage, existing, title, notes, settings in
                    try cameraManager.overwritePlanetaryPostProcessingResult(
                        cgImage, existing: existing, project: entry.project, title: title, notes: notes, settings: settings
                    )
                },
                resolveGraXpertInputURL: { image in
                    cameraManager.projectStore.elaboratedImagesFolderURL(for: entry.project).appendingPathComponent(image.fileName)
                },
                onSendToGraXpert: { inputURL, operation, parameters, onLog in
                    try await cameraManager.sendToGraXpert(
                        inputURL: inputURL, operation: operation, sourceSessionIDs: [entry.session.id],
                        sourceCaptureID: entry.capture.id, project: entry.project, parameters: parameters, onLog: onLog
                    )
                },
                onOpenGraXpertSettings: { cameraManager.isSettingsPresented = true },
                onDismiss: { postProcessingWindowController?.close() }
            )
        }
        postProcessingWindowController?.showWindow(nil)
    }

    private func openEditingImageWindow(for entry: TimelineEntry) {
        editingImageWindowController = DetachedContentWindowController(
            title: "Edit Image", contentSize: SingleImagePostProcessingView.fullScreenSize,
            minSize: SingleImagePostProcessingView.minWindowSize,
            onClose: { editingImageWindowController = nil }
        ) {
            SingleImagePostProcessingView(
                sourceURL: fileURL(for: entry),
                sourceDescription: "Editing \(entry.capture.fileName).",
                elaboratedImagesFolderURL: cameraManager.projectStore.elaboratedImagesFolderURL(for: entry.project),
                onSave: { cgImage in
                    try cameraManager.saveImageEditResult(
                        cgImage, sourceSessionIDs: [entry.session.id], sourceCaptureID: entry.capture.id, project: entry.project
                    )
                },
                onDismiss: { editingImageWindowController?.close() }
            )
        }
        editingImageWindowController?.showWindow(nil)
    }

    /// Re-anchors the scroll view to whatever was actually visible right before a zoom change —
    /// the fix for "the zoom in/out show only the most old thumb": changing `pixelsPerThumbnail`
    /// changes the strip's total width, and without this the scroll view was left wherever its
    /// old absolute scroll offset happened to clamp to against the new width, which after
    /// zooming out (a much narrower strip) was usually all the way back to the first, oldest
    /// thumbnail. Dispatched to the next runloop tick since the new width from this same
    /// `pixelsPerThumbnail` change needs to actually land before `scrollTo` has anywhere new to
    /// scroll to.
    private func rezoom(proxy: ScrollViewProxy) {
        guard let anchorID = visibleEntryID ?? entries.last?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(anchorID, anchor: .center)
        }
    }

    private func zoomControl(proxy: ScrollViewProxy) -> some View {
        HStack {
            Text("Zoom").font(.caption)
            Button {
                withAnimation { pixelsPerThumbnail = minPixelsPerThumbnail }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom all the way out")
            Slider(value: $pixelsPerThumbnail, in: minPixelsPerThumbnail...maxPixelsPerThumbnail)
            Button {
                withAnimation { pixelsPerThumbnail = maxPixelsPerThumbnail }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom all the way in — every thumbnail fully separated")
            if pixelsPerThumbnail != defaultPixelsPerThumbnail {
                Button("Reset") { withAnimation { pixelsPerThumbnail = defaultPixelsPerThumbnail } }
                    .font(.caption)
                    .controlSize(.small)
            }
            Divider().frame(height: 14)
            Button {
                guard let lastID = entries.last?.id else { return }
                withAnimation { proxy.scrollTo(lastID, anchor: .trailing) }
            } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .help("Jump to the most recent capture")
        }
        .help("Zooms the timeline horizontally — captures spread apart as you zoom in, so a dense session's captures become individually tappable instead of overlapping.")
    }

    /// Below `minVisibleThumbnailWidth` per-thumbnail spacing, not every thumbnail gets shown at
    /// all — packed any tighter and they'd stop reading as individual images regardless of text.
    /// Picks a fixed stride (every Nth index) rather than hiding by real time gaps, always
    /// keeping the very first and last (most recent) index so "jump to most recent" and the
    /// leading edge always have something real to land on. `nonisolated static` — see
    /// `mergedEntries`'s own doc comment for why — so it's directly unit-testable.
    nonisolated static func visibleIndices(count: Int, pixelsPerThumbnail: Double, minVisibleWidth: Double) -> [Int] {
        guard count > 0 else { return [] }
        let stride = max(1, Int((minVisibleWidth / max(pixelsPerThumbnail, 1)).rounded(.up)))
        var indices = Swift.stride(from: 0, to: count, by: stride).map { $0 }
        if indices.last != count - 1 {
            indices.append(count - 1)
        }
        return indices
    }

    /// Real thumbnails are allowed to overlap when zoomed out just short of
    /// `minVisibleThumbnailWidth` (a crowded run of captures visually stacks, rather than
    /// reserving empty space to keep every one fully apart) — only each *shown* entry's text
    /// (object name + date, the part that actually becomes unreadable when two captures land
    /// close together) gets suppressed, on a fixed stride evaluated against each entry's own
    /// absolute index (not its position within `indices`) so it stays a stable, periodic pattern
    /// regardless of which indices `visibleIndices` happens to have hidden. Parallel to
    /// `indices`, not to every entry. `columnWidth` is threaded through as a parameter (rather
    /// than reading the `private` constant directly) for the same testability reason as
    /// `mergedEntries`.
    nonisolated static func showsText(forVisibleIndices indices: [Int], pixelsPerThumbnail: Double, columnWidth: Double) -> [Bool] {
        let stride = max(1, Int((columnWidth / max(pixelsPerThumbnail, 1)).rounded(.up)))
        return indices.map { $0 % stride == 0 }
    }

    /// A real `HStack`, not a `ZStack` of `.offset()`-positioned children — `.offset()` is a
    /// purely visual transform that doesn't change what the layout system (and, critically,
    /// `ScrollViewReader.scrollTo`/`.scrollPosition(id:)`) believes a view's own position
    /// actually is. Every entry's *absolute* position is still `index * pixelsPerThumbnail`
    /// regardless of its actual capture date (see this type's own doc comment for why) — only
    /// which entries actually render (`visibleIndices` above) responds to zoom.
    @ViewBuilder
    private var timelineCanvas: some View {
        if !entries.isEmpty {
            let totalWidth = CGFloat(entries.count - 1) * pixelsPerThumbnail + Self.thumbnailSize + 40
            let visibleIndices = Self.visibleIndices(
                count: entries.count, pixelsPerThumbnail: pixelsPerThumbnail, minVisibleWidth: Double(Self.minVisibleThumbnailWidth)
            )
            let showsText = Self.showsText(
                forVisibleIndices: visibleIndices, pixelsPerThumbnail: pixelsPerThumbnail, columnWidth: Double(Self.columnWidth)
            )
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: totalWidth, height: 2)
                    .padding(.leading, 20)
                    .padding(.top, Self.thumbnailSize / 2 + 24)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(visibleIndices.enumerated()), id: \.element) { position, entryIndex in
                        let previousEntryIndex = position == 0 ? 0 : visibleIndices[position - 1]
                        let gap = position == 0
                            ? CGFloat(entryIndex) * pixelsPerThumbnail
                            : CGFloat(entryIndex - previousEntryIndex) * pixelsPerThumbnail - Self.columnWidth
                        thumbnailView(for: entries[entryIndex], showsText: showsText[position])
                            .padding(.leading, position == 0 ? gap + 20 : gap)
                            .id(entries[entryIndex].id)
                            // Later (visually rightmost/more-recent) thumbnails draw on top of
                            // whatever they overlap, same as `zIndex` ordering elsewhere in this
                            // app — reads more naturally than an earlier capture covering a later
                            // one.
                            .zIndex(Double(entryIndex))
                    }
                }
                .scrollTargetLayout()
            }
            .frame(width: totalWidth, height: Self.laneHeight, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func thumbnailView(for entry: TimelineEntry, showsText: Bool) -> some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let url = thumbnailURL(for: entry), let image = ThumbnailCache.image(at: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: entry.capture.kind.icon)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                CaptureKindBadge(kind: entry.capture.kind) { startPostProcessing(for: entry) }
                    .padding(3)
            }
            // A crowded run of captures shows no text under any of them rather than text that
            // collides into illegible overlapping characters — the full detail (object, session,
            // filename) is always still one hover away via `.help` below.
            if showsText {
                if let object = entry.capture.object, !object.isEmpty {
                    Text(object)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(entry.capture.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.thumbnailSize + 16)
        .background(.background)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(entry.project, entry.session, entry.capture) }
        .help("\(entry.project.name.isEmpty ? "Untitled Project" : entry.project.name) — \(entry.session.name)\n\(entry.capture.fileName)")
    }

    private func thumbnailURL(for entry: TimelineEntry) -> URL? {
        guard let name = entry.capture.thumbnailFileName else { return nil }
        return cameraManager.projectStore.thumbnailsFolderURL(for: entry.session, in: entry.project).appendingPathComponent(name)
    }
}
