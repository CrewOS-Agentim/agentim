import XCTest
@testable import AgentHub

/// The paid "Cloud models" switch: ChatGPT, Claude and Grok first when connected; local models otherwise.
final class CloudModelsTests: XCTestCase {
    private let server = LocalServer(name: "Mac", baseURL: URL(string: "http://localhost:8765")!)
    private lazy var localQwen = AIModel.server(ServerModelInfo(id: "ollama/qwen3:14b", kind: "chat", size_bytes: nil, parameter_size: "14B", loaded: true), on: server)
    private lazy var localCoder = AIModel.server(ServerModelInfo(id: "ollama/qwen2.5-coder:14b", kind: "chat", size_bytes: nil, parameter_size: "14B", loaded: true), on: server)
    private lazy var claudeLogin = AIModel.server(ServerModelInfo(id: "claude/sonnet", kind: "claude", size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
    private let grok = AIModel.cloudCatalog.first { $0.alias == "grok" }!
    private let gpt = AIModel.cloudCatalog.first { $0.alias == "gpt5" }!
    private let gemini = AIModel.cloudCatalog.first { $0.alias == "gemini" }!
    private let engineer = Agent(name: "Software Engineer", emoji: "", summary: "Pair programmer for debugging and code review.", systemPrompt: "")

    private func route(_ models: [AIModel], cloud: Bool, _ text: String = "Explain the trade-offs of our plan", agent: Agent? = nil) throws -> RoutingDecision {
        try ModelRouter(available: models, settings: .init(), cloudFirst: cloud).route(RoutingRequest(text: text, agent: agent))
    }

    func testWhichModelsArePaidCloud() {
        XCTAssertTrue(ModelRouter.isPaidCloud(grok))
        XCTAssertTrue(ModelRouter.isPaidCloud(gpt))
        XCTAssertTrue(ModelRouter.isPaidCloud(AIModel.cloudCatalog.first { $0.alias == "opus" }!))
        XCTAssertTrue(ModelRouter.isPaidCloud(claudeLogin), "Claude through your login counts")
        XCTAssertFalse(ModelRouter.isPaidCloud(gemini))
        XCTAssertFalse(ModelRouter.isPaidCloud(localQwen))
        XCTAssertEqual(Provider.xai.baseURL.absoluteString, "https://api.x.ai/v1")
        XCTAssertTrue(Provider.builtIn.contains(Provider.xai))
    }

    func testOnPaidModelsLeadEvenForAgentsThatPreferPrivate() throws {
        var privateAgent = engineer
        privateAgent.preferLocal = true
        XCTAssertTrue(try route([localQwen, localCoder, grok], cloud: false, agent: privateAgent).model.isLocal, "off: local first")
        let on = try route([localQwen, localCoder, grok], cloud: true, agent: privateAgent)
        XCTAssertEqual(on.model.id, grok.id)
        XCTAssertTrue(on.reason.contains("cloud models on"), on.reason)
    }

    func testTheAgentsKindStillPicksAmongThem() throws {
        let decision = try route([localCoder, claudeLogin, grok, gpt], cloud: true, "fix this bug in my swift code", agent: engineer)
        XCTAssertTrue(ModelRouter.isPaidCloud(decision.model))
        XCTAssertTrue(decision.model.capabilities.contains(.coding))
    }

    func testNothingConnectedChangesNothing() throws {
        let router = ModelRouter(available: [localQwen, gemini], settings: .init(), cloudFirst: true)
        XCTAssertFalse(router.cloudActive)
        XCTAssertEqual(try route([localQwen], cloud: true).model.id, localQwen.id)
    }

    func testSensitiveMessagesStillStayLocal() throws {
        XCTAssertEqual(try route([localQwen, grok], cloud: true, "here is my bank account and password").model.id, localQwen.id)
    }

    @MainActor
    func testTheSwitchIsRemembered() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        let before = UserDefaults.standard.bool(forKey: "cloudModelsFirst")
        defer { UserDefaults.standard.set(before, forKey: "cloudModelsFirst") }
        store.cloudModelsFirst = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "cloudModelsFirst"))
        store.cloudModelsFirst = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "cloudModelsFirst"))
    }
}
