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
        let images = Self.extractImages(from: request)
        var anthropicRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        anthropicRequest.httpMethod = "POST"
        anthropicRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        anthropicRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        anthropicRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        anthropicRequest.timeoutInterval = 60
        // Anthropic's Messages API wants `content` as an array of typed blocks once an image is
        // attached (image blocks first, then the text) — a bare string only works in the
        // text-only case, which is why this only switches shape when `images` isn't empty.
        let content: Any = images.isEmpty ? prompt : images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0]] as [String: Any]
        } + [["type": "text", "text": prompt]]
        anthropicRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": AppSettings.ollamaMaxResponseTokens,
            "messages": [["role": "user", "content": content]],
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

    /// The same request body's own `"images"` array (see `OllamaPlanner.generate`'s doc comment)
    /// — each already base64-encoded, exactly as Ollama's real vision-model API expects, so both
    /// cloud transports can reuse it verbatim rather than re-encoding. Empty (not thrown) for a
    /// request with no attached image, since an image is always optional here.
    static func extractImages(from request: URLRequest) -> [String] {
        guard let body = request.httpBody,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return [] }
        return json["images"] as? [String] ?? []
    }

    static func wrapAsOllamaResponse(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["response": text, "done": true])
    }
}

/// Resolves where a Gemini request actually goes and how it authenticates — the plain Gemini API
/// (`generativelanguage.googleapis.com`, a simple `?key=` query param) by default, or Vertex AI
/// (`{region}-aiplatform.googleapis.com`, an `Authorization: Bearer` token minted from a service
/// account) when `AppSettings.geminiUsesVertex` is on. Shared by `GeminiTransport` and
/// `GeminiImageEnhancer` since the request *body* (`contents`/`parts`/`generationConfig`) is
/// identical either way — only the URL and auth differ, which is exactly what this factors out.
enum GeminiEndpoint {
    /// Most current Gemini models (2.5+) on Vertex are only served from the "global" location, not
    /// a specific region — pinning a region like `"us-central1"` 404s for exactly those models
    /// even with an otherwise-correct project/model/credentials (confirmed live: switching this
    /// default from `"us-central1"` to `"global"` is what actually fixed a real 404). A specific
    /// region is still a valid, real Vertex location for models that *do* support one (mostly
    /// older/regional-only ones) — a user who genuinely needs that (e.g. data residency) can still
    /// set one explicitly in Settings; this is only the fallback when they haven't.
    static let defaultVertexRegion = "global"

    static func resolve(model: String, apiKey: String) async throws -> (url: URL, authHeader: (name: String, value: String)?) {
        guard AppSettings.geminiUsesVertex else {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")
            else { throw OllamaError.badResponse(message: "Malformed Gemini API URL.") }
            return (url, nil)
        }
        guard let projectID = AppSettings.geminiVertexProjectID, !projectID.isEmpty else {
            throw OllamaError.badResponse(message: "Vertex AI is enabled but no GCP project ID is set in Settings.")
        }
        guard let serviceAccountJSON = AppSettings.geminiVertexServiceAccountJSON, !serviceAccountJSON.isEmpty else {
            throw OllamaError.badResponse(message: "Vertex AI is enabled but no service account key is set in Settings.")
        }
        let region = AppSettings.geminiVertexRegion?.isEmpty == false ? AppSettings.geminiVertexRegion! : defaultVertexRegion
        guard let url = vertexURL(projectID: projectID, region: region, model: model)
        else { throw OllamaError.badResponse(message: "Malformed Vertex AI URL — check the project ID/region in Settings.") }
        do {
            let token = try await VertexServiceAccountAuthenticator.accessToken(serviceAccountJSON: serviceAccountJSON)
            return (url, ("Authorization", "Bearer \(token)"))
        } catch let error as VertexServiceAccountAuthenticator.AuthError {
            let message: String
            switch error {
            case .malformedServiceAccountJSON: message = "The Vertex AI service account key in Settings isn't valid JSON."
            case .invalidPrivateKey: message = "Couldn't read the private key in the Vertex AI service account JSON."
            case .tokenExchangeFailed(let detail): message = detail ?? "Google rejected the Vertex AI service account credentials."
            }
            throw OllamaError.badResponse(message: message)
        }
    }

    /// The "global" location has no region prefix on the host at all —
    /// `global-aiplatform.googleapis.com` doesn't exist; every other location *does* get one, e.g.
    /// `us-central1-aiplatform.googleapis.com`. Pulled out as its own pure function so it's
    /// testable without a real service account/network call the way `resolve` itself needs.
    static func vertexURL(projectID: String, region: String, model: String) -> URL? {
        let host = region == "global" ? "aiplatform.googleapis.com" : "\(region)-aiplatform.googleapis.com"
        return URL(string: "https://\(host)/v1/projects/\(projectID)/locations/\(region)/publishers/google/models/\(model):generateContent")
    }
}

/// Same shape as `AnthropicTransport`, for Google's Gemini API — see that type's own doc comment
/// for the full "why route through `OllamaTransport` instead of a parallel planner" reasoning.
struct GeminiTransport: OllamaTransport {
    var apiKey: String
    var model: String = "gemini-2.5-flash"

    func send(_ request: URLRequest) async throws -> Data {
        let prompt = try AnthropicTransport.extractPrompt(from: request)
        let images = AnthropicTransport.extractImages(from: request)
        let (url, authHeader) = try await GeminiEndpoint.resolve(model: model, apiKey: apiKey)
        var geminiRequest = URLRequest(url: url)
        geminiRequest.httpMethod = "POST"
        geminiRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authHeader { geminiRequest.setValue(authHeader.value, forHTTPHeaderField: authHeader.name) }
        geminiRequest.timeoutInterval = 60
        // Gemini expects an `inlineData` part per attached image, ahead of the text part — same
        // "image(s) first, then text" ordering `AnthropicTransport.send` above uses.
        let imageParts: [[String: Any]] = images.map { ["inlineData": ["mimeType": "image/jpeg", "data": $0]] }
        geminiRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": imageParts + [["text": prompt]]]],
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

/// True pixel-level image editing via Gemini's own image-generation model ("Nano Banana") — unlike
/// `GeminiTransport` above (routed through `OllamaPlanner`'s text-only envelope, used for
/// "suggest slider values" chat), this calls Gemini's image-output endpoint directly and gets a
/// genuinely re-rendered image back. Neither Ollama's plain-text `/api/generate` protocol nor
/// Anthropic's Messages API (no image-generation capability at all, as of this writing) can express
/// that, which is why `SingleImagePostProcessingView`'s "AI Enhance" button is Gemini-only — see
/// its own doc comment for why the result gets a visible watermark once applied.
enum GeminiImageEnhancer {
    enum EnhanceError: Error {
        /// The request succeeded, but Gemini's reply had no image part at all — e.g. it declined
        /// and only replied with text explaining why, or the chosen model doesn't actually support
        /// image output.
        case noImageInResponse
    }

    static func enhance(image: Data, apiKey: String, model: String, instructions: String) async throws -> Data {
        let (url, authHeader) = try await GeminiEndpoint.resolve(model: model, apiKey: apiKey)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authHeader { request.setValue(authHeader.value, forHTTPHeaderField: authHeader.name) }
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [
                ["inlineData": ["mimeType": "image/jpeg", "data": image.base64EncodedString()]],
                ["text": instructions],
            ]]],
            "generationConfig": ["responseModalities": ["IMAGE"]],
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
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
              let inlineData = parts.compactMap({ $0["inlineData"] as? [String: Any] }).first,
              let base64 = inlineData["data"] as? String,
              let outputData = Data(base64Encoded: base64)
        else { throw EnhanceError.noImageInResponse }
        return outputData
    }
}
