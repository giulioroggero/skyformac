import Foundation

/// The one HTTP call `OllamaPlanner` needs — narrowed to a protocol (rather than using
/// `URLSession` directly) so tests can supply a fake that returns a canned response instead of
/// requiring a real Ollama server running on the test machine.
protocol OllamaTransport: Sendable {
    func send(_ request: URLRequest) async throws -> Data
    /// Streams the response as it arrives — one `Data` chunk per NDJSON line for a real `stream:
    /// true` Ollama request, so a caller (`generate(prompt:onPartialResponse:)`) can surface
    /// partial text as it's generated instead of waiting for the whole reply. Defaults to
    /// wrapping `send(_:)` and yielding its entire body as a single chunk, so a fake transport
    /// that only implements `send(_:)` (every test fake in this app) keeps working completely
    /// unchanged — it just never produces more than one "partial" update, exactly what a
    /// synchronous stand-in should do.
    func sendStreaming(_ request: URLRequest) -> AsyncThrowingStream<Data, Error>
}

extension OllamaTransport {
    func sendStreaming(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await send(request))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
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

    /// Real NDJSON streaming via `bytes(for:)` — each line Ollama writes as it generates is its
    /// own complete JSON object, so this yields one `Data` chunk per line rather than waiting for
    /// the connection to close the way `send(_:)`/`data(for:)` does.
    func sendStreaming(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await self.bytes(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        // Drain the (non-streamed, plain-JSON) error body so the same "surface
                        // Ollama's own message" behavior `send(_:)` has applies here too.
                        var collected = Data()
                        for try await byte in bytes { collected.append(byte) }
                        let serverMessage = (try? JSONSerialization.jsonObject(with: collected) as? [String: Any])?["error"] as? String
                        let status = (response as? HTTPURLResponse)?.statusCode
                        continuation.finish(throwing: OllamaError.badResponse(message: serverMessage ?? status.map { "HTTP \($0)" }))
                        return
                    }
                    for try await line in bytes.lines {
                        continuation.yield(Data(line.utf8))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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

    /// What `respond(to:context:history:)` returns — either a plain answer, or a proposed
    /// `AssistantAction` with the plain-English explanation to show alongside its Approve/Reject
    /// buttons. Never applies anything itself; that's `CameraManager.confirmAssistantAction()`'s
    /// job, strictly after the user approves.
    enum AssistantResponse: Equatable, Sendable {
        case reply(String)
        case action(AssistantAction, message: String)
    }

    /// The one shape every assistant reply decodes into first — `kind` picks which of the other,
    /// all-optional fields actually matter; unused ones for a given `kind` are simply `nil` and
    /// ignored. One flexible struct rather than four separate ones since only one `kind` at a
    /// time is ever populated, and this is decoded exactly once per reply either way.
    private struct AssistantRawResponse: Codable {
        var kind: String
        var text: String?
        var message: String?
        var name: String?
        var goal: String?
        var projectName: String?
        var plannedObjects: [String]?
        var gain: Int?
        var exposureSeconds: Double?
        var mode: String?
        var enabled: Bool?
        var frameCount: Int?
        var fraction: Double?
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
    ///
    /// `onPartialResponse`, if given, fires with the raw text accumulated so far each time a new
    /// chunk streams in — including a reasoning model's own `<think>...</think>` preamble, since
    /// there's no way to know where (or whether) that block ends until the whole reply is in. The
    /// final return value has that preamble already stripped; a caller showing partial text live
    /// (`AIDescribeSheet`) should simply replace it with the final value once this returns, the
    /// same way a chat UI shows a model "thinking" before swapping in its polished answer.
    func summarize(context: String, extraInstructions: String = "", onPartialResponse: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let text = try await generate(
            prompt: Self.summaryPrompt(context: context, extraInstructions: extraInstructions), onPartialResponse: onPartialResponse
        )
        let stripped = Self.stripReasoningPreamble(from: text)
        guard !stripped.isEmpty else { throw OllamaError.emptySummary }
        return stripped
    }

    /// "Add tags can be helped by AI" — a handful of short, lowercase, single/double-word tags
    /// grounded in the same project/session context `summarize(context:)` uses, filtered against
    /// `existingTags` so the caller only ever sees genuinely new suggestions to add.
    func suggestTags(context: String, existingTags: [String], extraInstructions: String = "") async throws -> [String] {
        let text = try await generate(
            prompt: Self.suggestTagsPrompt(context: context, existingTags: existingTags, extraInstructions: extraInstructions)
        )
        guard let json = Self.extractJSONArray(from: text) else { throw OllamaError.invalidPlanJSON }
        guard let decoded = try? JSONDecoder().decode([String].self, from: json) else { throw OllamaError.invalidPlanJSON }
        let existingLowercased = Set(existingTags.map { $0.lowercased() })
        var seen = existingLowercased
        var result: [String] = []
        for tag in decoded {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    /// A full next-session suggestion — name, goal, target objects, *and* which project it belongs
    /// to (an existing one by exact name, or a new one), not just a bare object name. Driven by a
    /// user-editable "skill" (`AppSettings
    /// .sessionSuggestionSkill`) folded into the prompt as standing instructions, so the caller
    /// controls the model's preferences without a code change.
    struct SuggestedSessionPlan: Codable, Equatable, Sendable {
        var projectName: String
        var name: String
        var goal: String
        var plannedObjects: [String]
    }

    func suggestNextSession(context: String, skill: String) async throws -> SuggestedSessionPlan {
        let text = try await generate(prompt: Self.suggestNextSessionPrompt(context: context, skill: skill))
        guard let json = Self.extractJSONObject(from: text) else { throw OllamaError.invalidPlanJSON }
        guard let decoded = try? JSONDecoder().decode(SuggestedSessionPlan.self, from: json),
              !decoded.name.isEmpty, !decoded.projectName.isEmpty
        else {
            throw OllamaError.invalidPlanJSON
        }
        return decoded
    }

    /// The sidebar assistant's own entry point — "provide insight, create projects and sessions,
    /// suggest camera configuration, suggest what to see next," all through one classification
    /// call: the model either just answers, or proposes exactly one `AssistantAction` alongside a
    /// plain-English explanation, never both and never applying anything itself (that's strictly
    /// `CameraManager.confirmAssistantAction()`'s job, after the user approves). `history` is the
    /// last few turns folded into the prompt as plain text, since `/api/generate` has no
    /// conversation state of its own — the same reasoning `planProject`'s clarification round trip
    /// already relies on.
    /// `image`, when given (a JPEG-encoded snapshot of whatever's currently on screen — a
    /// capture, an elaborated image), is attached the same way `discussImage` attaches Edit
    /// Image's own preview — "what is that?" about a capture needs the assistant to actually see
    /// it, not just its filename/metadata in `context`. Every cloud transport already threads an
    /// attached image through (see `AnthropicTransport`/`GeminiTransport`'s own doc comments); a
    /// local Ollama model needs to itself be vision-capable for this to actually see anything.
    func respond(to message: String, context: String, history: [AssistantMessage], image: Data? = nil) async throws -> AssistantResponse {
        let text = try await generate(prompt: Self.assistantPrompt(message: message, context: context, history: history), image: image)
        guard let json = Self.extractJSONObject(from: text), let raw = try? JSONDecoder().decode(AssistantRawResponse.self, from: json) else {
            // A model that ignores the "respond with ONLY a JSON object" instruction and just
            // answers a conversational question in plain prose instead (confirmed live: "what's
            // my best session?" against a real provider) shouldn't read as a hard failure — the
            // whole point of the "reply" kind is that a plain answer is a perfectly valid
            // response, so falling back to treating the raw text as one directly is strictly
            // friendlier than surfacing "didn't contain a usable plan" for what's actually a
            // normal answer, just not in the requested envelope.
            let stripped = Self.stripReasoningPreamble(from: text)
            guard !stripped.isEmpty else { throw OllamaError.invalidPlanJSON }
            return .reply(stripped)
        }
        switch raw.kind {
        case "createProject":
            guard let name = raw.name, !name.isEmpty else { throw OllamaError.invalidPlanJSON }
            let message = raw.message ?? "Create a new project named \"\(name)\"?"
            return .action(.createProject(name: name, goal: raw.goal ?? ""), message: message)
        case "createSession":
            guard let name = raw.name, !name.isEmpty, let projectName = raw.projectName, !projectName.isEmpty else {
                throw OllamaError.invalidPlanJSON
            }
            let message = raw.message ?? "Create a new session \"\(name)\" in \"\(projectName)\"?"
            return .action(
                .createSession(projectName: projectName, sessionName: name, goal: raw.goal ?? "", plannedObjects: raw.plannedObjects ?? []),
                message: message
            )
        case "applyCameraSettings":
            guard raw.gain != nil || raw.exposureSeconds != nil || raw.mode != nil else { throw OllamaError.invalidPlanJSON }
            let mode = raw.mode.flatMap(AcquisitionMode.init(rawValue:))
            let message = raw.message ?? "Apply the suggested camera settings?"
            return .action(.applyCameraSettings(gain: raw.gain, exposureSeconds: raw.exposureSeconds, mode: mode), message: message)
        case "setLiveStacking":
            guard let enabled = raw.enabled else { throw OllamaError.invalidPlanJSON }
            let message = raw.message ?? (enabled ? "Start Live Stack?" : "Stop Live Stack?")
            return .action(.setLiveStacking(enabled: enabled), message: message)
        case "startLuckyImagingBurst":
            guard let frameCount = raw.frameCount, frameCount > 0 else { throw OllamaError.invalidPlanJSON }
            let message = raw.message ?? "Start a Lucky Imaging burst of \(frameCount) frames?"
            return .action(.startLuckyImagingBurst(frameCount: frameCount), message: message)
        case "stackLuckyImagingBest":
            guard let fraction = raw.fraction, fraction > 0, fraction <= 1 else { throw OllamaError.invalidPlanJSON }
            let message = raw.message ?? "Stack the sharpest \(Int(fraction * 100))% of the Lucky Imaging burst?"
            return .action(.stackLuckyImagingBest(fraction: fraction), message: message)
        case "createEquipmentSystem":
            guard let name = raw.name, !name.isEmpty else { throw OllamaError.invalidPlanJSON }
            let message = raw.message ?? "Create a new equipment system named \"\(name)\"?"
            return .action(.createEquipmentSystem(name: name), message: message)
        case "reply":
            return .reply(raw.text ?? raw.message ?? "")
        default:
            throw OllamaError.invalidPlanJSON
        }
    }

    /// What `discussImage(message:adjustmentsDescription:image:history:)` returns — either a plain
    /// answer, or a proposed set of slider values grounded in what the model actually saw in the
    /// attached image. Never applies anything itself; the caller (`SingleImagePostProcessingView`)
    /// shows the proposal and only writes it into `ImageEditor.Adjustments` once the user approves,
    /// the same "propose, don't act" discipline `respond(to:context:history:)`'s `AssistantAction`
    /// already follows for project/session/camera changes.
    enum ImageAssistantResponse: Equatable, Sendable {
        case reply(String)
        case suggestion(ImageAdjustmentSuggestion)
    }

    /// Every field mirrors one of `ImageEditor.Adjustments`' own sliders by name (kept as a
    /// separate type, not that struct itself, so this file doesn't need to import `ImageEditor` —
    /// `SingleImagePostProcessingView` is what actually merges whichever fields came back non-`nil`
    /// onto its own `Adjustments` value) — `nil` means "not proposing to change this one," not
    /// "set it to zero."
    struct ImageAdjustmentSuggestion: Codable, Equatable, Sendable {
        var message: String
        var brightness: Double?
        var contrast: Double?
        var saturation: Double?
        var gamma: Double?
        var sharpenIntensity: Double?
        var denoiseAmount: Double?
        var chromaNoiseReduction: Double?
        var greenCastRemoval: Double?
        var starSizeReduction: Double?
        var shadowLift: Double?
        var highlightRecovery: Double?
        var vibrance: Double?
        var warmth: Double?
        var tint: Double?
        var deconvolutionSharpen: Double?
    }

    private struct ImageAssistantRawResponse: Codable {
        var kind: String
        var text: String?
        var message: String?
        var brightness: Double?
        var contrast: Double?
        var saturation: Double?
        var gamma: Double?
        var sharpenIntensity: Double?
        var denoiseAmount: Double?
        var chromaNoiseReduction: Double?
        var greenCastRemoval: Double?
        var starSizeReduction: Double?
        var shadowLift: Double?
        var highlightRecovery: Double?
        var vibrance: Double?
        var warmth: Double?
        var tint: Double?
        var deconvolutionSharpen: Double?
    }

    /// Edit Image's own AI panel — grounded in an actual attached image (`image`, JPEG-encoded)
    /// rather than only a text description of the current sliders, so the model can answer "what's
    /// wrong with this image" or "how do I fix this color cast" by actually looking, and propose
    /// specific slider values instead of vague advice. Every cloud transport already threads an
    /// attached image through to its own provider's multimodal request shape (see
    /// `AnthropicTransport`/`GeminiTransport`'s own doc comments); a local Ollama model needs to
    /// itself be vision-capable (e.g. `llava`, `llama3.2-vision`) for this to actually see anything
    /// — a non-vision model simply won't reference the image in its reply, since Ollama's own
    /// `/api/generate` silently ignores an attached `images` array a model doesn't support.
    func discussImage(
        message: String, adjustmentsDescription: String, image: Data, history: [AssistantMessage]
    ) async throws -> ImageAssistantResponse {
        let text = try await generate(
            prompt: Self.imageAssistantPrompt(message: message, adjustmentsDescription: adjustmentsDescription, history: history),
            image: image
        )
        guard let json = Self.extractJSONObject(from: text) else { throw OllamaError.invalidPlanJSON }
        guard let raw = try? JSONDecoder().decode(ImageAssistantRawResponse.self, from: json) else { throw OllamaError.invalidPlanJSON }
        switch raw.kind {
        case "reply":
            return .reply(raw.text ?? raw.message ?? "")
        case "adjustments":
            return .suggestion(ImageAdjustmentSuggestion(
                message: raw.message ?? "Apply these adjustments?",
                brightness: raw.brightness, contrast: raw.contrast, saturation: raw.saturation, gamma: raw.gamma,
                sharpenIntensity: raw.sharpenIntensity, denoiseAmount: raw.denoiseAmount,
                chromaNoiseReduction: raw.chromaNoiseReduction, greenCastRemoval: raw.greenCastRemoval,
                starSizeReduction: raw.starSizeReduction, shadowLift: raw.shadowLift, highlightRecovery: raw.highlightRecovery,
                vibrance: raw.vibrance, warmth: raw.warmth, tint: raw.tint, deconvolutionSharpen: raw.deconvolutionSharpen
            ))
        default:
            throw OllamaError.invalidPlanJSON
        }
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

    /// `stream: true` — Ollama writes one complete JSON object per line as it generates, each
    /// with the token(s) generated so far in `"response"` and `"done": false`, until a final line
    /// with `"done": true`. Streaming (rather than the previous `stream: false`, wait-for-the-
    /// whole-thing approach) means a caller gets the first tokens within a second or two instead
    /// of after the entire reply — including a reasoning model's full hidden "thinking" pass —
    /// finishes; `onPartialResponse`, if given, is called with the text accumulated so far after
    /// every chunk, so a UI can show a response growing live instead of a bare spinner.
    /// `options.num_predict` (`AppSettings.ollamaMaxResponseTokens`, user-configurable in Settings)
    /// bounds how many tokens a single response — reasoning included — may generate at all.
    private func generate(prompt: String, image: Data? = nil, onPartialResponse: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let resolvedModel = try await resolveModel()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": resolvedModel, "prompt": prompt, "stream": true,
            "options": ["num_predict": AppSettings.ollamaMaxResponseTokens],
        ]
        if let image {
            // Ollama's own real vision-model field: a top-level array of base64-encoded images
            // alongside the prompt. `AnthropicTransport`/`GeminiTransport` read this exact field
            // back out of the request body this method builds to construct their own provider's
            // multimodal payload — see each transport's own doc comment.
            body["images"] = [image.base64EncodedString()]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        // A local model — especially a reasoning one that "thinks" before answering — can
        // legitimately take well past URLRequest's normal 60s default, which is what "Ollama goes
        // in timeout" actually was: the request timing out, not Ollama itself failing.
        request.timeoutInterval = 180

        var fullText = ""
        var sawAResponseField = false
        for try await chunk in transport.sendStreaming(request) {
            guard let envelope = try? JSONSerialization.jsonObject(with: chunk) as? [String: Any] else { continue }
            if let responseChunk = envelope["response"] as? String {
                sawAResponseField = true
                fullText += responseChunk
                onPartialResponse?(fullText)
            }
            if envelope["done"] as? Bool == true { break }
        }
        guard sawAResponseField else { throw OllamaError.badResponse(message: nil) }
        return fullText
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

    /// Same reasoning as `extractJSONObject(from:)`, for the one reply shape (`suggestTags`) that's
    /// a bare JSON array rather than an object.
    private static func extractJSONArray(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]"), start <= end else { return nil }
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

    private static func assistantPrompt(message: String, context: String, history: [AssistantMessage]) -> String {
        let historyText = history.suffix(6).map { entry in
            "\(entry.role == .user ? "User" : "Assistant"): \(entry.text)"
        }.joined(separator: "\n")
        return """
        You are an assistant embedded in the sidebar of an astrophotography capture app, grounded \
        in the current page's own context below — use it, don't ignore it. If an image is \
        attached, it's a snapshot of whatever's currently on screen (a capture, an elaborated \
        image) — actually look at it before answering a question like "what is that?" rather than \
        guessing from the context text alone.
        Context:
        \(context)
        \(historyText.isEmpty ? "" : "Recent conversation:\n\(historyText)\n")\
        User message: \(message)

        You can either just answer (insight, advice, what to see next, what's in the gallery, which \
        equipment is set up), or propose ONE of: creating a new project, creating a new session, \
        changing the camera's gain/exposure/mode, starting or stopping Live Stack, starting a Lucky \
        Imaging burst, stacking an already-completed Lucky Imaging burst's sharpest frames, or \
        creating a new equipment system. Never claim to have already done something — a proposal is \
        only ever applied after the user approves it separately, so always include a short "message" \
        field describing the proposal in plain English for that approval step.

        Respond with ONLY a JSON object, no other text, in exactly one of these shapes:
        {"kind": "reply", "text": "your answer"}
        {"kind": "createProject", "name": "...", "goal": "...", "message": "..."}
        {"kind": "createSession", "projectName": "...", "name": "...", "goal": "...", "plannedObjects": ["..."], "message": "..."}
        {"kind": "applyCameraSettings", "gain": 100, "exposureSeconds": 2.0, "mode": "liveStack", "message": "..."}
        {"kind": "setLiveStacking", "enabled": true, "message": "..."}
        {"kind": "startLuckyImagingBurst", "frameCount": 100, "message": "..."}
        {"kind": "stackLuckyImagingBest", "fraction": 0.2, "message": "..."}
        {"kind": "createEquipmentSystem", "name": "...", "message": "..."}
        For applyCameraSettings, "mode" must be exactly one of "liveStack", "luckyImaging", or "both" \
        if included, and any of gain/exposureSeconds/mode may be omitted if you're not proposing to \
        change that one. setLiveStacking/startLuckyImagingBurst/stackLuckyImagingBest all need a \
        connected camera (see the context above) — don't propose them when none is connected. \
        "fraction" for stackLuckyImagingBest is 0...1 (e.g. 0.2 for "the sharpest 20%").
        """
    }

    private static func imageAssistantPrompt(message: String, adjustmentsDescription: String, history: [AssistantMessage]) -> String {
        let historyText = history.suffix(6).map { entry in
            "\(entry.role == .user ? "User" : "Assistant"): \(entry.text)"
        }.joined(separator: "\n")
        return """
        You are an assistant embedded in this astrophotography app's Edit Image tool. An image of \
        the photo currently being edited is attached — actually look at it: its color balance, \
        noise level, sharpness, contrast, and any visible artifacts (gradient/vignetting, hot \
        pixels, bloated stars, green color cast).
        Adjustment sliders already applied: \(adjustmentsDescription)
        \(historyText.isEmpty ? "" : "Recent conversation:\n\(historyText)\n")\
        User message: \(message)

        You can either just answer a question about the image, or propose a specific set of \
        adjustment slider values that would improve it, grounded only in what you actually see — \
        never propose changing a slider that's already fine as-is, and never invent an artifact \
        that isn't visible in the image.

        Respond with ONLY a JSON object, no other text, in exactly one of these shapes:
        {"kind": "reply", "text": "your answer"}
        {"kind": "adjustments", "message": "one sentence explaining the proposal", "brightness": 0.1, \
        "contrast": 1.2, "saturation": 1.1, "gamma": 1.0, "sharpenIntensity": 1.5, "denoiseAmount": 0.3, \
        "chromaNoiseReduction": 0.2, "greenCastRemoval": 0.5, "starSizeReduction": 0.2, "shadowLift": 0.3, \
        "highlightRecovery": 0.2, "vibrance": 0.3, "warmth": 0.1, "tint": 0.0, "deconvolutionSharpen": 0.2}
        For "adjustments", every field besides "message" is optional — include only the sliders \
        you're actually proposing to change, omit the rest entirely (don't set an unchanged one to \
        its default). Value ranges: brightness/vibrance/warmth/tint are -1...1 (0 = unchanged); \
        contrast is 0.25...4 (1 = unchanged); saturation is 0...2 and gamma is 0.1...4 (1 = \
        unchanged for both); sharpenIntensity is 0...5 (0 = off); every other field is 0...1 (0 = \
        off).
        """
    }

    private static func summaryPrompt(context: String, extraInstructions: String) -> String {
        """
        You are an assistant helping an amateur astronomer write a short, engaging description of \
        their observing project or session, grounded only in the facts given below — don't invent \
        details (equipment, dates, objects) that aren't in this data.
        \(context)
        \(extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "Additional instructions from the user: \(extraInstructions)\n")\
        Respond with a plain-text paragraph only — no JSON, no markdown formatting, no preamble like \
        "Here's a description:".
        """
    }

    private static func suggestTagsPrompt(context: String, existingTags: [String], extraInstructions: String) -> String {
        """
        You are an assistant suggesting short organizational tags for an amateur astronomer's \
        observing project or session, grounded only in the facts given below — don't invent \
        details (equipment, dates, objects) that aren't in this data.
        \(context)
        \(existingTags.isEmpty ? "" : "Tags already applied (don't repeat these): \(existingTags.joined(separator: ", "))\n")\
        \(extraInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "Additional instructions from the user: \(extraInstructions)\n")\
        Suggest up to 5 new tags — short, lowercase, one or two words each (e.g. "deep-sky", \
        "planetary", "widefield", "moonless-night").
        Respond with ONLY a JSON array of strings, no other text, e.g. ["deep-sky", "widefield"]
        """
    }

    private static func suggestNextSessionPrompt(context: String, skill: String) -> String {
        """
        You are an assistant helping an amateur astronomer plan their next full observing session \
        — not just a single object, but a named session with a goal, target objects, and a project \
        to attach it to.
        \(skill)
        \(context)
        If an existing project's goal genuinely fits this session, propose attaching to it by its \
        exact existing name; otherwise propose a short new project name.
        Respond with ONLY a JSON object, no other text, matching exactly this shape:
        {"projectName": "...", "name": "short session title", "goal": "one sentence goal", \
        "plannedObjects": ["object1"]}
        """
    }
}
