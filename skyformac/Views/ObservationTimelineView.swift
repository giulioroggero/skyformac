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
/// timeline — real elapsed time between captures *close together* becomes horizontal distance, so
/// a dense session's captures cluster proportionally. A gap longer than `maxGapHours` (a quiet
/// week/month/year between sessions) no longer stretches proportionally to its real length —
/// it's capped at `maxGapHours`' worth of width, so the timeline stays compact and scrollable
/// instead of mostly blank space between the handful of sessions that actually happened. Zooming
/// in spreads a cluster apart until individual captures (from different sessions/projects,
/// interleaved by when they actually happened) become separately tappable. Placed on the Home
/// page, above "Recent Projects."
struct ObservationTimelineView: View {
    let projects: [Project]
    var cameraManager: CameraManager
    var onSelect: (Project, Session, CaptureRecord) -> Void

    private let entries: [TimelineEntry]
    private let defaultPixelsPerHour: Double
    @State private var pixelsPerHour: Double

    private static let thumbnailSize: CGFloat = 72
    private static let laneHeight: CGFloat = thumbnailSize + 88
    /// The whole (gap-capped) span is scaled to roughly this many points wide at the default
    /// zoom — wide enough to read as a real timeline without opening already fully zoomed in.
    private static let targetInitialWidth: CGFloat = 1400
    /// Any inter-capture gap longer than this compresses to exactly this many hours' worth of
    /// width, regardless of how much real time actually passed — the fix for "remove the empty
    /// spaces between days, compress the timeline dynamically if there is no observation."
    private static let maxGapHours: Double = 6

    init(projects: [Project], cameraManager: CameraManager, onSelect: @escaping (Project, Session, CaptureRecord) -> Void) {
        self.projects = projects
        self.cameraManager = cameraManager
        self.onSelect = onSelect

        let built = Self.mergedEntries(from: projects)
        self.entries = built
        let compressedHours = Self.compressedTotalHours(for: built)
        let initial = max(Self.targetInitialWidth / compressedHours, 0.5)
        self.defaultPixelsPerHour = initial
        self._pixelsPerHour = State(initialValue: initial)
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

    /// Sum of every consecutive inter-capture gap, each capped at `maxGapHours` — the "real"
    /// total span with long quiet stretches compressed out, used both to pick a sensible default
    /// zoom (`defaultPixelsPerHour`) and, per-entry, to lay each thumbnail out
    /// (`compressedOffsetsInHours`). At least 0.1h so a single capture (or several in the same
    /// instant) doesn't divide by zero.
    nonisolated static func compressedTotalHours(for entries: [TimelineEntry]) -> Double {
        guard entries.count > 1 else { return 0.1 }
        var total = 0.0
        for i in 1..<entries.count {
            let gapHours = entries[i].capture.date.timeIntervalSince(entries[i - 1].capture.date) / 3600
            total += min(max(gapHours, 0), maxGapHours)
        }
        return max(total, 0.1)
    }

    /// Each entry's horizontal position, in hours from the first entry, with every inter-capture
    /// gap capped at `maxGapHours` — same index order as `entries`. `xOffset`s pixel positions
    /// come straight from multiplying these by `pixelsPerHour`.
    nonisolated static func compressedOffsetsInHours(for entries: [TimelineEntry]) -> [Double] {
        guard !entries.isEmpty else { return [] }
        var offsets = [0.0]
        for i in 1..<entries.count {
            let gapHours = entries[i].capture.date.timeIntervalSince(entries[i - 1].capture.date) / 3600
            offsets.append(offsets[i - 1] + min(max(gapHours, 0), maxGapHours))
        }
        return offsets
    }

    /// Lower bound stays relative to `defaultPixelsPerHour` (zooming *out* only ever needs to
    /// relate to how wide the actual data span already is). The upper bound doesn't — a purely
    /// relative ceiling (e.g. `defaultPixelsPerHour * 300`) shrinks to nothing for a timeline
    /// spanning months/years, since `defaultPixelsPerHour` itself is already tiny at that scale
    /// (see its own doc comment). An absolute floor of 3000 px/hour (50pt/minute — enough to tell
    /// captures a minute apart apart, per the actual request: "resolution of minutes") guarantees
    /// real minute-level zoom is always reachable regardless of how long the total span is.
    private var minPixelsPerHour: Double { defaultPixelsPerHour * 0.05 }
    private var maxPixelsPerHour: Double { max(defaultPixelsPerHour * 300, 3000) }

    /// "MM.dd.yy" — the big-number date header above the timeline, styled like a calendar page
    /// heading rather than a plain sentence date, matching the literal ask ("show the date in
    /// large number eg 08.14.26").
    private static let bigDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM.dd.yy"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                Text("No captures yet — once you've captured something, it shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if let mostRecentDate = entries.last?.capture.date {
                    Text(Self.bigDateFormatter.string(from: mostRecentDate))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                ScrollViewReader { proxy in
                    zoomControl(proxy: proxy)
                    ScrollView(.horizontal) {
                        timelineCanvas
                    }
                    .frame(height: Self.laneHeight)
                    .defaultScrollAnchor(.trailing)
                }
            }
        }
    }

    private func zoomControl(proxy: ScrollViewProxy) -> some View {
        HStack {
            Text("Zoom").font(.caption)
            Button {
                withAnimation { pixelsPerHour = minPixelsPerHour }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom all the way out")
            Slider(value: $pixelsPerHour, in: minPixelsPerHour...maxPixelsPerHour)
            Button {
                withAnimation { pixelsPerHour = maxPixelsPerHour }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom all the way in — minute-level resolution")
            if pixelsPerHour != defaultPixelsPerHour {
                Button("Reset") { withAnimation { pixelsPerHour = defaultPixelsPerHour } }
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
        .help("Zooms the timeline horizontally — captures close together in time spread apart as you zoom in, so a dense session's captures become individually tappable instead of overlapping.")
    }

    /// A thumbnail column's total footprint (`thumbnailView`'s own `.frame(width:)` below) —
    /// two entries whose x-positions are closer together than this would otherwise render on
    /// top of each other, their date/object labels overlapping into illegible text. `lanes(...)`
    /// below exists specifically to avoid that.
    private static let columnWidth: CGFloat = thumbnailSize + 16

    /// Greedily packs entries into rows ("lanes") so that no two entries sharing a lane are
    /// closer together (in actual pixels, at the current zoom) than `columnWidth` — the classic
    /// calendar-event lane-packing algorithm. Entries are visited in chronological order and each
    /// one joins the first lane whose most-recently-placed entry doesn't overlap it, or starts a
    /// new lane otherwise. Without this, two captures close in time (worse, two *different*
    /// sessions' captures landing near each other after `compressedOffsetsInHours`' gap-capping)
    /// rendered directly on top of one another.
    private func lanes(offsetsInHours: [Double]) -> [[Int]] {
        Self.lanes(offsetsInHours: offsetsInHours, pixelsPerHour: pixelsPerHour, columnWidth: Self.columnWidth)
    }

    /// Pure core of the lane-packing algorithm — `nonisolated static` (see `mergedEntries`'s own
    /// doc comment for why) so it's directly unit-testable without constructing a whole view.
    nonisolated static func lanes(offsetsInHours: [Double], pixelsPerHour: Double, columnWidth: CGFloat) -> [[Int]] {
        var laneRightEdges: [CGFloat] = []
        var laneAssignments: [[Int]] = []
        for i in offsetsInHours.indices {
            let x = CGFloat(offsetsInHours[i]) * pixelsPerHour
            if let laneIndex = laneRightEdges.firstIndex(where: { x >= $0 }) {
                laneAssignments[laneIndex].append(i)
                laneRightEdges[laneIndex] = x + columnWidth
            } else {
                laneAssignments.append([i])
                laneRightEdges.append(x + columnWidth)
            }
        }
        return laneAssignments
    }

    /// Real `HStack`s with computed leading padding between entries, not a `ZStack` of
    /// `.offset()`-positioned children — `.offset()` is a purely visual transform that doesn't
    /// change what the layout system (and, critically, `ScrollViewReader.scrollTo`) believes a
    /// view's own position actually is, which is exactly why "jump to most recent" could scroll
    /// to the wrong place: every absolutely-offset thumbnail reported the *same* pre-offset
    /// layout frame to the scroll view. Padding-based layout doesn't have that problem — each
    /// view's real position matches where it's actually drawn.
    @ViewBuilder
    private var timelineCanvas: some View {
        if !entries.isEmpty {
            let offsetsInHours = Self.compressedOffsetsInHours(for: entries)
            let totalWidth = CGFloat(offsetsInHours.last ?? 0) * pixelsPerHour + Self.thumbnailSize + 40
            let laneAssignments = lanes(offsetsInHours: offsetsInHours)
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: totalWidth, height: 2)
                    .padding(.leading, 20)
                    .padding(.top, Self.thumbnailSize / 2 + 24)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(laneAssignments.indices, id: \.self) { laneIndex in
                        laneRow(indices: laneAssignments[laneIndex], offsetsInHours: offsetsInHours)
                    }
                }
                .padding(.leading, 20)
            }
            .frame(width: totalWidth, height: Self.laneHeight * CGFloat(max(laneAssignments.count, 1)), alignment: .topLeading)
        }
    }

    /// One lane's own row — a plain `HStack` where each entry after the first is placed via
    /// `.padding(.leading:)` equal to the real pixel gap since the previous entry *in this same
    /// lane* (not the previous entry overall, since lane-packing may have skipped entries into
    /// other lanes in between).
    private func laneRow(indices: [Int], offsetsInHours: [Double]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(indices.enumerated()), id: \.element) { position, entryIndex in
                let x = CGFloat(offsetsInHours[entryIndex]) * pixelsPerHour
                let previousRightEdge = position == 0
                    ? 0
                    : CGFloat(offsetsInHours[indices[position - 1]]) * pixelsPerHour + Self.columnWidth
                thumbnailView(for: entries[entryIndex])
                    .padding(.leading, max(0, x - previousRightEdge))
                    .id(entries[entryIndex].id)
            }
        }
    }

    @ViewBuilder
    private func thumbnailView(for entry: TimelineEntry) -> some View {
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
        .frame(width: Self.thumbnailSize + 16)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(entry.project, entry.session, entry.capture) }
        .help("\(entry.project.name.isEmpty ? "Untitled Project" : entry.project.name) — \(entry.session.name)\n\(entry.capture.fileName)")
    }

    private func thumbnailURL(for entry: TimelineEntry) -> URL? {
        guard let name = entry.capture.thumbnailFileName else { return nil }
        return cameraManager.projectStore.thumbnailsFolderURL(for: entry.session, in: entry.project).appendingPathComponent(name)
    }
}
