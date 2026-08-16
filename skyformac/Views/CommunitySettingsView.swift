import SwiftUI

/// Settings' "Community" tab — live open/resolved issues straight from GitHub, so anyone can see
/// what's actually being worked on and what's already been fixed without leaving the app. Purely
/// a viewer: filing/closing issues still happens on GitHub itself (`GitHubIssuesService
/// .repositoryURL`, opened via "Report an Issue" below).
struct CommunitySettingsView: View {
    @State private var issues: [GitHubIssue] = []
    @State private var loadState: LoadState = .loading
    @State private var showingOnlyOpen = false

    private enum LoadState: Equatable {
        case loading, loaded, failed(String)
    }

    private var openIssues: [GitHubIssue] { issues.filter(\.isOpen) }
    private var closedIssues: [GitHubIssue] { issues.filter { !$0.isOpen } }
    private var visibleIssues: [GitHubIssue] { showingOnlyOpen ? openIssues : issues }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("\(openIssues.count) open", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Label("\(closedIssues.count) resolved", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Spacer()
                Toggle("Open only", isOn: $showingOnlyOpen)
                    .toggleStyle(.checkbox)
                Button("Report an Issue…", systemImage: "arrow.up.forward.app") {
                    NSWorkspace.shared.open(GitHubIssuesService.repositoryURL.appendingPathComponent("issues/new/choose"))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.background.secondary)

            switch loadState {
            case .loading:
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Loading issues from GitHub…")
                }
            case .failed(let message):
                ContentUnavailableView("Couldn't Load Issues", systemImage: "wifi.slash", description: Text(message))
            case .loaded:
                if visibleIssues.isEmpty {
                    ContentUnavailableView("No Open Issues", systemImage: "checkmark.seal")
                } else {
                    List(visibleIssues) { issue in
                        IssueRow(issue: issue)
                    }
                    .listStyle(.inset)
                }
            }

            Text("Skyformac is still in active development — testing against real cameras/mounts, feature proposals, code, and bug reports are all welcome. See the full history at [github.com/giulioroggero/skyformac](\(GitHubIssuesService.repositoryURL.absoluteString)).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding()
        }
        .task { await load() }
    }

    private func load() async {
        loadState = .loading
        do {
            issues = try await GitHubIssuesService.fetchIssues()
            loadState = .loaded
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }
}

private struct IssueRow: View {
    let issue: GitHubIssue

    var body: some View {
        Button {
            NSWorkspace.shared.open(issue.htmlURL)
        } label: {
            HStack {
                Image(systemName: issue.isOpen ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(issue.isOpen ? .orange : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.title)
                        .lineLimit(1)
                    Text(issue.isOpen
                        ? "#\(issue.number) opened \(issue.createdAt.formatted(date: .abbreviated, time: .omitted))"
                        : "#\(issue.number) resolved \((issue.closedAt ?? issue.createdAt).formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
