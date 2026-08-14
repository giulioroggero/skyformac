import SwiftUI

/// One past action with actual camera parameters attached — what `RecallParametersView` lists,
/// flattened out of every project/session's own captures rather than making the user drill down
/// through the browser to find one worth reusing.
private struct RecallableAction: Identifiable {
    var id: CaptureRecord.ID { capture.id }
    let capture: CaptureRecord
    let project: Project
    let session: Session
}

/// "Recall the parameters used in a previous action" — every past capture that actually has an
/// `AcquisitionPreset` attached (every capture recorded since this field was added), newest
/// first, so setting up a similar shot again is picking from history instead of re-dialing in
/// gain/exposure/ROI/mode by hand. Selecting one calls `CameraManager.recallParameters(_:)` and
/// dismisses — applied immediately if a camera's connected, held pending otherwise.
struct RecallParametersView: View {
    var cameraManager: CameraManager
    @Environment(\.dismiss) private var dismiss

    private var actions: [RecallableAction] {
        cameraManager.projectsLibrary.activeProjects
            .flatMap { project in
                project.sessions.flatMap { session in
                    session.captures.compactMap { capture -> RecallableAction? in
                        guard capture.preset != nil else { return nil }
                        return RecallableAction(capture: capture, project: project, session: session)
                    }
                }
            }
            .sorted { $0.capture.date > $1.capture.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Recall Parameters").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            if actions.isEmpty {
                ContentUnavailableView(
                    "No Past Actions Yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Once you've captured something, its parameters show up here to reuse next time.")
                )
                .frame(maxHeight: .infinity)
            } else {
                List(actions) { action in
                    Button {
                        cameraManager.recallParameters(action.capture.preset!)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(action.capture.note ?? action.capture.kind.displayName)
                                .font(.body)
                            Text(action.capture.preset!.summaryLine)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(action.project.name) — \(action.session.name) · \(action.capture.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 480, height: 480)
    }
}
