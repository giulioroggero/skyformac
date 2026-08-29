import Foundation

/// Routes an `OllamaPlanner`-shaped request to Anthropic's Messages API instead — every one of
/// `OllamaPlanner`'s own methods (`planSession`, `respond`, `summarize`, etc.) already funnels
/// through its private `generate(prompt:onPartialResponse:)`, which just POSTs a `{"prompt":
/// ...}` JSON body through its `transport: OllamaTransport` and expects an Ollama-shaped
/// `{"response": "...", "done": true}` reply back — a real prompt-and-reply round trip, not
/// anything actually Ollama-specific about the *shape* of that exchange. Implementing
/// `OllamaTransport` here, reading the `prompt` back out of the request `OllamaPlanner` built and
/// translating the result back into that same envelope, means every one of its prompt templates
/// and JSON-extraction helpers works completely unchanged against a cloud provider — no
/// duplicated prompt logic, no parallel `AnthropicPlanner` type to keep in sync.
///
/// This is a deliberate architectural choice over `litellm` (a Python library) for a native
/// Swift/SwiftUI app with no other Python runtime dependency anywhere else — see `SBOM.md` for
/// the full reasoning. Each cloud provider here is a small, dependency-free `URLSession` call.
struct AnthropicTransport: OllamaTransport {
    var apiKey: String
    var model: String = "claude-sonnet-5"

    func send(_ request: URLRequest) async throws -> Data {
        let prompt = try Self.extractPrompt(from: request)
        var anthropicRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        anthropicRequest.httpMethod = "POST"
        anthropicRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        anthropicRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        anthropicRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        anthropicRequest.timeoutInterval = 60
        anthropicRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": AppSettings.ollamaMaxResponseTokens,
            "messages": [["role": "user", "content": prompt]],
        ])

        let (data, response) = try await URLSession.shared.data(for: anthropicRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaError.badResponse(message: Self.errorMessage(from: data, status: (response as? HTTPURLResponse)?.statusCode))
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = envelope["content"] as? [[String: Any]],
              let text = content.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
        else { throw OllamaError.badResponse(message: nil) }
        return try Self.wrapAsOllamaResponse(text)
    }

    /// Anthropic's own error envelope: `{"error": {"type": "...", "message": "..."}}`.
    static func errorMessage(from data: Data, status: Int?) -> String? {
        let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = (envelope?["error"] as? [String: Any])?["message"] as? String
        return message ?? status.map { "HTTP \($0)" }
    }

    /// Both cloud transports need the exact same two glue steps — reading the prompt back out of
    /// whatever request `OllamaPlanner.generate` built, and wrapping a plain-text reply back into
    /// its own expected single-line NDJSON shape — factored out so `GeminiTransport` doesn't
    /// duplicate them.
    static func extractPrompt(from request: URLRequest) throws -> String {
        guard let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let prompt = json["prompt"] as? String
        else { throw OllamaError.badResponse(message: "Malformed request") }
        return prompt
    }

    static func wrapAsOllamaResponse(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["response": text, "done": true])
    }
}

/// Same shape as `AnthropicTransport`, for Google's Gemini API — see that type's own doc comment
/// for the full "why route through `OllamaTransport` instead of a parallel planner" reasoning.
struct GeminiTransport: OllamaTransport {
    var apiKey: String
    var model: String = "gemini-3.0-flash"

    func send(_ request: URLRequest) async throws -> Data {
        let prompt = try AnthropicTransport.extractPrompt(from: request)
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var geminiRequest = URLRequest(url: url)
        geminiRequest.httpMethod = "POST"
        geminiRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        geminiRequest.timeoutInterval = 60
        geminiRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": ["maxOutputTokens": AppSettings.ollamaMaxResponseTokens],
        ])

        let (data, response) = try await URLSession.shared.data(for: geminiRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (envelope?["error"] as? [String: Any])?["message"] as? String
            let status = (response as? HTTPURLResponse)?.statusCode
            throw OllamaError.badResponse(message: message ?? status.map { "HTTP \($0)" })
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = envelope["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String
        else { throw OllamaError.badResponse(message: nil) }
        return try AnthropicTransport.wrapAsOllamaResponse(text)
    }
}
