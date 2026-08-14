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
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(session.captures.sorted(by: { $0.date > $1.date })) { capture in
                        TimelineThumbnailView(project: project, session: session, capture: capture, store: store)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(capture) }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 140)
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
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnailURL, let image = NSImage(contentsOf: thumbnailURL) {
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
            .frame(width: 110, height: 90)

            Text(capture.date, format: .dateTime.hour().minute())
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .help(capture.fileName)
        .contextMenu {
            Button("Show in Finder") {
                let url = store.sessionFolderURL(for: session, in: project).appendingPathComponent(capture.fileName)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}
