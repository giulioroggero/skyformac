import SwiftUI

/// "Create a new section: gallery, where the user can see all post-processed images" — every
/// `ElaboratedImage` across every active project, newest first, in one place instead of having to
/// open each project's own Elaborated section separately to find one. Reuses `ElaboratedImageCard`
/// directly (the same tap-to-view-full-screen, context menu, Info sheet, and Third-Party Tools
/// menu it already has in a project's own gallery) rather than a second, parallel card
/// implementation — this page is just a different (project-spanning) collection of the same cards.
///
/// "Create a sidebar similar to Apple Photos to organize albums/folders, favorites (up to 6),
/// auto-organize by object" — `GalleryLibrary` (`AppSettings.galleryLibrary`) is the persisted
/// organization; this view is both its editor and its browser. Deliberately one level of folder
/// nesting (a folder holds albums, not other folders) rather than Photos' own arbitrary depth —
/// see `GalleryFolder`'s own doc comment for why.
struct GalleryView: View {
    var cameraManager: CameraManager
    let projects: [Project]
    var onHome: () -> Void

    private struct Entry: Identifiable {
        let project: Project
        let image: ElaboratedImage
        var id: UUID { image.id }
    }

    private enum Selection: Hashable {
        case allPhotos
        case favorites
        case album(UUID)
    }

    fileprivate enum NamePromptKind {
        case newAlbum
        case newAlbumWithImage(UUID)
        case newFolder
        case renameAlbum(UUID)
        case renameFolder(UUID)
    }

    @State private var library = AppSettings.galleryLibrary
    @State private var selection: Selection = .allPhotos
    @State private var searchText = ""
    @State private var namePrompt: NamePromptKind?
    @State private var nameText = ""
    @State private var confirmingDeleteAlbum: GalleryAlbum?
    @State private var confirmingDeleteFolder: GalleryFolder?
    @State private var isAutoOrganizing = false

    /// Newest first — matches every other "everything, across projects" list in this app
    /// (Insights' own activity buckets, the Home page's Recent Projects).
    private var allEntries: [Entry] {
        projects.flatMap { project in project.elaboratedImages.map { Entry(project: project, image: $0) } }
            .sorted { $0.image.date > $1.image.date }
    }

    private var entriesByID: [UUID: Entry] {
        Dictionary(uniqueKeysWithValues: allEntries.map { ($0.id, $0) })
    }

    private var favoriteEntries: [Entry] {
        library.favoriteImageIDs.compactMap { entriesByID[$0] }
    }

    private var selectedAlbum: GalleryAlbum? {
        if case .album(let id) = selection { return library.albums.first { $0.id == id } }
        return nil
    }

    private var displayedEntries: [Entry] {
        let base: [Entry]
        switch selection {
        case .allPhotos: base = allEntries
        case .favorites: base = favoriteEntries
        case .album(let id):
            guard let album = library.albums.first(where: { $0.id == id }) else { return [] }
            base = album.imageIDs.compactMap { entriesByID[$0] }
        }
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSearch.isEmpty else { return base }
        return base.filter { $0.image.displayLabel.localizedCaseInsensitiveContains(trimmedSearch) }
    }

    private var selectionTitle: String {
        switch selection {
        case .allPhotos: return "Gallery"
        case .favorites: return "Favorites"
        case .album(let id): return library.albums.first { $0.id == id }?.name ?? "Album"
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            content
        }
        .navigationTitle(selectionTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Home", systemImage: "house", action: onHome)
            }
            OpenAssistantToolbarItem(cameraManager: cameraManager)
        }
        .popover(item: $namePrompt) { kind in
            namePromptContent(kind)
        }
        .confirmationDialog(
            confirmingDeleteAlbum.map { "Delete \"\($0.name)\"?" } ?? "",
            isPresented: Binding(get: { confirmingDeleteAlbum != nil }, set: { if !$0 { confirmingDeleteAlbum = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                guard let album = confirmingDeleteAlbum else { return }
                if selection == .album(album.id) { selection = .allPhotos }
                library.deleteAlbum(album.id)
                save()
            }
        } message: {
            Text("The images themselves aren't deleted — only the album.")
        }
        .confirmationDialog(
            confirmingDeleteFolder.map { "Delete \"\($0.name)\" and every album inside it?" } ?? "",
            isPresented: Binding(get: { confirmingDeleteFolder != nil }, set: { if !$0 { confirmingDeleteFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                guard let folder = confirmingDeleteFolder else { return }
                if case .album(let id) = selection, library.albums.first(where: { $0.id == id })?.parentFolderID == folder.id {
                    selection = .allPhotos
                }
                library.deleteFolder(folder.id)
                save()
            }
        } message: {
            Text("The images themselves aren't deleted — only the folder and the albums in it.")
        }
    }

    private func save() {
        AppSettings.galleryLibrary = library
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(get: { selection }, set: { if let value = $0 { selection = value } })) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle.angled").tag(Selection.allPhotos)
                Label("Favorites", systemImage: "star.fill")
                    .tag(Selection.favorites)
                    .badge(library.favoriteImageIDs.count)
            }
            Section("My Albums") {
                ForEach(library.albums(inFolder: nil)) { album in
                    albumRow(album)
                }
                ForEach(library.rootFolders) { folder in
                    DisclosureGroup {
                        ForEach(library.albums(inFolder: folder.id)) { album in
                            albumRow(album)
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .contextMenu {
                                Button("Rename…") { beginRename(folder: folder) }
                                Button("Delete…", role: .destructive) { confirmingDeleteFolder = folder }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if isAutoOrganizing { ProgressView().controlSize(.small) }
                Button {
                    autoOrganize()
                } label: {
                    Label("Auto-Organize", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .help("Creates one album per object name found across your elaborated images' own sessions — replaces only the albums a previous Auto-Organize created, never anything you made by hand.")
                Menu {
                    Button("New Album…") { namePrompt = .newAlbum }
                    Button("New Folder…") { namePrompt = .newFolder }
                } label: {
                    Label("New…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .padding(8)
        }
    }

    @ViewBuilder
    private func albumRow(_ album: GalleryAlbum) -> some View {
        Label(album.name, systemImage: album.isAutoGenerated ? "sparkles" : "rectangle.stack")
            .tag(Selection.album(album.id))
            .contextMenu {
                Button("Rename…") { beginRename(album: album) }
                if !library.folders.isEmpty {
                    Menu("Move to Folder") {
                        if album.parentFolderID != nil {
                            Button("None (Top Level)") { move(album: album, toFolder: nil) }
                        }
                        ForEach(library.rootFolders) { folder in
                            if folder.id != album.parentFolderID {
                                Button(folder.name) { move(album: album, toFolder: folder.id) }
                            }
                        }
                    }
                }
                Button("Delete…", role: .destructive) { confirmingDeleteAlbum = album }
            }
    }

    private func move(album: GalleryAlbum, toFolder folderID: UUID?) {
        guard let index = library.albums.firstIndex(where: { $0.id == album.id }) else { return }
        library.albums[index].parentFolderID = folderID
        save()
    }

    private func beginRename(album: GalleryAlbum) {
        nameText = album.name
        namePrompt = .renameAlbum(album.id)
    }

    private func beginRename(folder: GalleryFolder) {
        nameText = folder.name
        namePrompt = .renameFolder(folder.id)
    }

    // MARK: - Name prompt (new album/folder, rename)

    private func namePromptContent(_ kind: NamePromptKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(namePromptTitle(kind)).font(.headline)
            TextField("Name", text: $nameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .onSubmit { commitNamePrompt(kind) }
            HStack {
                Spacer()
                Button("Cancel") { namePrompt = nil }
                Button("Save") { commitNamePrompt(kind) }
                    .buttonStyle(.borderedProminent)
                    .disabled(nameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func namePromptTitle(_ kind: NamePromptKind) -> String {
        switch kind {
        case .newAlbum, .newAlbumWithImage: return "New Album"
        case .newFolder: return "New Folder"
        case .renameAlbum: return "Rename Album"
        case .renameFolder: return "Rename Folder"
        }
    }

    private func commitNamePrompt(_ kind: NamePromptKind) {
        let trimmed = nameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        switch kind {
        case .newAlbum:
            let album = GalleryAlbum(name: trimmed)
            library.albums.append(album)
            selection = .album(album.id)
        case .newAlbumWithImage(let imageID):
            let album = GalleryAlbum(name: trimmed, imageIDs: [imageID])
            library.albums.append(album)
        case .newFolder:
            library.folders.append(GalleryFolder(name: trimmed))
        case .renameAlbum(let id):
            if let index = library.albums.firstIndex(where: { $0.id == id }) {
                library.albums[index].name = trimmed
                library.albums[index].isAutoGenerated = false
            }
        case .renameFolder(let id):
            if let index = library.folders.firstIndex(where: { $0.id == id }) {
                library.folders[index].name = trimmed
            }
        }
        namePrompt = nil
        save()
    }

    // MARK: - Auto-organize

    /// Groups every elaborated image by its owning session's own planned-object names — an image
    /// whose session planned more than one object lands in more than one album, same as any manual
    /// "add to album" would let it. Images whose source session is missing (deleted since) or has
    /// no planned objects at all are simply left out, not put in some catch-all "Unsorted" album.
    private func autoOrganize() {
        isAutoOrganizing = true
        var groups: [String: [UUID]] = [:]
        for entry in allEntries {
            guard let sessionID = entry.image.sourceSessionIDs.first,
                  let session = entry.project.sessions.first(where: { $0.id == sessionID })
            else { continue }
            for object in session.plannedObjects {
                groups[object, default: []].append(entry.id)
            }
        }
        library.autoOrganize(byObjectName: groups)
        save()
        isAutoOrganizing = false
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            if displayedEntries.isEmpty && favoriteEntries.isEmpty {
                ContentUnavailableView(
                    "No Elaborated Images Yet", systemImage: "photo.on.rectangle.angled",
                    description: Text("Post-process a capture — or send one to Siril, GraXpert, or StarNet — and it shows up here.")
                )
                .padding(.top, 80)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    if selection == .allPhotos {
                        TextField("Search by name…", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    if selection == .allPhotos && !favoriteEntries.isEmpty {
                        PageSection(title: "Favorites") {
                            imageGrid(favoriteEntries)
                        }
                    }
                    if !(selection == .allPhotos && displayedEntries.isEmpty) {
                        imageGrid(displayedEntries)
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func imageGrid(_ entries: [Entry]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 20) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    ElaboratedImageCard(
                        project: entry.project, image: entry.image, cameraManager: cameraManager,
                        siblings: entries.map { (project: $0.project, image: $0.image) },
                        galleryActions: GalleryCardActions(
                            isFavorite: library.favoriteImageIDs.contains(entry.id),
                            canAddFavorite: library.favoriteImageIDs.count < GalleryLibrary.maxFavorites,
                            albums: library.albums,
                            onToggleFavorite: { toggleFavorite(entry.id) },
                            onAddToAlbum: { addImage(entry.id, toAlbum: $0) },
                            onCreateAlbumWithImage: { namePrompt = .newAlbumWithImage(entry.id); nameText = "" }
                        )
                    )
                    Text(entry.project.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func toggleFavorite(_ imageID: UUID) {
        if library.favoriteImageIDs.contains(imageID) {
            library.removeFavorite(imageID)
        } else {
            library.addFavorite(imageID)
        }
        save()
    }

    private func addImage(_ imageID: UUID, toAlbum albumID: UUID) {
        library.addImage(imageID, toAlbum: albumID)
        save()
    }
}

extension GalleryView.NamePromptKind: Identifiable {
    var id: String {
        switch self {
        case .newAlbum: return "newAlbum"
        case .newAlbumWithImage(let id): return "newAlbumWithImage-\(id)"
        case .newFolder: return "newFolder"
        case .renameAlbum(let id): return "renameAlbum-\(id)"
        case .renameFolder(let id): return "renameFolder-\(id)"
        }
    }
}
