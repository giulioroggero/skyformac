import Foundation

/// One issue as GitHub's REST API returns it — a small subset of the real response, just enough
/// to show "what's open, what's been fixed" without pulling in a whole GitHub API client
/// dependency for a single read-only, unauthenticated list.
struct GitHubIssue: Codable, Identifiable, Sendable {
    var id: Int { number }
    let number: Int
    let title: String
    let state: String
    let htmlURL: URL
    let createdAt: Date
    let closedAt: Date?
    /// GitHub's `/issues` endpoint returns pull requests too — present only on those, so its mere
    /// presence (not its content) is what `GitHubIssuesService` filters on to keep this a list of
    /// actual issues, not merged PRs.
    let pullRequest: PullRequestMarker?

    struct PullRequestMarker: Codable, Sendable {}

    enum CodingKeys: String, CodingKey {
        case number, title, state
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case closedAt = "closed_at"
        case pullRequest = "pull_request"
    }

    var isOpen: Bool { state == "open" }
}

/// Fetches this project's own GitHub issues — "provide evidence to the users and allow people to
/// understand the evolution of the application," per the Settings > Community tab this backs.
/// Read-only, unauthenticated (GitHub's REST API allows this for public repos, at a lower rate
/// limit than an authenticated request — plenty for one person occasionally opening Settings).
enum GitHubIssuesService {
    static let repositoryURL = URL(string: "https://github.com/giulioroggero/skyformac")!

    private static let apiURL = URL(string: "https://api.github.com/repos/giulioroggero/skyformac/issues?state=all&per_page=100")!

    enum ServiceError: Error, LocalizedError {
        case network(Error)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .network(let error): return "Couldn't reach GitHub: \(error.localizedDescription)"
            case .badResponse: return "GitHub returned an unexpected response."
            }
        }
    }

    /// Every real issue (pull requests filtered out), newest first — exactly the order GitHub's
    /// own API already returns them in by default, so no extra sort is needed.
    static func fetchIssues() async throws -> [GitHubIssue] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        decoder.dateDecodingStrategy = .iso8601
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: apiURL)
        } catch {
            throw ServiceError.network(error)
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ServiceError.badResponse
        }
        let issues = try decoder.decode([GitHubIssue].self, from: data)
        return issues.filter { $0.pullRequest == nil }
    }
}
