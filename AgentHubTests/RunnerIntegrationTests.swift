import XCTest
@testable import AgentHub

/// Talks to a real AgentHub Runner. Skipped unless one is configured:
///
///     TEST_RUNNER_AGENTHUB_RUNNER_URL=http://localhost:8765 \
///     TEST_RUNNER_AGENTHUB_RUNNER_TOKEN=... \
///     TEST_RUNNER_AGENTHUB_RUNNER_MODEL=ollama/qwen3:0.6b xcodebuild test ...
final class RunnerIntegrationTests: XCTestCase {
    private var server: LocalServer!
    private var token: String?

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["AGENTHUB_RUNNER_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Set AGENTHUB_RUNNER_URL to run against a live runner")
        }
        server = LocalServer(name: "Test", baseURL: url)
        token = env["AGENTHUB_RUNNER_TOKEN"]
    }

    func testSystemModelsAndMemoryCheck() async throws {
        let client = RunnerClient(server: server, token: token)
        let system = try await client.system()
        XCTAssertGreaterThan(system.memory.total_bytes, 0)

        let models = try await client.models()
        XCTAssertFalse(models.isEmpty)

        let small = try await client.check("qwen3:0.6b", hfToken: nil)
        XCTAssertEqual(small.assessment.verdict, .fits)
        let huge = try await client.check("llama3.1:405b", hfToken: nil)
        XCTAssertEqual(huge.assessment.verdict, .tooLarge)
    }

    func testWrongTokenIsRejected() async {
        do {
            _ = try await RunnerClient(server: server, token: "wrong").system()
            XCTFail("expected 401")
        } catch ChatClientError.http(let code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStreamingChatThroughRunner() async throws {
        let model = ProcessInfo.processInfo.environment["AGENTHUB_RUNNER_MODEL"] ?? "ollama/qwen3:0.6b"
        let client = OpenAICompatibleClient(baseURL: server.openAIBaseURL, apiKey: token)
        var reply = ""
        let request = ChatRequest(
            model: model, system: "Answer in one short sentence.",
            messages: [ChatMessage(role: .user, content: "What color is the sky on a clear day? /no_think")], maxTokens: 64)
        for try await chunk in client.stream(request) { reply += chunk }
        XCTAssertFalse(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("runner reply:", reply)
    }
}
