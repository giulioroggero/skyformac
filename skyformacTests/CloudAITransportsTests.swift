import Foundation
import Testing
@testable import skyformac

/// `.serialized` — several tests below mutate real, shared `AppSettings.geminiUsesVertex`/etc.
/// (`UserDefaults`/Keychain-backed, not an isolated test double), so running this suite's tests
/// concurrently (Swift Testing's own default) let one test's settings mutation clobber another's
/// mid-flight — confirmed live as a genuine race, not a real production bug.
@Suite(.serialized)
struct CloudAITransportsTests {
    @Test func extractPromptReadsThePromptFieldFromAnOllamaShapedRequest() throws {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "x", "prompt": "hello world", "stream": true])
        let prompt = try AnthropicTransport.extractPrompt(from: request)
        #expect(prompt == "hello world")
    }

    @Test func extractPromptThrowsForARequestWithNoBody() {
        let request = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        #expect(throws: OllamaError.self) {
            _ = try AnthropicTransport.extractPrompt(from: request)
        }
    }

    @Test func extractPromptThrowsWhenThePromptFieldIsMissing() throws {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "x"])
        #expect(throws: OllamaError.self) {
            _ = try AnthropicTransport.extractPrompt(from: request)
        }
    }

    /// `OllamaPlanner.generate` parses this exact envelope — `wrapAsOllamaResponse` is what lets
    /// every one of `OllamaPlanner`'s own prompt/JSON-extraction methods work completely
    /// unchanged against a cloud provider's plain-text reply.
    @Test func wrapAsOllamaResponseProducesAParsableOllamaShapedEnvelope() throws {
        let data = try AnthropicTransport.wrapAsOllamaResponse("the answer")
        let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(envelope?["response"] as? String == "the answer")
        #expect(envelope?["done"] as? Bool == true)
    }

    @Test func anthropicErrorMessageExtractsTheProvidersOwnErrorText() throws {
        let data = try JSONSerialization.data(withJSONObject: ["error": ["type": "invalid_request_error", "message": "bad key"]])
        let message = AnthropicTransport.errorMessage(from: data, status: 401)
        #expect(message == "bad key")
    }

    @Test func anthropicErrorMessageFallsBackToStatusCodeWhenBodyIsntJSON() {
        let message = AnthropicTransport.errorMessage(from: Data("not json".utf8), status: 500)
        #expect(message == "HTTP 500")
    }

    @Test func extractImagesReadsTheImagesFieldFromAnOllamaShapedRequest() throws {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "x", "prompt": "describe this", "images": ["aGVsbG8=", "d29ybGQ="],
        ])
        #expect(AnthropicTransport.extractImages(from: request) == ["aGVsbG8=", "d29ybGQ="])
    }

    @Test func extractImagesReturnsEmptyWhenNoImagesFieldIsPresent() throws {
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": "x", "prompt": "hello"])
        #expect(AnthropicTransport.extractImages(from: request).isEmpty)
    }

    @Test func extractImagesReturnsEmptyForARequestWithNoBody() {
        let request = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        #expect(AnthropicTransport.extractImages(from: request).isEmpty)
    }

    /// `AppSettings.geminiUsesVertex` is real `UserDefaults` — reset it (and the other Vertex
    /// settings this touches) around every test here so none of them leak into each other or into
    /// whatever this machine's real app usage has actually configured.
    private func withCleanGeminiVertexSettings(_ body: () async throws -> Void) async rethrows {
        let originalUsesVertex = AppSettings.geminiUsesVertex
        let originalProjectID = AppSettings.geminiVertexProjectID
        let originalRegion = AppSettings.geminiVertexRegion
        let originalServiceAccountJSON = AppSettings.geminiVertexServiceAccountJSON
        defer {
            AppSettings.geminiUsesVertex = originalUsesVertex
            AppSettings.geminiVertexProjectID = originalProjectID
            AppSettings.geminiVertexRegion = originalRegion
            AppSettings.geminiVertexServiceAccountJSON = originalServiceAccountJSON
        }
        try await body()
    }

    @Test func vertexURLUsesTheUnprefixedGlobalHostForTheGlobalLocation() {
        let url = GeminiEndpoint.vertexURL(projectID: "my-project", region: "global", model: "gemini-2.5-flash")
        #expect(url?.absoluteString == "https://aiplatform.googleapis.com/v1/projects/my-project/locations/global/publishers/google/models/gemini-2.5-flash:generateContent")
    }

    /// Most current Gemini models on Vertex only serve from "global" — a specific region is still
    /// a real, valid Vertex location for models that support one, just not this app's own default
    /// (see `GeminiEndpoint.defaultVertexRegion`'s own doc comment for why).
    @Test func vertexURLPrefixesTheHostForASpecificRegion() {
        let url = GeminiEndpoint.vertexURL(projectID: "my-project", region: "us-central1", model: "gemini-2.5-flash")
        #expect(url?.absoluteString == "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1/publishers/google/models/gemini-2.5-flash:generateContent")
    }

    @Test func geminiEndpointResolvesThePlainAPIURLWhenVertexIsOff() async throws {
        try await withCleanGeminiVertexSettings {
            AppSettings.geminiUsesVertex = false
            let (url, authHeader) = try await GeminiEndpoint.resolve(model: "gemini-2.5-flash", apiKey: "test-key")
            #expect(url.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=test-key")
            #expect(authHeader == nil)
        }
    }

    @Test func geminiEndpointThrowsWithoutAProjectIDWhenVertexIsOn() async throws {
        try await withCleanGeminiVertexSettings {
            AppSettings.geminiUsesVertex = true
            AppSettings.geminiVertexProjectID = nil
            await #expect(throws: OllamaError.self) {
                _ = try await GeminiEndpoint.resolve(model: "gemini-2.5-flash", apiKey: "")
            }
        }
    }

    @Test func geminiEndpointThrowsWithoutAServiceAccountWhenVertexIsOn() async throws {
        try await withCleanGeminiVertexSettings {
            AppSettings.geminiUsesVertex = true
            AppSettings.geminiVertexProjectID = "my-project"
            AppSettings.geminiVertexServiceAccountJSON = nil
            await #expect(throws: OllamaError.self) {
                _ = try await GeminiEndpoint.resolve(model: "gemini-2.5-flash", apiKey: "")
            }
        }
    }

    @Test func geminiEndpointThrowsForMalformedServiceAccountJSONWhenVertexIsOn() async throws {
        try await withCleanGeminiVertexSettings {
            AppSettings.geminiUsesVertex = true
            AppSettings.geminiVertexProjectID = "my-project"
            AppSettings.geminiVertexServiceAccountJSON = "not valid json"
            await #expect(throws: OllamaError.self) {
                _ = try await GeminiEndpoint.resolve(model: "gemini-2.5-flash", apiKey: "")
            }
        }
    }
}
