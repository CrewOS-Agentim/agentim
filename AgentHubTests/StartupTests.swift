import XCTest
@testable import AgentHub

final class StartupTests: XCTestCase {
    /// Shape of `GET /v1/startup` from gateway/agentim/startup.py `snapshot()`.
    private let gatewayJSON = """
    {"configured": true, "idea": "Uber for dog walking", "enabled": true, "plan": "# Dogs",
     "min_minutes": 10, "max_minutes": 30, "next_run": 1000600, "rounds": 2, "notify_channel": "telegram",
     "notify_chat": "42", "updated": 1000000, "now": 1000000,
     "team": [{"key": "sales", "name": "Sales", "emoji": "💼", "focus": "who buys first"}],
     "roles": {"sales": {"name": "Sales", "emoji": "💼"}, "chief": {"name": "Chief of Staff", "emoji": "🗂️"}},
     "messages": [{"round": 2, "role": "sales", "content": "Pre-sell 10 walks.", "ts": 999000},
                  {"round": 2, "role": "chief", "content": "Do it.", "ts": 999100}]}
    """

    func testDecodesTheGatewaySnapshot() throws {
        let state = try JSONDecoder().decode(StartupState.self, from: Data(gatewayJSON.utf8))
        XCTAssertEqual(state.idea, "Uber for dog walking")
        XCTAssertEqual(state.rounds, 2)
        XCTAssertEqual(state.messages?.count, 2)
        XCTAssertEqual(state.role("chief").emoji, "🗂️")
        XCTAssertEqual(state.role("unknown").emoji, "🤖")
        XCTAssertEqual(state.minutesToNext, 10)
    }

    func testUnconfiguredSnapshot() throws {
        let state = try JSONDecoder().decode(StartupState.self, from: Data(#"{"configured": false, "team": []}"#.utf8))
        XCTAssertFalse(state.configured)
        XCTAssertNil(state.minutesToNext)
    }

    func testPausedHasNoCountdown() throws {
        var state = try JSONDecoder().decode(StartupState.self, from: Data(gatewayJSON.utf8))
        state.enabled = false
        XCTAssertNil(state.minutesToNext)
    }

    @MainActor
    func testTokenComesFromTheStackEnv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(StartupModel.client(stackRoot: dir), "no .env yet")
        try "RUNNER_TOKEN=runner\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StartupModel.client(stackRoot: dir)?.token, "runner")
        try "RUNNER_TOKEN=runner\nAGENTIM_API_TOKEN=api\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StartupModel.client(stackRoot: dir)?.token, "api", "the gateway's own token wins")
    }

    @MainActor
    func testDemoMatchesTheGatewayTeam() {
        let demo = StartupModel(demo: true)
        XCTAssertTrue(demo.isRunning)
        XCTAssertEqual(demo.state?.team.count, 8)
        XCTAssertEqual(Set(demo.state?.roles?.keys.map { $0 } ?? []),
                       ["sales", "bizdev", "marketing", "automation", "engineering", "product", "design", "finance", "chief"])
    }
}
