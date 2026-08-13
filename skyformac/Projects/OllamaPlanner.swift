import Foundation

/// The one HTTP call `OllamaPlanner` needs — narrowed to a protocol (rather than using
/// `URLSession` directly) so tests can supply a fake that returns a canned response instead of
/// requiring a real Ollama server running on the test machine.
protocol OllamaTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Data
}

extension URLSession: OllamaTransport {
    func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaError.badResponse
        }
        return data
    }
}

enum OllamaError: Error, Equatable {
    /// The Ollama server itself returned a non-2xx status, or wasn't reachable at all.
    case badResponse
    /// The server responded, but the model's own text didn't contain the JSON plan asked for —
    /// most likely a smaller/less-capable local model ignoring the "respond with only JSON"
    /// instruction, which no amount of retrying the same prompt reliably fixes.
    case invalidPlanJSON
}

/// Asks a local Ollama server (no cloud dependency — matches this app's "everything runs on the
/// observer's own machine, no accounts, no telemetry" stance) to draft a session or project plan
/// from a one-line goal, the same way a human would sketch "see M13, M57, Saturn" into a proper
/// plan with a name and a concrete target list.
struct OllamaPlanner: Sendable {
    struct SessionPlanSuggestion: Codable, Equatable, Sendable {
        var name: String
        var goal: String
        var plannedObjects: [String]
    }

    struct ProjectPlanSuggestion: Codable, Equatable, Sendable {
        var name: String
        var goal: String
        var sessions: [SessionPlanSuggestion]
    }

    var baseURL: URL
    var model: String
    var transport: OllamaTransport

    init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String = "llama3.2", transport: OllamaTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.model = model
        self.transport = transport
    }

    /// `true` once the server answers at all — used to gray out the "Ask AI to plan this" button
    /// rather than let the user hit it and wait for a timeout when Ollama just isn't running.
    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        return (try? await transport.send(request)) != nil
    }

    func planSession(goal: String, notes: String = "") async throws -> SessionPlanSuggestion {
        let text = try await generate(prompt: Self.sessionPrompt(goal: goal, notes: notes))
        guard let json = Self.extractJSONObject(from: text) else { throw OllamaError.invalidPlanJSON }
        do {
            return try JSONDecoder().decode(SessionPlanSuggestion.self, from: json)
        } catch {
            throw OllamaError.invalidPlanJSON
        }
    }

    func planProject(goal: String, notes: String = "") async throws -> ProjectPlanSuggestion {
        let text = try await generate(prompt: Self.projectPrompt(goal: goal, notes: notes))
        guard let json = Self.extractJSONObject(from: text) else { throw OllamaError.invalidPlanJSON }
        do {
            return try JSONDecoder().decode(ProjectPlanSuggestion.self, from: json)
        } catch {
            throw OllamaError.invalidPlanJSON
        }
    }

    private func generate(prompt: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": false,
        ])
        let data = try await transport.send(request)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = envelope["response"] as? String
        else {
            throw OllamaError.badResponse
        }
        return response
    }

    /// Ollama's own reply is plain text, not guaranteed-valid JSON on its own even when the
    /// prompt asks for "only JSON" — smaller models routinely wrap it in a sentence or a
    /// ` ```json ` fence. Taking the substring between the first `{` and the last `}` recovers
    /// the actual object in every case that matters without needing a real parser to find it.
    private static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }

    private static func sessionPrompt(goal: String, notes: String) -> String {
        """
        You are an assistant helping an amateur astronomer plan a single observing session.
        Goal: \(goal)
        \(notes.isEmpty ? "" : "Notes: \(notes)\n")\
        Respond with ONLY a JSON object, no other text, matching exactly this shape:
        {"name": "short session title", "goal": "one sentence goal", "plannedObjects": ["object1", "object2"]}
        """
    }

    private static func projectPrompt(goal: String, notes: String) -> String {
        """
        You are an assistant helping an amateur astronomer plan a multi-session observing project.
        Goal: \(goal)
        \(notes.isEmpty ? "" : "Notes: \(notes)\n")\
        Respond with ONLY a JSON object, no other text, matching exactly this shape:
        {"name": "short project title", "goal": "one sentence goal", "sessions": [\
        {"name": "short session title", "goal": "one sentence goal", "plannedObjects": ["object1"]}]}
        """
    }
}
