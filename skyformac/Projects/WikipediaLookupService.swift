import Foundation

/// A description/thumbnail lookup against Wikipedia's own public REST "page summary" endpoint —
/// no API key, no auth, a single GET per object. The one place this app makes a live network
/// request at all (see `AppSettings.isOnlineObjectInfoEnabled`'s own doc comment); every call site
/// must check that flag before calling this.
/// The narrow slice of `URLSession` this service actually needs — lets tests substitute a fake
/// that returns canned responses instead of making a real network call. `URLSession` itself
/// already satisfies this for real use.
protocol WikipediaHTTPClient: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: WikipediaHTTPClient {}

enum WikipediaLookupService {
    struct Summary: Sendable {
        var title: String
        var extract: String
        var thumbnailURL: URL?
        var pageURL: URL?
    }

    enum LookupError: Error {
        case notFound
        case network(Error)
        case malformedResponse
    }

    /// `title` should be a real, disambiguating page title — "M31" alone is far more likely to
    /// resolve correctly as "Andromeda Galaxy" or similar than a bare catalog ID would on its own,
    /// so callers pass the object's own display name (already whatever's most recognizable —
    /// "Andromeda Galaxy" rather than "M31" when a common name exists).
    static func summary(for title: String, client: WikipediaHTTPClient = URLSession.shared) async throws -> Summary {
        guard let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encodedTitle)")
        else { throw LookupError.malformedResponse }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await client.data(from: url)
        } catch {
            throw LookupError.network(error)
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw LookupError.malformedResponse }
        guard httpResponse.statusCode != 404 else { throw LookupError.notFound }
        guard (200...299).contains(httpResponse.statusCode) else { throw LookupError.malformedResponse }

        guard let decoded = try? JSONDecoder().decode(SummaryResponse.self, from: data) else {
            throw LookupError.malformedResponse
        }
        return Summary(
            title: decoded.title, extract: decoded.extract,
            thumbnailURL: decoded.thumbnail.flatMap { URL(string: $0.source) },
            pageURL: decoded.content_urls?.desktop.flatMap { URL(string: $0.page) }
        )
    }

    private struct SummaryResponse: Decodable {
        var title: String
        var extract: String
        var thumbnail: Thumbnail?
        var content_urls: ContentURLs?

        struct Thumbnail: Decodable { var source: String }
        struct ContentURLs: Decodable { var desktop: Desktop? }
        struct Desktop: Decodable { var page: String }
    }
}
