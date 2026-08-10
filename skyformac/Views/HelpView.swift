import SwiftUI

/// In-app Help, presented as a `.sheet` on `ContentView` (via `cameraManager.isHelpPresented`,
/// opened by `SkyformacCommands`' Help menu item, ⌘?) — not its own `Window` scene, since this
/// app is deliberately single-window (see `SkyformacApp`'s doc comment). A plain
/// `NavigationSplitView` over `HelpContent.topics` — deliberately not a web view or a bundled
/// HTML/Markdown file: the content is short enough, and specific enough to this app's actual
/// current feature set, that plain structured Swift data (`HelpSection`) plus real SwiftUI
/// typography is simpler than shipping and rendering a second document format.
///
/// Two entry points into a specific paragraph, not just a topic: `.searchable` full-text search
/// over every topic's content, and `initialTopicID`/`initialSectionID` — set via
/// `CameraManager.showHelp(topicID:sectionID:)`, which every "?" `HelpLinkButton` next to a
/// setting in `ControlsPanelView` calls — so a control's own explanation is one click away
/// instead of a scavenger hunt through the topic list.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTopicID: String?
    @State private var searchText = ""
    @State private var scrollAnchorID: String?

    private let initialSectionID: String?

    init(initialTopicID: String? = nil, initialSectionID: String? = nil) {
        _selectedTopicID = State(initialValue: initialTopicID ?? HelpContent.topics.first?.id)
        self.initialSectionID = initialSectionID
        _scrollAnchorID = State(initialValue: initialSectionID)
    }

    private var searchResults: [HelpSearchResult] { HelpContent.search(searchText) }
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationSplitView {
            sidebarList
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let topic = HelpContent.topics.first(where: { $0.id == selectedTopicID }) {
                // Explicit `.id(topic.id)` forces a fresh `HelpTopicView` (and its `ScrollView`)
                // per topic — without it, switching topics keeps the same underlying `ScrollView`
                // instance with whatever scroll offset the *previous* topic left it at, since only
                // the `ForEach`'s content changes, not the view's own identity.
                HelpTopicView(topic: topic, scrollAnchorID: $scrollAnchorID)
                    .id(topic.id)
            } else {
                ContentUnavailableView("Select a Topic", systemImage: "questionmark.circle")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Help")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            // Jumping straight to a specific setting's explanation (`showHelp(topicID:
            // sectionID:)`) needs both the topic selected *and* the anchor set — `init` already
            // did both, but `HelpTopicView`'s `ScrollViewReader` isn't mounted until the first
            // layout pass, so re-asserting the anchor here (after that pass) is what actually
            // triggers the scroll; setting it only in `init` scrolls to nothing since there's no
            // `ScrollViewReader` yet to catch the `onChange` it would otherwise rely on.
            if let initialSectionID {
                scrollAnchorID = initialSectionID
            }
        }
    }

    @ViewBuilder
    private var sidebarList: some View {
        if isSearching {
            List(searchResults, selection: Binding(
                get: { selectedTopicID },
                set: { newTopicID in
                    guard let result = searchResults.first(where: { $0.topicID == newTopicID || $0.id == newTopicID }) else { return }
                    selectedTopicID = result.topicID
                    // Matches `HelpTopicView`'s own fallback for sections with no explicit
                    // `HelpSection.id` — a search hit still needs to land on the exact matched
                    // paragraph, not just the top of the topic, even when that paragraph never
                    // needed a stable anchor for any other reason.
                    scrollAnchorID = result.sectionAnchorID ?? "section-\(result.sectionIndex)"
                }
            )) { result in
                VStack(alignment: .leading, spacing: 3) {
                    Label(result.displayTitle, systemImage: result.topicIcon)
                        .font(.callout.bold())
                    Text(result.topicTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(result.snippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .tag(result.id)
                .padding(.vertical, 2)
            }
            .overlay {
                if searchResults.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        } else {
            List(HelpContent.topics, selection: Binding(
                get: { selectedTopicID },
                set: { newTopicID in
                    selectedTopicID = newTopicID
                    // Plain topic-list navigation always starts at the top — without clearing
                    // this, revisiting a topic after arriving at it once via search or a
                    // setting's "?" link would keep re-scrolling to that old anchor forever.
                    scrollAnchorID = nil
                }
            )) { topic in
                Label(topic.title, systemImage: topic.icon).tag(topic.id)
            }
        }
    }
}

private struct HelpTopicView: View {
    let topic: HelpTopic
    @Binding var scrollAnchorID: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(topic.title)
                        .font(.largeTitle.bold())
                    ForEach(Array(topic.sections.enumerated()), id: \.offset) { index, section in
                        // Falls back to an index-derived id for sections with no explicit
                        // `HelpSection.id` — every row needs a *distinct* identity for
                        // `ScrollViewProxy.scrollTo` to target correctly; letting several
                        // headerless sections all share a bare `nil` id would make them
                        // indistinguishable to it (and to SwiftUI's own view-identity diffing).
                        HelpSectionView(section: section)
                            .id(section.id ?? "section-\(index)")
                    }
                }
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(topic.title)
            .onAppear { scrollTo(proxy) }
            .onChange(of: scrollAnchorID) { _, _ in scrollTo(proxy) }
        }
    }

    private func scrollTo(_ proxy: ScrollViewProxy) {
        guard let scrollAnchorID else { return }
        // A search hit on a headerless section (no stable `id`) still selects the right topic —
        // it just can't scroll to an exact paragraph, so it falls through to the top, which is
        // still strictly better than leaving the scroll position wherever the previous topic left
        // it.
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(scrollAnchorID, anchor: .top)
        }
    }
}

private struct HelpSectionView: View {
    let section: HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading = section.heading {
                Text(heading)
                    .font(.title3.bold())
                    .padding(.top, 4)
            }
            // Inline `**bold**` markdown (the only markup `HelpContent` uses) renders through
            // `Text`'s own `LocalizedStringKey` markdown support — no need for a real parser for
            // content this constrained. Some sections are heading + bullets only, with no lead-in
            // sentence — `body` defaults to "" for those, so skip rendering an empty line.
            if !section.body.isEmpty {
                Text(.init(section.body))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                    Text(.init(bullet))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

#Preview {
    HelpView()
}
