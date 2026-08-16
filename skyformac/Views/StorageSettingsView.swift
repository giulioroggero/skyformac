import SwiftUI

/// Settings' "Storage" tab — where all that disk space captures/sessions/projects actually use
/// went, and a way to reclaim it without leaving Settings to hunt through the Projects browser.
/// Every project is expandable down to individual captures, each with its own real file size
/// (`ProjectStore.diskUsage`) and a delete action, sorted biggest-first so whatever's actually
/// worth deleting to free up space is easy to find rather than buried alphabetically.
struct StorageSettingsView: View {
    var cameraManager: CameraManager

    private var library: ProjectsLibrary { cameraManager.projectsLibrary }
    private var store: ProjectStore { cameraManager.projectStore }

    private var sortedProjects: [Project] {
        library.projects.sorted { store.diskUsage(for: $0) > store.diskUsage(for: $1) }
    }

    private var totalUsage: Int64 {
        store.totalDiskUsage(for: library.projects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Total across every project").foregroundStyle(.secondary)
                Spacer()
                Text(Self.formattedBytes(totalUsage)).font(.headline.monospacedDigit())
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.background.secondary)

            if library.projects.isEmpty {
                ContentUnavailableView("No Projects Yet", systemImage: "internaldrive")
            } else {
                List {
                    ForEach(sortedProjects) { project in
                        ProjectStorageRow(project: project, cameraManager: cameraManager)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    static func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct ProjectStorageRow: View {
    let project: Project
    var cameraManager: CameraManager
    @State private var isExpanded = false

    private var store: ProjectStore { cameraManager.projectStore }

    private var sortedSessions: [Session] {
        project.sessions.sorted { store.diskUsage(for: $0, in: project) > store.diskUsage(for: $1, in: project) }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(sortedSessions) { session in
                SessionStorageRow(project: project, session: session, cameraManager: cameraManager)
                    .padding(.leading, 16)
            }
        } label: {
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(project.name.isEmpty ? "Untitled Project" : project.name)
                Spacer()
                Text(StorageSettingsView.formattedBytes(store.diskUsage(for: project)))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
        }
    }
}

private struct SessionStorageRow: View {
    let project: Project
    let session: Session
    var cameraManager: CameraManager
    @State private var isExpanded = false
    @State private var pendingDeleteCapture: CaptureRecord?

    private var store: ProjectStore { cameraManager.projectStore }
    private var library: ProjectsLibrary { cameraManager.projectsLibrary }

    private var sortedCaptures: [CaptureRecord] {
        session.captures.sorted {
            store.diskUsage(for: $0, in: session, project: project) > store.diskUsage(for: $1, in: session, project: project)
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if session.captures.isEmpty {
                Text("No captures").font(.caption).foregroundStyle(.tertiary).padding(.leading, 16)
            }
            ForEach(sortedCaptures) { capture in
                HStack {
                    Image(systemName: capture.kind.icon).foregroundStyle(.secondary).font(.caption)
                    Text(capture.fileName).font(.caption).lineLimit(1)
                    Spacer()
                    Text(StorageSettingsView.formattedBytes(store.diskUsage(for: capture, in: session, project: project)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        pendingDeleteCapture = capture
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Delete this capture")
                }
                .padding(.leading, 16)
            }
        } label: {
            HStack {
                Image(systemName: "calendar").foregroundStyle(.secondary)
                Text(session.name)
                Spacer()
                Text(StorageSettingsView.formattedBytes(store.diskUsage(for: session, in: project)))
                    .foregroundStyle(.secondary)
                    .font(.callout.monospacedDigit())
            }
        }
        .confirmationDialog(
            "Delete this capture?",
            isPresented: Binding(get: { pendingDeleteCapture != nil }, set: { if !$0 { pendingDeleteCapture = nil } }),
            titleVisibility: .visible
        ) {
            if let capture = pendingDeleteCapture {
                Button("Delete \(capture.fileName)", role: .destructive) {
                    try? library.deleteCapture(capture.id, fromSessionID: session.id, in: project)
                    pendingDeleteCapture = nil
                }
            }
        } message: {
            Text("This removes the file and its thumbnail from disk — this can't be undone.")
        }
    }
}
