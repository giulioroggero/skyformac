import SwiftUI

/// "Create a new section: gallery, where the user can see all post-processed images" — every
/// `ElaboratedImage` across every active project, newest first, in one place instead of having to
/// open each project's own Elaborated section separately to find one. Reuses `ElaboratedImageCard`
/// directly (the same tap-to-view-full-screen, context menu, Info sheet, and Third-Party Tools
/// menu it already has in a project's own gallery) rather than a second, parallel card
/// implementation — this page is just a different (project-spanning) collection of the same cards.
struct GalleryView: View {
    var cameraManager: CameraManager
    let projects: [Project]
    var onBack: () -> Void

    private struct Entry: Identifiable {
        let project: Project
        let image: ElaboratedImage
        var id: UUID { image.id }
    }

    /// Newest first — matches every other "everything, across projects" list in this app
    /// (Insights' own activity buckets, the Home page's Recent Projects).
    private var entries: [Entry] {
        projects.flatMap { project in project.elaboratedImages.map { Entry(project: project, image: $0) } }
            .sorted { $0.image.date > $1.image.date }
    }

    var body: some View {
        ScrollView {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Elaborated Images Yet", systemImage: "photo.on.rectangle.angled",
                    description: Text("Post-process a capture — or send one to Siril, GraXpert, or StarNet — and it shows up here.")
                )
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 20) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            ElaboratedImageCard(project: entry.project, image: entry.image, cameraManager: cameraManager)
                            Text(entry.project.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationTitle("Gallery")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: onBack)
            }
            OpenAssistantToolbarItem(cameraManager: cameraManager)
        }
    }
}
