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
    var onNewProject: () -> Void
    var onQuickStart: () -> Void
    var onShowEquipment: () -> Void
    var onShowInsights: () -> Void
    var onShowSettings: () -> Void

    /// Starts out as `insights.suggestedNextObjects` (the catalog-based fallback, available
    /// immediately/synchronously) and is replaced by `CameraManager.fetchSuggestedNextObjects`'s
    /// AI-generated list once that resolves, if Ollama's actually available — "ideas for next
    /// time must be calculated by AI … if not present ollama fall back to the list of the
    /// wizard." Never shows an empty state while the AI call is in flight.
    @State private var ideas: [String] = []

    /// "Add the skill for the AI that suggests project sessions" — a whole session proposal
    /// (name, goal, objects, target project), computed via `CameraManager.fetchSuggestedNextSession()`.
    /// Unlike `ideas`, there's no synchronous fallback to show first: a full session plan has no
    /// wizard-list equivalent, so the card simply doesn't appear until (if) Ollama actually answers.
    @State private var suggestedSession: OllamaPlanner.SuggestedSessionPlan?

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
    /// the same session doesn't appear twice on one page.
    private var highlightedSessions: [(project: Project, session: Session)] {
        var entries: [(project: Project, session: Session, date: Date)] = []
        for project in projects {
            for session in project.sessions where !session.isArchived {
                guard let date = session.lastCaptureDate, session.id != lastActive?.session.id else { continue }
                entries.append((project, session, date))
            }
        }
        return entries.sorted { $0.date > $1.date }.prefix(5).map { ($0.project, $0.session) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let lastActive {
                    PageSection(title: "Resume Where You Left Off") {
                        HStack {
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
                    }
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
                        }
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

                if !insights.suggestedNextObjects.isEmpty {
                    PageSection(title: "Ideas for Next Time") {
                        ForEach(ideas.prefix(3), id: \.self) { object in
                            HStack {
                                Text(object)
                                Spacer()
                                Button("Quick Start…") { cameraManager.quickStart(forObjectName: object) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Home")
        .task(id: insights.suggestedNextObjects) {
            ideas = insights.suggestedNextObjects
            ideas = await cameraManager.fetchSuggestedNextObjects(fallback: insights.suggestedNextObjects)
        }
        .task {
            suggestedSession = await cameraManager.fetchSuggestedNextSession()
        }
        .toolbar {
            ToolbarItem {
                Button("Settings…", systemImage: "gearshape", action: onShowSettings)
                    .accessibilityIdentifier("DashboardSettingsToolbarButton")
            }
        }
        .frame(minWidth: 820, minHeight: 600)
    }

    @ViewBuilder
    private func summaryStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body)
        }
    }
}
