import Foundation
import Testing
@testable import skyformac

private final class FakeTransport: OllamaTransport, @unchecked Sendable {
    var responseText: String?
    var statusCode: Int = 200
    var error: Error?
    /// What `/api/tags` reports as installed — defaults to one model so tests that don't care
    /// about model resolution (most of them) still resolve one without extra setup.
    var installedModels: [String] = ["llama3.2"]
    private(set) var lastRequest: URLRequest?
    private(set) var requestedPaths: [String] = []

    func send(_ request: URLRequest) async throws -> Data {
        lastRequest = request
        requestedPaths.append(request.url?.path ?? "")
        if let error { throw error }
        guard statusCode == 200 else { throw OllamaError.badResponse(message: "HTTP \(statusCode)") }
        if request.url?.path == "/api/tags" {
            let models = installedModels.map { ["name": $0] }
            return try JSONSerialization.data(withJSONObject: ["models": models])
        }
        let envelope: [String: Any] = ["model": installedModels.first ?? "llama3.2", "response": responseText ?? "", "done": true]
        return try JSONSerialization.data(withJSONObject: envelope)
    }
}

struct OllamaPlannerTests {
    @Test func isAvailableIsTrueWhenTheServerResponds() async {
        let transport = FakeTransport()
        let planner = OllamaPlanner(transport: transport)
        #expect(await planner.isAvailable())
    }

    @Test func isAvailableIsFalseWhenTheServerIsUnreachable() async {
        let transport = FakeTransport()
        transport.error = URLError(.cannotConnectToHost)
        let planner = OllamaPlanner(transport: transport)
        #expect(!(await planner.isAvailable()))
    }

    @Test func installedModelsListsEveryReportedName() async throws {
        let transport = FakeTransport()
        transport.installedModels = ["qwen3.5:4b", "gemma4:e2b"]
        let planner = OllamaPlanner(transport: transport)

        #expect(try await planner.installedModels() == ["qwen3.5:4b", "gemma4:e2b"])
    }

    @Test func planSessionAutoResolvesTheFirstInstalledModelWhenNoneIsConfigured() async throws {
        let transport = FakeTransport()
        transport.installedModels = ["qwen3.5:4b", "gemma4:e2b"]
        transport.responseText = #"{"name": "n", "goal": "g", "plannedObjects": []}"#
        let planner = OllamaPlanner(transport: transport)

        _ = try await planner.planSession(goal: "see saturn")

        let request = try #require(transport.lastRequest)
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "qwen3.5:4b")
    }

    @Test func planSessionPrefersQwen3_8bWhenInstalledAlongsideOthers() async throws {
        let transport = FakeTransport()
        transport.installedModels = ["gemma4:e2b", "qwen3:8b", "deepseek-r1:8b"]
        transport.responseText = #"{"name": "n", "goal": "g", "plannedObjects": []}"#
        let planner = OllamaPlanner(transport: transport)

        _ = try await planner.planSession(goal: "see saturn")

        let request = try #require(transport.lastRequest)
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "qwen3:8b")
    }

    @Test func generateRequestUsesAGenerousTimeout() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"name": "n", "goal": "g", "plannedObjects": []}"#
        let planner = OllamaPlanner(transport: transport)

        _ = try await planner.planSession(goal: "see saturn")

        let request = try #require(transport.lastRequest)
        #expect(request.timeoutInterval >= 120)
    }

    @Test func planSessionThrowsNoModelsInstalledWhenTheServerHasNone() async {
        let transport = FakeTransport()
        transport.installedModels = []
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.noModelsInstalled) {
            try await planner.planSession(goal: "see saturn")
        }
    }

    @Test func planSessionParsesAPlainJSONResponse() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"name": "Messier Night", "goal": "See open clusters", "plannedObjects": ["M13", "M57"]}"#
        let planner = OllamaPlanner(transport: transport)

        let plan = try await planner.planSession(goal: "see m13, m57")
        #expect(plan.name == "Messier Night")
        #expect(plan.plannedObjects == ["M13", "M57"])
    }

    @Test func planSessionExtractsJSONWrappedInProseAndMarkdownFences() async throws {
        let transport = FakeTransport()
        transport.responseText = """
        Sure! Here's a plan:
        ```json
        {"name": "Saturn Watch", "goal": "Track the rings", "plannedObjects": ["Saturn"]}
        ```
        Let me know if you'd like changes.
        """
        let planner = OllamaPlanner(transport: transport)

        let plan = try await planner.planSession(goal: "see saturn")
        #expect(plan.name == "Saturn Watch")
        #expect(plan.plannedObjects == ["Saturn"])
    }

    @Test func planSessionExtractsJSONAfterAThinkingBlock() async throws {
        // Reasoning models (qwen3.5, deepseek-r1, ...) can prepend their own chain-of-thought
        // ahead of the final answer even with the model's own "thinking" field separate — this
        // covers the case where some of that leaks into "response" too.
        let transport = FakeTransport()
        transport.responseText = """
        <think>The user wants a plan for Saturn. Let me consider the goal...</think>
        {"name": "Saturn Watch", "goal": "Track the rings", "plannedObjects": ["Saturn"]}
        """
        let planner = OllamaPlanner(transport: transport)

        let plan = try await planner.planSession(goal: "see saturn")
        #expect(plan.name == "Saturn Watch")
    }

    @Test func planSessionThrowsInvalidPlanJSONWhenNoJSONIsPresent() async {
        let transport = FakeTransport()
        transport.responseText = "I'm not sure what you mean."
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.invalidPlanJSON) {
            try await planner.planSession(goal: "see saturn")
        }
    }

    @Test func planSessionThrowsInvalidPlanJSONWhenFieldsDontMatch() async {
        let transport = FakeTransport()
        transport.responseText = #"{"unexpected": "shape"}"#
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.invalidPlanJSON) {
            try await planner.planSession(goal: "see saturn")
        }
    }

    @Test func planProjectParsesNestedSessions() async throws {
        let transport = FakeTransport()
        transport.responseText = #"""
        {"name": "Messier Marathon", "goal": "See many Messier objects",
         "sessions": [
           {"name": "Night 1", "goal": "Clusters", "plannedObjects": ["M13"]},
           {"name": "Night 2", "goal": "Galaxies", "plannedObjects": ["M31", "M51"]}
         ]}
        """#
        let planner = OllamaPlanner(transport: transport)

        let response = try await planner.planProject(goal: "messier marathon")
        guard case .plan(let plan) = response else {
            Issue.record("expected .plan, got \(response)")
            return
        }
        #expect(plan.name == "Messier Marathon")
        #expect(plan.sessions.count == 2)
        #expect(plan.sessions.last?.plannedObjects == ["M31", "M51"])
    }

    @Test func planProjectReturnsNeedsMoreInfoWhenTheModelAsksAQuestion() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"needsMoreInfo": true, "question": "Which month and location?"}"#
        let planner = OllamaPlanner(transport: transport)

        let response = try await planner.planProject(goal: "the nicest deep-sky objects")
        #expect(response == .needsMoreInfo(question: "Which month and location?"))
    }

    @Test func planProjectIgnoresAnExplicitFalseNeedsMoreInfoFlag() async throws {
        let transport = FakeTransport()
        transport.responseText = #"""
        {"needsMoreInfo": false, "name": "Messier Marathon", "goal": "See many objects",
         "sessions": [{"name": "Night 1", "goal": "Clusters", "plannedObjects": ["M13"]}]}
        """#
        let planner = OllamaPlanner(transport: transport)

        let response = try await planner.planProject(goal: "messier marathon")
        guard case .plan(let plan) = response else {
            Issue.record("expected .plan, got \(response)")
            return
        }
        #expect(plan.name == "Messier Marathon")
    }

    @Test func planSessionThrowsBadResponseOnAServerError() async {
        let transport = FakeTransport()
        transport.statusCode = 500
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.badResponse(message: "HTTP 500")) {
            try await planner.planSession(goal: "see saturn")
        }
    }

    @Test func generateRequestUsesTheConfiguredModelAndPOSTsJSON() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"name": "n", "goal": "g", "plannedObjects": []}"#
        let planner = OllamaPlanner(baseURL: URL(string: "http://localhost:11434")!, model: "custom-model", transport: transport)

        _ = try await planner.planSession(goal: "see saturn")

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/generate")
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["model"] as? String == "custom-model")
        // An explicitly configured model skips the /api/tags round trip entirely.
        #expect(!transport.requestedPaths.contains("/api/tags"))
    }

    @Test func summarizeReturnsThePlainTextResponseTrimmed() async throws {
        let transport = FakeTransport()
        transport.responseText = "  A great night under dark skies.  \n"
        let planner = OllamaPlanner(transport: transport)

        let summary = try await planner.summarize(context: "Project: Test")
        #expect(summary == "A great night under dark skies.")
    }

    @Test func summarizeStripsAThinkingBlockPreamble() async throws {
        let transport = FakeTransport()
        transport.responseText = "<think>Let me consider the facts given...</think>\nA great night under dark skies."
        let planner = OllamaPlanner(transport: transport)

        let summary = try await planner.summarize(context: "Project: Test")
        #expect(summary == "A great night under dark skies.")
    }

    @Test func summarizeThrowsEmptySummaryWhenNothingIsLeftAfterStripping() async {
        let transport = FakeTransport()
        transport.responseText = "<think>Only thinking, no actual answer.</think>"
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.emptySummary) {
            try await planner.summarize(context: "Project: Test")
        }
    }

    @Test func summarizeDoesNotRequireJSONFormatting() async throws {
        // Unlike planSession/planProject, summarize's prompt asks for plain prose — a response
        // with no braces at all should still work rather than throwing invalidPlanJSON.
        let transport = FakeTransport()
        transport.responseText = "Just a plain sentence with no JSON in it whatsoever."
        let planner = OllamaPlanner(transport: transport)

        let summary = try await planner.summarize(context: "Session: Test")
        #expect(summary == "Just a plain sentence with no JSON in it whatsoever.")
    }

    @Test func respondParsesAPlainReply() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"kind": "reply", "text": "M13 is well placed tonight."}"#
        let planner = OllamaPlanner(transport: transport)

        let response = try await planner.respond(to: "what should I see tonight?", context: "", history: [])
        #expect(response == .reply("M13 is well placed tonight."))
    }

    @Test func respondParsesACreateProjectProposal() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"kind": "createProject", "name": "Messier Marathon", "goal": "See many objects", "message": "Create it?"}"#
        let planner = OllamaPlanner(transport: transport)

        let response = try await planner.respond(to: "start a messier marathon project", context: "", history: [])
        #expect(response == .action(.createProject(name: "Messier Marathon", goal: "See many objects"), message: "Create it?"))
    }

    @Test func respondParsesACreateSessionProposal() async throws {
        let transport = FakeTransport()
        transport.responseText = #"""
        {"kind": "createSession", "projectName": "Messier Marathon", "name": "Night 1", "goal": "Clusters",
         "plannedObjects": ["M13"], "message": "Add this session?"}
        """#
        let planner = OllamaPlanner(transport: transport)

        let response = try await planner.respond(to: "add a session for M13", context: "", history: [])
        #expect(response == .action(
            .createSession(projectName: "Messier Marathon", sessionName: "Night 1", goal: "Clusters", plannedObjects: ["M13"]),
            message: "Add this session?"
        ))
    }

    @Test func respondParsesAnApplyCameraSettingsProposal() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"kind": "applyCameraSettings", "gain": 150, "exposureSeconds": 3.0, "mode": "liveStack", "message": "Try these?"}"#
        let planner = OllamaPlanner(transport: transport)

        let response = try await planner.respond(to: "suggest settings for M31", context: "", history: [])
        #expect(response == .action(.applyCameraSettings(gain: 150, exposureSeconds: 3.0, mode: .liveStack), message: "Try these?"))
    }

    @Test func respondAllowsPartialCameraSettings() async throws {
        // Only some of gain/exposureSeconds/mode may be proposed at once — the rest should stay
        // untouched by the caller, not default to some made-up value.
        let transport = FakeTransport()
        transport.responseText = #"{"kind": "applyCameraSettings", "gain": 200, "message": "Bump the gain?"}"#
        let planner = OllamaPlanner(transport: transport)

        let response = try await planner.respond(to: "increase the gain", context: "", history: [])
        #expect(response == .action(.applyCameraSettings(gain: 200, exposureSeconds: nil, mode: nil), message: "Bump the gain?"))
    }

    @Test func respondThrowsInvalidPlanJSONForAnUnknownKind() async {
        let transport = FakeTransport()
        transport.responseText = #"{"kind": "doSomethingElse"}"#
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.invalidPlanJSON) {
            try await planner.respond(to: "test", context: "", history: [])
        }
    }

    @Test func respondThrowsInvalidPlanJSONWhenCreateProjectHasNoName() async {
        let transport = FakeTransport()
        transport.responseText = #"{"kind": "createProject", "goal": "no name given"}"#
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.invalidPlanJSON) {
            try await planner.respond(to: "test", context: "", history: [])
        }
    }

    @Test func respondIncludesRecentHistoryInThePrompt() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"kind": "reply", "text": "ok"}"#
        let planner = OllamaPlanner(transport: transport)
        let history = [AssistantMessage(role: .user, text: "earlier question"), AssistantMessage(role: .assistant, text: "earlier answer")]

        _ = try await planner.respond(to: "follow-up", context: "some context", history: history)

        let request = try #require(transport.lastRequest)
        let body = try #require(request.httpBody)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let prompt = try #require(json?["prompt"] as? String)
        #expect(prompt.contains("earlier question"))
        #expect(prompt.contains("earlier answer"))
        #expect(prompt.contains("some context"))
    }

    @Test func suggestNextObjectsParsesTheObjectsArray() async throws {
        let transport = FakeTransport()
        transport.responseText = #"{"objects": ["M13", "Saturn", "NGC 7000"]}"#
        let planner = OllamaPlanner(transport: transport)

        let objects = try await planner.suggestNextObjects(context: "some context")
        #expect(objects == ["M13", "Saturn", "NGC 7000"])
    }

    @Test func suggestNextObjectsThrowsInvalidPlanJSONWhenNoJSONIsPresent() async {
        let transport = FakeTransport()
        transport.responseText = "I'm not sure what to suggest."
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.invalidPlanJSON) {
            try await planner.suggestNextObjects(context: "some context")
        }
    }

    @Test func suggestNextObjectsExtractsJSONAfterAThinkingBlock() async throws {
        let transport = FakeTransport()
        transport.responseText = """
        <think>The user wants object suggestions...</think>
        {"objects": ["M31"]}
        """
        let planner = OllamaPlanner(transport: transport)

        let objects = try await planner.suggestNextObjects(context: "some context")
        #expect(objects == ["M31"])
    }
}
