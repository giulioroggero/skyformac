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
            // Ollama's own error responses are JSON with a plain "error" string (e.g. `{"error":
            // "model 'llama3.2' not found"}` for a model that was never pulled) — surfacing that
            // verbatim is the difference between a user seeing exactly what's wrong and just
            // "couldn't reach Ollama" for a server that answered just fine.
            let serverMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            let status = (response as? HTTPURLResponse)?.statusCode
            throw OllamaError.badResponse(message: serverMessage ?? status.map { "HTTP \($0)" })
        }
        return data
    }
}

enum OllamaError: Error, Equatable {
    /// The Ollama server itself returned a non-2xx status, or wasn't reachable at all —
    /// `message` is the server's own explanation when it gave one (see `URLSession.send`).
    case badResponse(message: String?)
    /// The server responded, but the model's own text didn't contain the JSON plan asked for —
    /// most likely a smaller/less-capable local model ignoring the "respond with only JSON"
    /// instruction, which no amount of retrying the same prompt reliably fixes.
    case invalidPlanJSON
    /// `model` was left `nil` (auto-detect) but the server reports zero installed models — there
    /// is nothing to fall back to; the user needs to `ollama pull` something first.
    case noModelsInstalled
    /// `summarize(context:)`'s reply was blank after stripping any `<think>` preamble — the model
    /// "answered" with nothing usable. Kept distinct from `invalidPlanJSON` since that case is
    /// specifically about JSON shape, which a plain-text summary was never expected to have.
    case emptySummary

    /// What `AIPlanSheets` actually shows — a plain sentence rather than `String(describing:)`'s
    /// `badResponse(message: Optional("..."))`-shaped debug dump.
    var userFacingMessage: String {
        switch self {
        case .badResponse(let message): message ?? "Couldn't reach the Ollama server."
        case .invalidPlanJSON: "The model's reply didn't contain a usable plan — try again, or try a different model."
        case .noModelsInstalled: "No models are installed. Run `ollama pull <model>` first."
        case .emptySummary: "The model didn't return any text — try again, or try a different model."
        }
    }
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

    /// What `planProject` actually returns — either the plan itself, or (new) a single clarifying
    /// question the model asked for first. Modeled as two cases rather than an optional question
    /// alongside an optional plan, so a caller can't end up with — or have to guard against —
    /// both or neither being present at once.
    enum ProjectPlanResponse: Equatable, Sendable {
        case plan(ProjectPlanSuggestion)
        case needsMoreInfo(question: String)
    }

    /// The probe type `planProject` decodes first to tell the two response shapes apart —
    /// `needsMoreInfo`/`question` are the only fields it cares about; a full plan response simply
    /// doesn't have a top-level `needsMoreInfo` key, so `raw.needsMoreInfo == true` never matches
    /// one, letting the same decode attempt safely fall through to `ProjectPlanSuggestion` below.
    private struct NeedsMoreInfoProbe: Codable {
        var needsMoreInfo: Bool?
        var question: String?
    }

    var baseURL: URL
    /// `nil` (the default) means "ask the server which models are actually installed and use the
    /// first one" — a specific hardcoded model name reliably 404s on any machine that hasn't
    /// pulled that exact model, which is most of them; every real Ollama install already has at
    /// least one model the user actually chose themselves. Set this explicitly to pin a
    /// particular model instead.
    var model: String?
    var transport: OllamaTransport

    init(baseURL: URL = URL(string: "http://localhost:11434")!, model: String? = nil, transport: OllamaTransport = URLSession.shared) {
        self.baseURL = baseURL
        self.model = model
        self.transport = transport
    }

    /// `true` once the server answers at all — used to gray out the "Ask AI to plan this" button
    /// rather than let the user hit it and wait for a timeout when Ollama just isn't running.
    /// Reachable-but-empty (zero models installed) still counts as "available" here; that's
    /// `planSession`/`planProject`'s `noModelsInstalled` to report once actually asked for a plan.
    func isAvailable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        return (try? await transport.send(request)) != nil
    }

    /// Every model name the server currently reports as installed (`ollama list`, over HTTP) —
    /// exposed mainly so a future model picker doesn't have to re-derive this, though
    /// `resolveModel()` is what actually uses it today.
    func installedModels() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"
        let data = try await transport.send(request)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = envelope["models"] as? [[String: Any]]
        else {
            return []
        }
        return models.compactMap { $0["name"] as? String }
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

    /// Plans a whole multi-session project from one goal — e.g. "the nicest Messier objects
    /// visible in August from Orta San Giulio" becomes one session per object. The model can
    /// respond either with the full plan, or (if it decides it needs more to go on — an unclear
    /// date range, an ambiguous object list) a single clarifying question instead; the caller
    /// (`AIPlanProjectSheet`) shows that question, collects an answer, and calls this again with
    /// the answer folded into `notes` — the same one-shot `generate` call each time, not a real
    /// back-and-forth chat session, since `/api/generate` has no conversation state of its own.
    func planProject(goal: String, notes: String = "") async throws -> ProjectPlanResponse {
        let text = try await generate(prompt: Self.projectPrompt(goal: goal, notes: notes))
        guard let json = Self.extractJSONObject(from: text) else { throw OllamaError.invalidPlanJSON }
        if let probe = try? JSONDecoder().decode(NeedsMoreInfoProbe.self, from: json),
           probe.needsMoreInfo == true, let question = probe.question, !question.isEmpty {
            return .needsMoreInfo(question: question)
        }
        do {
            return .plan(try JSONDecoder().decode(ProjectPlanSuggestion.self, from: json))
        } catch {
            throw OllamaError.invalidPlanJSON
        }
    }

    /// Writes a plain-English description/annotation for a project or session, grounded in what
    /// was actually observed/captured (`AIDescriptionContext.forProject`/`forSession`) rather than
    /// invented from the goal alone — "leveraging the information gathered during the sessions."
    /// Unlike `planSession`/`planProject`, this asks for plain text, not JSON, since there's no
    /// structured shape to fill in, just a paragraph.
    func summarize(context: String) async throws -> String {
        let text = try await generate(prompt: Self.summaryPrompt(context: context))
        let stripped = Self.stripReasoningPreamble(from: text)
        guard !stripped.isEmpty else { throw OllamaError.emptySummary }
        return stripped
    }

    /// The model this app actually wants when it's available — a good balance of capability vs.
    /// speed for the short planning prompts this feature sends. Just a preference, not a
    /// requirement: `resolveModel()` falls back to whatever's actually installed when it isn't.
    static let preferredModel = "qwen3:8b"

    /// `model` if explicitly set; otherwise `preferredModel` if that's actually installed;
    /// otherwise the first name `installedModels()` reports. Throws `noModelsInstalled` rather
    /// than falling through to a name that's likely to 404 anyway.
    private func resolveModel() async throws -> String {
        if let model { return model }
        let installed = try await installedModels()
        if installed.contains(Self.preferredModel) { return Self.preferredModel }
        guard let first = installed.first else { throw OllamaError.noModelsInstalled }
        return first
    }

    private func generate(prompt: String) async throws -> String {
        let resolvedModel = try await resolveModel()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": resolvedModel, "prompt": prompt, "stream": false,
        ])
        // A local model — especially a reasoning one that "thinks" before answering — can
        // legitimately take well past URLRequest's normal 60s default, which is what "Ollama goes
        // in timeout" actually was: the request timing out, not Ollama itself failing.
        request.timeoutInterval = 180
        let data = try await transport.send(request)
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = envelope["response"] as? String
        else {
            throw OllamaError.badResponse(message: nil)
        }
        return response
    }

    /// Ollama's own reply is plain text, not guaranteed-valid JSON on its own even when the
    /// prompt asks for "only JSON" — smaller models routinely wrap it in a sentence, a
    /// ` ```json ` fence, or (reasoning models) a `<think>...</think>` block ahead of the actual
    /// answer. Taking the substring between the first `{` and the last `}` recovers the actual
    /// object in every case that matters without needing a real parser to find it.
    private static func extractJSONObject(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }

    /// For plain-text (non-JSON) replies, like `summarize(context:)`'s — reasoning models still
    /// sometimes prepend a `<think>...</think>` block even for a simple prose request, and unlike
    /// a JSON reply there's no `{`/`}` pair to extract the real answer from instead, so this just
    /// drops everything up to and including the closing tag when one's present.
    private static func stripReasoningPreamble(from text: String) -> String {
        if let range = text.range(of: "</think>") {
            return String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        \(notes.isEmpty ? "" : "Context: \(notes)\n")\
        If the goal names or implies a list of distinct targets (e.g. "the nicest Messier objects \
        visible in August"), plan one session per target, each session's plannedObjects containing \
        just that one object, rather than lumping several into a single session.
        If — and only if — you genuinely cannot produce a good plan without more information (an \
        unclear date range, an ambiguous or missing location, "some objects" with no way to pick \
        which), respond with ONLY this JSON object instead, asking exactly one clarifying question:
        {"needsMoreInfo": true, "question": "your one clarifying question"}
        Otherwise, respond with ONLY a JSON object, no other text, matching exactly this shape:
        {"name": "short project title", "goal": "one sentence goal", "sessions": [\
        {"name": "short session title", "goal": "one sentence goal", "plannedObjects": ["object1"]}]}
        """
    }

    private static func summaryPrompt(context: String) -> String {
        """
        You are an assistant helping an amateur astronomer write a short, engaging description of \
        their observing project or session, grounded only in the facts given below — don't invent \
        details (equipment, dates, objects) that aren't in this data.
        \(context)
        Respond with a plain-text paragraph only — no JSON, no markdown formatting, no preamble like \
        "Here's a description:".
        """
    }
}
