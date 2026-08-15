import SwiftUI

/// A horizontal filmstrip of a session's captures — the iMovie-style "timeline with thumbnails"
/// the Projects feature is built around. Purely a viewer: reordering/deleting individual captures
/// isn't a thing this app needs (captures arrive in capture order and stay that way). Tapping a
/// thumbnail pushes that capture's own full-width Capture page (`onSelect`).
struct TimelineStripView: View {
    let project: Project
    let session: Session
    let store: ProjectStore
    var onSelect: (CaptureRecord) -> Void

    var body: some View {
        if session.captures.isEmpty {
            ContentUnavailableView(
                "No Captures Yet", systemImage: "film",
                description: Text("Frames exported or recorded while this session is active will show up here.")
            )
            .frame(height: 140)
        } else {
            // Newest first, left to right — `>` sorts a later date before an earlier one, and an
            // `HStack` lays out its first element leftmost, so the most recent capture is always
            // the leftmost thumbnail.
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(session.captures.sorted(by: { $0.date > $1.date })) { capture in
                        TimelineThumbnailView(project: project, session: session, capture: capture, store: store)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(capture) }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 190)
        }
    }
}

private struct TimelineThumbnailView: View {
    let project: Project
    let session: Session
    let capture: CaptureRecord
    let store: ProjectStore

    private var thumbnailURL: URL? {
        guard let name = capture.thumbnailFileName else { return nil }
        return store.thumbnailsFolderURL(for: session, in: project).appendingPathComponent(name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
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

            Text(capture.date, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(capture.kind.displayName)
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
        }
    }
}
