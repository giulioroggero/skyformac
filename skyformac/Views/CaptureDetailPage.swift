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
            return NSImage(contentsOf: fileURL) ?? thumbnailURL.flatMap(NSImage.init(contentsOf:))
        case .fits, .serVideo, .recording:
            return thumbnailURL.flatMap(NSImage.init(contentsOf:))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection {
                    HStack {
                        Spacer(minLength: 0)
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
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
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
    }

    private var fileStats: [StatItem] {
        [
            StatItem(label: "File", value: capture.fileName),
            StatItem(label: "Kind", value: capture.kind.displayName),
            StatItem(label: "Date", value: capture.date.formatted(date: .abbreviated, time: .shortened)),
        ]
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
