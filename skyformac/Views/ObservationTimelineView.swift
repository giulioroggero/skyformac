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
/// timeline — real elapsed time between captures becomes horizontal distance, not just list order,
/// so a dense session's captures cluster tightly together and a quiet month between sessions shows
/// as real empty space. Zooming in spreads a cluster apart until individual captures (from
/// different sessions/projects, interleaved by when they actually happened) become separately
/// tappable. Placed on the Home page, above "Recent Projects."
struct ObservationTimelineView: View {
    let projects: [Project]
    var cameraManager: CameraManager
    var onSelect: (Project, Session, CaptureRecord) -> Void

    private let entries: [TimelineEntry]
    private let dateRange: ClosedRange<Date>?
    private let defaultPixelsPerHour: Double
    @State private var pixelsPerHour: Double

    private static let thumbnailSize: CGFloat = 72
    private static let laneHeight: CGFloat = thumbnailSize + 76
    /// The whole date range is scaled to roughly this many points wide at the default zoom — wide
    /// enough to read as a real timeline without opening already fully zoomed in.
    private static let targetInitialWidth: CGFloat = 1400

    init(projects: [Project], cameraManager: CameraManager, onSelect: @escaping (Project, Session, CaptureRecord) -> Void) {
        self.projects = projects
        self.cameraManager = cameraManager
        self.onSelect = onSelect

        let built = Self.mergedEntries(from: projects)
        self.entries = built
        let range = Self.dateRange(for: built)
        self.dateRange = range
        let initial = Self.defaultPixelsPerHour(for: range)
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

    /// `nil` for no captures anywhere. At least a minute wide even for a single capture (or
    /// several taken in the same instant) — a zero-width range would divide by zero in
    /// `defaultPixelsPerHour(for:)`.
    nonisolated static func dateRange(for entries: [TimelineEntry]) -> ClosedRange<Date>? {
        entries.first.map { first in
            let last = entries.last?.capture.date ?? first.capture.date
            return first.capture.date...max(last, first.capture.date.addingTimeInterval(60))
        }
    }

    /// Scales `range` to roughly `targetInitialWidth` points wide — wide enough to read as a real
    /// timeline without opening already fully zoomed in, regardless of whether the actual data
    /// spans a day or several years.
    nonisolated static func defaultPixelsPerHour(for range: ClosedRange<Date>?) -> Double {
        let totalHours = range.map { max($0.upperBound.timeIntervalSince($0.lowerBound) / 3600, 0.1) } ?? 1
        return max(targetInitialWidth / totalHours, 0.5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if entries.isEmpty {
                Text("No captures yet — once you've captured something, it shows up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                zoomControl
                ScrollView(.horizontal) {
                    timelineCanvas
                }
                .frame(height: Self.laneHeight)
                .defaultScrollAnchor(.trailing)
            }
        }
    }

    private var zoomControl: some View {
        HStack {
            Text("Zoom").font(.caption)
            Slider(value: $pixelsPerHour, in: (defaultPixelsPerHour * 0.05)...(defaultPixelsPerHour * 40))
            if pixelsPerHour != defaultPixelsPerHour {
                Button("Reset") { pixelsPerHour = defaultPixelsPerHour }
                    .font(.caption)
                    .controlSize(.small)
            }
        }
        .help("Zooms the timeline horizontally — captures close together in time spread apart as you zoom in, so a dense session's captures become individually tappable instead of overlapping.")
    }

    /// A `ZStack` with every capture positioned by an explicit `.offset`, not a `HStack` — the
    /// whole point is real time becoming real horizontal distance, which a stack's own "one after
    /// another" layout can't express. `.offset` doesn't itself grow the `ZStack`'s reported size
    /// (it only moves a view visually), so the outer `.frame(width:height:alignment: .topLeading)`
    /// below is what actually gives `ScrollView` the right scrollable width — the offsets alone
    /// would silently render past the stack's bounds without it.
    @ViewBuilder
    private var timelineCanvas: some View {
        if let dateRange {
            let totalWidth = xOffset(for: dateRange.upperBound, start: dateRange.lowerBound) + Self.thumbnailSize + 40
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: totalWidth, height: 2)
                    .offset(x: 20, y: Self.thumbnailSize / 2 + 24)
                ForEach(entries) { entry in
                    thumbnailView(for: entry)
                        .offset(x: xOffset(for: entry.capture.date, start: dateRange.lowerBound) + 20, y: 0)
                }
            }
            .frame(width: totalWidth, height: Self.laneHeight, alignment: .topLeading)
        }
    }

    private func xOffset(for date: Date, start: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(start) / 3600) * pixelsPerHour
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

            Text(entry.capture.date.formatted(.dateTime.month(.abbreviated).day()))
                .font(.system(size: 9))
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
