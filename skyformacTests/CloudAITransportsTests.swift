import Foundation
import Testing
@testable import skyformac

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
}
