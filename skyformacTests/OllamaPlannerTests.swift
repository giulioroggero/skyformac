import Foundation
import Testing
@testable import skyformac

private final class FakeTransport: OllamaTransport, @unchecked Sendable {
    var responseText: String?
    var statusCode: Int = 200
    var error: Error?
    private(set) var lastRequest: URLRequest?

    func send(_ request: URLRequest) async throws -> Data {
        lastRequest = request
        if let error { throw error }
        guard statusCode == 200 else { throw OllamaError.badResponse }
        let envelope: [String: Any] = ["model": "llama3.2", "response": responseText ?? "", "done": true]
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

        let plan = try await planner.planProject(goal: "messier marathon")
        #expect(plan.name == "Messier Marathon")
        #expect(plan.sessions.count == 2)
        #expect(plan.sessions.last?.plannedObjects == ["M31", "M51"])
    }

    @Test func planSessionThrowsBadResponseOnAServerError() async {
        let transport = FakeTransport()
        transport.statusCode = 500
        let planner = OllamaPlanner(transport: transport)

        await #expect(throws: OllamaError.badResponse) {
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
    }
}
