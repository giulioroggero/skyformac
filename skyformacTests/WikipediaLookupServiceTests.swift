import Foundation
import Testing
@testable import skyformac

private final class FakeWikipediaHTTPClient: WikipediaHTTPClient, @unchecked Sendable {
    var statusCode = 200
    var responseData = Data()
    var thrownError: Error?
    private(set) var lastRequestedURL: URL?

    func data(from url: URL) async throws -> (Data, URLResponse) {
        lastRequestedURL = url
        if let thrownError { throw thrownError }
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        return (responseData, response)
    }
}

struct WikipediaLookupServiceTests {
    @Test func summaryDecodesATypicalResponse() async throws {
        let client = FakeWikipediaHTTPClient()
        client.responseData = #"""
        {"title": "Andromeda Galaxy", "extract": "The nearest large spiral galaxy to the Milky Way.",
        "thumbnail": {"source": "https://upload.wikimedia.org/example.jpg", "width": 320, "height": 240},
        "content_urls": {"desktop": {"page": "https://en.wikipedia.org/wiki/Andromeda_Galaxy"}}}
        """#.data(using: .utf8)!

        let summary = try await WikipediaLookupService.summary(for: "Andromeda Galaxy", client: client)
        #expect(summary.title == "Andromeda Galaxy")
        #expect(summary.extract == "The nearest large spiral galaxy to the Milky Way.")
        #expect(summary.thumbnailURL == URL(string: "https://upload.wikimedia.org/example.jpg"))
        #expect(summary.pageURL == URL(string: "https://en.wikipedia.org/wiki/Andromeda_Galaxy"))
    }

    @Test func summaryHandlesAMissingThumbnailAndPageURL() async throws {
        let client = FakeWikipediaHTTPClient()
        client.responseData = #"{"title": "Some Object", "extract": "A short description."}"#.data(using: .utf8)!

        let summary = try await WikipediaLookupService.summary(for: "Some Object", client: client)
        #expect(summary.thumbnailURL == nil)
        #expect(summary.pageURL == nil)
    }

    @Test func summaryThrowsNotFoundOn404() async {
        let client = FakeWikipediaHTTPClient()
        client.statusCode = 404
        client.responseData = Data()

        do {
            _ = try await WikipediaLookupService.summary(for: "Nonexistent Object", client: client)
            Issue.record("expected LookupError.notFound to be thrown")
        } catch WikipediaLookupService.LookupError.notFound {
            // expected
        } catch {
            Issue.record("expected .notFound, got \(error)")
        }
    }

    @Test func summaryThrowsMalformedResponseForUnparsableJSON() async {
        let client = FakeWikipediaHTTPClient()
        client.responseData = "not json at all".data(using: .utf8)!

        do {
            _ = try await WikipediaLookupService.summary(for: "Anything", client: client)
            Issue.record("expected LookupError.malformedResponse to be thrown")
        } catch WikipediaLookupService.LookupError.malformedResponse {
            // expected
        } catch {
            Issue.record("expected .malformedResponse, got \(error)")
        }
    }

    @Test func summaryPercentEncodesTheTitleInTheRequestURL() async throws {
        let client = FakeWikipediaHTTPClient()
        client.responseData = #"{"title": "M 31", "extract": "..."}"#.data(using: .utf8)!

        _ = try await WikipediaLookupService.summary(for: "M 31 / Andromeda", client: client)
        #expect(client.lastRequestedURL?.absoluteString.contains(" ") == false)
    }
}
