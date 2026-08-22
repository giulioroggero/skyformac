import SwiftUI
import Charts

/// The app's actual root page — orientation, not browsing: resume where you left off, jump to a
/// common task, see recent projects/sessions, and a quick read on overall activity, all without
/// drilling into the Projects list first. That list (every project — what used to be "Home")
/// moves one level down as its own subpage, matching the hierarchy this now sits above: **Home**
/// (this page) → **Projects** (every project) → **Project Detail** → **Session** (history/
/// timeline, or the live camera session once running).
struct DashboardHomeView: View {
    var cameraManager: CameraManager
    let projects: [Project]
    let insights: InsightsData
    var onOpenProjects: () -> Void
    var onSelectProject: (Project) -> Void
    var onOpenSession: (Project, Session) -> Void
    /// Jumps straight to one specific capture, surfaced by tapping a thumbnail in the Observation
    /// Timeline — mixed across sessions/projects there, so (unlike `onOpenSession`) it needs to
    /// carry the specific session and project each tapped capture actually belongs to.
    var onOpenCapture: (Project, Session, CaptureRecord) -> Void
    var onNewProject: () -> Void
    var onQuickStart: () -> Void
    var onShowEquipment: () -> Void
    var onShowInsights: () -> Void
    var onShowSettings: () -> Void

    /// "Add the skill for the AI that suggests project sessions" — a whole session proposal
    /// (name, goal, objects, target project), computed via `CameraManager.fetchSuggestedNextSession()`.
    /// There's no synchronous fallback to show first: a full session plan has no catalog-list
    /// equivalent, so the card simply doesn't appear until (if) Ollama actually answers.
    @State private var suggestedSession: OllamaPlanner.SuggestedSessionPlan?

    /// Home's own search — `.searchable` below puts the field in the window's toolbar; typing
    /// anything replaces the rest of the page with `searchResultsSection` rather than filtering
    /// the sections in place, since most of Home (Resume/Common Tasks/Timeline) has nothing to
    /// filter *by* text in the first place. Reuses `ProjectSearch` — the same name/goal/tags/
    /// objects/notes substring match the Projects browser's own search already uses — rather
    /// than a second, narrower search implementation.
    @State private var searchText = ""

    private var searchResults: [ProjectSearch.Result] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return ProjectSearch.search(projects, text: searchText)
    }

    /// The single most recently active session across every project — what "resume the last
    /// session" actually resumes. Falls back to `nil` (the card just doesn't show) when nothing's
    /// ever been captured anywhere, rather than picking an arbitrary "most recent" with nothing
    /// real to resume.
    private var lastActive: (project: Project, session: Session)? {
        var best: (project: Project, session: Session)?
        var bestDate = Date.distantPast
        for project in projects {
            for session in project.sessions where !session.isArchived {
                guard let date = session.lastCaptureDate, date > bestDate else { continue }
                bestDate = date
                best = (project, session)
            }
        }
        return best
    }

    /// The next handful of most-recently-touched projects — "last projects," not every project
    /// (that's what Projects is for).
    private var recentProjects: [Project] {
        Array(projects.sorted { $0.lastActivityDate > $1.lastActivityDate }.prefix(6))
    }

    /// The next handful of most-recently-touched sessions across every project — "highlighted
    /// sessions" — excluding whichever one is already shown as "Resume Last Session" above, so
    /// the same session doesn't appear twice on one page. Takes that exclusion explicitly rather
    /// than reading `lastActive` itself: `lastActive` re-scans every project's every session, so
    /// calling it once per session considered here (as this used to) turned an O(P·S) scan into an
    /// effectively O((P·S)²) one — `body` now computes `lastActive` exactly once and passes it in.
    private func highlightedSessions(excludingSessionID: Session.ID?) -> [(project: Project, session: Session)] {
        var entries: [(project: Project, session: Session, date: Date)] = []
        for project in projects {
            for session in project.sessions where !session.isArchived {
                guard let date = session.lastCaptureDate, session.id != excludingSessionID else { continue }
                entries.append((project, session, date))
            }
        }
        return entries.sorted { $0.date > $1.date }.prefix(5).map { ($0.project, $0.session) }
    }

    var body: some View {
        // Computed once per render rather than read as computed properties from several places
        // below (each of which used to redo its own full project/session scan).
        let lastActive = self.lastActive
        let highlightedSessions = highlightedSessions(excludingSessionID: lastActive?.session.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    searchResultsSection
                } else {
                homeContent(lastActive: lastActive, highlightedSessions: highlightedSessions)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .searchable(text: $searchText, prompt: "Search projects, sessions, objects…")
        .navigationTitle("Home")
        .task {
            suggestedSession = await cameraManager.fetchSuggestedNextSession()
        }
        .toolbar {
            OpenAssistantToolbarItem(cameraManager: cameraManager)
            ToolbarItem {
                Button("Settings…", systemImage: "gearshape", action: onShowSettings)
                    .accessibilityIdentifier("DashboardSettingsToolbarButton")
            }
        }
        // See `ProjectsBrowserView`'s own matching `.frame(minWidth: 600, ...)` doc comment —
        // this one (applied to the Dashboard, the NavigationStack's own root content) contributes
        // to the same overall window-width floor and needed the identical fix, or the window
        // would still be forced past a 1024pt-wide screen regardless of the other one changing.
        .frame(minWidth: 600, minHeight: 600)
    }

    /// Everything Home shows when the user isn't searching — split out of `body` so the search-
    /// vs-normal branching above stays readable. `lastActive`/`highlightedSessions` are computed
    /// once in `body` (see its own doc comment on why) and threaded through rather than
    /// recomputed here.
    @ViewBuilder
    private func homeContent(
        lastActive: (project: Project, session: Session)?,
        highlightedSessions: [(project: Project, session: Session)]
    ) -> some View {
        Group {
                if let lastActive {
                    PageSection(title: "Resume Where You Left Off") {
                        HStack {
                            ResumeThumbnail(
                                project: lastActive.project, session: lastActive.session,
                                store: cameraManager.projectStore
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(lastActive.project.name) — \(lastActive.session.name)").font(.headline)
                                if let date = lastActive.session.lastCaptureDate {
                                    Text("Last activity \(date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Resume", systemImage: "play.fill") {
                                cameraManager.setActive(project: lastActive.project, session: lastActive.session)
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Open") { onOpenSession(lastActive.project, lastActive.session) }
                        }
                    }
                }

                PageSection(title: "Common Tasks") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ActionCard(title: "Quick Start", icon: "bolt.fill", tint: .orange, subtitle: "A planet, the Moon, or a deep-sky object — ready to run", action: onQuickStart)
                                .accessibilityIdentifier("DashboardQuickStartTile")
                            ActionCard(title: "New Project", icon: "plus", tint: .accentColor, action: onNewProject)
                            ActionCard(title: "All Projects", icon: "folder", tint: .blue, subtitle: "Browse everything", action: onOpenProjects)
                                .accessibilityIdentifier("DashboardAllProjectsTile")
                            ActionCard(title: "Equipment", icon: "wrench.and.screwdriver", tint: .gray, subtitle: "Cameras, mounts, and gear", action: onShowEquipment)
                            ActionCard(title: "Insights", icon: "chart.bar", tint: .purple, subtitle: "What you actually do most", action: onShowInsights)
                                .accessibilityIdentifier("DashboardInsightsTile")
                        }
                        // Extra leading inset, deliberately more than `PageSection`'s own 16pt —
                        // this (and "Recent Projects" below) were observed to clip a real ~15-20pt
                        // sliver off the first card's own left edge regardless of scroll position
                        // (confirmed by screenshot: `.defaultScrollAnchor(.leading)` and an explicit
                        // `ScrollViewReader.scrollTo(anchor: .leading)` both left it unchanged, so
                        // this isn't a scroll-offset bug — it reads as an `NSScrollView` content-
                        // inset quirk on macOS). Rather than keep fighting where exactly that clip
                        // boundary sits, padding real content well clear of it tolerates the clip
                        // instead: only blank space ever sits in the clipped zone now.
                        .padding(.leading, 20)
                    }
                    .defaultScrollAnchor(.leading)
                    .accessibilityIdentifier("CommonTasksScrollView")
                }

                PageSection(title: "Observation Timeline") {
                    ObservationTimelineView(
                        projects: projects, cameraManager: cameraManager,
                        onSelect: { project, session, capture in onOpenCapture(project, session, capture) }
                    )
                }

                if !recentProjects.isEmpty {
                    PageSection(title: "Recent Projects") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(recentProjects) { project in
                                    ProjectCard(project: project, isOpen: cameraManager.activeProject?.id == project.id, store: cameraManager.projectStore)
                                        .frame(width: 220)
                                        .contentShape(Rectangle())
                                        .onTapGesture { onSelectProject(project) }
                                }
                            }
                            // See "Common Tasks" above for why this is 20pt of real padding, not
                            // just a scroll-anchor fix.
                            .padding(.leading, 20)
                        }
                        .defaultScrollAnchor(.leading)
                    }
                }

                if !highlightedSessions.isEmpty {
                    PageSection(title: "Highlighted Sessions") {
                        ForEach(highlightedSessions, id: \.session.id) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(entry.project.name) — \(entry.session.name)").font(.body)
                                    Text("\(entry.session.captures.count) captures · last \(entry.session.lastCaptureDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Open") { onOpenSession(entry.project, entry.session) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                if insights.totalCaptures > 0 {
                    PageSection(title: "Activity") {
                        if !insights.monthlyActivity.isEmpty {
                            // Categorical (`label`) x-axis — see `MonthlyActivity.label`'s doc
                            // comment for why a continuous `Date` axis showed misleading gaps.
                            Chart(insights.monthlyActivity) { bucket in
                                BarMark(x: .value("Month", bucket.label), y: .value("Captures", bucket.count))
                            }
                            .frame(height: 140)
                        }
                        HStack(spacing: 24) {
                            if let topObject = insights.byObject.first {
                                summaryStat(label: "Most Captured", value: "\(topObject.name) (\(topObject.count))")
                            }
                            if let topEquipment = insights.byEquipmentSystem.first {
                                summaryStat(label: "Most Used Equipment", value: "\(topEquipment.name) (\(topEquipment.count))")
                            }
                            summaryStat(label: "Total Captures", value: "\(insights.totalCaptures)")
                        }
                        Button("See Full Insights…") { onShowInsights() }
                            .buttonStyle(.borderless)
                    }
                }

                if let suggestedSession {
                    PageSection(title: "Suggested Session") {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(suggestedSession.name) — \(suggestedSession.projectName)").font(.headline)
                                Text(suggestedSession.goal).font(.caption).foregroundStyle(.secondary)
                                if !suggestedSession.plannedObjects.isEmpty {
                                    Text("Objects: \(suggestedSession.plannedObjects.joined(separator: ", "))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                            Button("Dismiss") { self.suggestedSession = nil }
                                .buttonStyle(.borderless)
                            Button("Create") {
                                cameraManager.acceptSuggestedSession(suggestedSession)
                                self.suggestedSession = nil
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
        }
    }

    /// Every matching project/session — tapping a project row opens it, a session row opens
    /// straight to that session (matching `RecentProjects`/`HighlightedSessions`'s own actions
    /// above), each labeled with which project it belongs to so a session result isn't ambiguous.
    @ViewBuilder
    private var searchResultsSection: some View {
        PageSection(title: "Search Results") {
            if searchResults.isEmpty {
                Text("No projects or sessions match \"\(searchText)\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(searchResults) { result in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            if let session = result.session {
                                Text(session.name).font(.body)
                                Text(result.project.name.isEmpty ? "Untitled Project" : result.project.name)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(result.project.name.isEmpty ? "Untitled Project" : result.project.name).font(.body)
                                Text("Project").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Open") {
                            if let session = result.session {
                                onOpenSession(result.project, session)
                            } else {
                                onSelectProject(result.project)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let session = result.session {
                            onOpenSession(result.project, session)
                        } else {
                            onSelectProject(result.project)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body)
        }
    }
}

/// "Resume Where You Left Off"'s own cover image — same `ProjectStore.mostRecentThumbnailURL(for:
/// in:)` every other session cover already uses (`SessionCard` on the Project Detail page), so it
/// automatically follows the same rule everywhere a cover shows: a user-chosen custom thumbnail
/// always wins, and un-setting one falls straight back to the session's own most recent capture
/// with no separate refresh step needed — `mostRecentThumbnailURL` is computed fresh from current
/// state on every call, not cached, so this row picks up either change the next time it renders.
private struct ResumeThumbnail: View {
    let project: Project
    let session: Session
    let store: ProjectStore

    private var thumbnailURL: URL? { store.mostRecentThumbnailURL(for: session, in: project) }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let thumbnailURL, let image = ThumbnailCache.image(at: thumbnailURL) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "calendar").font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 72, height: 72)
        .clipped()
    }
}
