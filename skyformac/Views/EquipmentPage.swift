import SwiftUI

/// The Equipment page — every named `EquipmentSystem` the user has set up ("Backyard Rig,"
/// "Travel Setup"), reachable from the Home page toolbar. Tapping one pushes its own editor
/// (`EquipmentSystemEditorPage`); "+" creates a new, empty, immediately-named system.
struct EquipmentPage: View {
    var library: EquipmentLibrary
    var onSelect: (EquipmentSystem) -> Void

    @State private var isCreatingSystem = false

    var body: some View {
        List {
            ForEach(library.systems) { system in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(system.name).font(.headline)
                        Text(system.items.isEmpty ? "No items yet" : system.items.map(\.displayName).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { onSelect(system) }
                .contextMenu {
                    Button("Delete", role: .destructive) { library.delete(system) }
                }
            }
        }
        .overlay {
            if library.systems.isEmpty {
                ContentUnavailableView(
                    "No Equipment Systems Yet", systemImage: "wrench.and.screwdriver",
                    description: Text("Create one to associate a camera, mount, optical tube, and any other gear with your projects and sessions.")
                )
            }
        }
        .navigationTitle("Equipment")
        .toolbar {
            ToolbarItem {
                Button("New System…", systemImage: "plus") { isCreatingSystem = true }
            }
        }
        .sheet(isPresented: $isCreatingSystem) {
            NewEquipmentSystemSheet(library: library) { system in onSelect(system) }
        }
    }
}

private struct NewEquipmentSystemSheet: View {
    var library: EquipmentLibrary
    var onCreate: (EquipmentSystem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Equipment System").font(.headline)
            TextField("Name", text: $name, prompt: Text("e.g. Backyard Rig")).onSubmit(create)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding()
        .frame(width: 320, height: 140)
    }

    private func create() {
        guard !trimmedName.isEmpty else { return }
        let system = library.createSystem(name: trimmedName)
        onCreate(system)
        dismiss()
    }
}

/// One equipment system's own editor — rename it, and add/remove items per category. The three
/// "core" categories (camera, mount, optical tube) always show, even empty, since every real
/// setup has them; every other category only appears once it actually has an item.
struct EquipmentSystemEditorPage: View {
    let system: EquipmentSystem
    var library: EquipmentLibrary
    var onBack: () -> Void

    @State private var name: String
    @State private var addingCategory: EquipmentCategory?

    init(system: EquipmentSystem, library: EquipmentLibrary, onBack: @escaping () -> Void) {
        self.system = system
        self.library = library
        self.onBack = onBack
        self._name = State(initialValue: system.name)
    }

    private var visibleCategories: [EquipmentCategory] {
        EquipmentCategory.allCases.filter { $0.isCore || !system.items(in: $0).isEmpty }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageSection(title: "System") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, newValue in
                            var updated = system
                            updated.name = newValue
                            library.save(updated)
                        }
                }

                ForEach(visibleCategories) { category in
                    PageSection {
                        HStack {
                            Label(category.displayName, systemImage: category.icon).font(.headline)
                            Spacer()
                            Button("Add", systemImage: "plus") { addingCategory = category }
                                .buttonStyle(.borderless)
                        }
                        ForEach(system.items(in: category)) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.displayName)
                                    if !item.notes.isEmpty {
                                        Text(item.notes).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) { remove(item) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if system.items(in: category).isEmpty {
                            Text("None added yet").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(system.name.isEmpty ? "Equipment System" : system.name)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: onBack)
            }
        }
        .sheet(item: $addingCategory) { category in
            AddEquipmentItemSheet(category: category) { item in
                var updated = system
                updated.items.append(item)
                library.save(updated)
            }
        }
    }

    private func remove(_ item: EquipmentItem) {
        var updated = system
        updated.items.removeAll { $0.id == item.id }
        library.save(updated)
    }
}

/// Picking an item to add — either one of `EquipmentCatalog`'s curated entries for this category,
/// or "Add Custom" for anything not listed.
private struct AddEquipmentItemSheet: View {
    let category: EquipmentCategory
    var onAdd: (EquipmentItem) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var isAddingCustom = false
    @State private var customBrand = ""
    @State private var customModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Add \(category.displayName)").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding()

            if isAddingCustom {
                VStack(alignment: .leading, spacing: 12) {
                    TextField("Brand", text: $customBrand, prompt: Text("e.g. Celestron"))
                    TextField("Model", text: $customModel, prompt: Text("e.g. NexStar 6SE"))
                    Spacer()
                    HStack {
                        Button("Back") { isAddingCustom = false }
                        Spacer()
                        Button("Add") {
                            onAdd(.custom(category: category, brand: customBrand, model: customModel))
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(customBrand.trimmingCharacters(in: .whitespaces).isEmpty
                            && customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding()
            } else {
                List {
                    Button("Add Custom…", systemImage: "plus.circle") { isAddingCustom = true }
                    ForEach(EquipmentCatalog.items(for: category)) { catalogItem in
                        Button(catalogItem.displayName) {
                            onAdd(.fromCatalog(catalogItem))
                            dismiss()
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 420)
    }
}
