import XCTest
@testable import AgentHub

final class ServerRoutingTests: XCTestCase {
    private let server = LocalServer(name: "Mac", baseURL: URL(string: "http://mac.local:8765")!)
    private let opus = AIModel.cloudCatalog.first { $0.alias == "opus" }!
    private let haiku = AIModel.cloudCatalog.first { $0.alias == "haiku" }!
    private let phone = AIModel.suggestedLocal[0]

    private var llama8b: AIModel {
        .server(ServerModelInfo(id: "ollama/llama3.1:8b", kind: "chat", size_bytes: nil, parameter_size: "8.0B", loaded: nil), on: server)
    }
    private var ltxVideo: AIModel {
        .server(ServerModelInfo(id: "ltx/video", kind: "video", size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
    }
    private var ltxImage: AIModel {
        .server(ServerModelInfo(id: "ltx/image", kind: "image", size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
    }

    private func route(_ text: String, _ models: [AIModel], online: Bool = true) throws -> RoutingDecision {
        try ModelRouter(available: models, settings: .init()).route(RoutingRequest(text: text, isOnline: online))
    }

    private func agent(_ name: String) -> AIModel {
        .server(ServerModelInfo(id: "local/\(name)", kind: "agent", size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
    }

    func testLocalClaudeCodeThenCodexAnswerWhenNoModelIsUp() throws {
        let decision = try route("Write a tagline for my bakery", [ltxImage, agent("codex"), agent("claude-code")])
        XCTAssertEqual(decision.model.modelName, "local/claude-code", "Claude Code first")
        XCTAssertEqual(decision.fallbacks.map(\.modelName), ["local/codex"], "then Codex (ChatGPT)")
        XCTAssertTrue(decision.reason.contains("No local model is running"))
        // With a chat model up, the agents stay explicit-only (@claude).
        XCTAssertEqual(try route("Write a tagline for my bakery", [llama8b, agent("claude-code")]).model.id, llama8b.id)
        XCTAssertThrowsError(try route("Write a tagline", [ltxImage]))
    }

    func testClaudeThroughTheLoginIsARealChatModel() throws {
        let sonnet = AIModel.server(ServerModelInfo(id: "claude/sonnet", kind: "claude", size_bytes: nil, parameter_size: nil,
                                                    loaded: nil, name: "Claude Sonnet (your Claude login)"), on: server)
        XCTAssertFalse(sonnet.isExplicitOnly, "not just @-only: it can answer like an API model")
        XCTAssertTrue(sonnet.capabilities.contains(.coding))
        XCTAssertEqual(try route("@sonnet refactor this function", [llama8b, sonnet]).model.id, sonnet.id)
        XCTAssertEqual(try route("Write a tagline", [sonnet, agent("claude-code")]).model.id, sonnet.id,
                       "no local model: Claude via the login answers, no API key needed")
    }

    func testVideoRequestGoesToLTX() throws {
        let decision = try route("Make a video of a fox running through snow at dawn", [opus, haiku, llama8b, ltxVideo, ltxImage])
        XCTAssertEqual(decision.model.id, ltxVideo.id)
        XCTAssertTrue(decision.fallbacks.allSatisfy { $0.capabilities.contains(.video) })
    }

    func testImageRequestGoesToLTXImage() throws {
        let decision = try route("Draw a cozy coffee shop poster", [opus, ltxVideo, ltxImage])
        XCTAssertEqual(decision.model.id, ltxImage.id)
    }

    func testTextNeverGoesToMediaModels() throws {
        let decision = try route("hello there", [ltxVideo, ltxImage, haiku])
        XCTAssertEqual(decision.model.id, haiku.id)
        XCTAssertFalse(decision.fallbacks.contains { $0.isMedia })
    }

    func testMediaRequestWithoutMediaModelAnswersInText() throws {
        let decision = try route("make a video of a sunset", [opus, haiku])
        XCTAssertFalse(decision.model.isMedia)
        XCTAssertNotEqual(decision.profile.primary, .video)
    }

    func testSensitivePromptCanUseOwnServer() throws {
        let decision = try route("Analyze my bank account statements step by step", [opus, llama8b])
        XCTAssertEqual(decision.model.id, llama8b.id)
        XCTAssertTrue(decision.reason.contains("server"))
    }

    func testOfflineSkipsServers() throws {
        let decision = try route("hi", [llama8b, phone], online: false)
        XCTAssertEqual(decision.model.id, phone.id)
        XCTAssertThrowsError(try route("hi", [llama8b], online: false))
    }

    func testAliasPicksServerModel() throws {
        let decision = try route("@llama3.1 hi", [opus, llama8b])
        XCTAssertEqual(decision.model.id, llama8b.id)
    }

    func testReadableNames() {
        let (hfName, hfTag) = AIModel.readableName("ollama/hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M")
        XCTAssertEqual(hfName, "Qwen3-4B-Instruct-2507")
        XCTAssertNil(hfTag)
        XCTAssertEqual(AIModel.readableName("ollama/qwen2.5-coder:14b").tag, "14b")
        XCTAssertNil(AIModel.readableName("ollama/llama3.2:latest").tag)

        let qwen = AIModel.server(ServerModelInfo(
            id: "ollama/hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M", kind: nil, size_bytes: nil,
            parameter_size: "4.0B", loaded: nil), on: server)
        XCTAssertEqual(qwen.displayName, "Qwen3 4B Instruct 2507")
        XCTAssertEqual(qwen.alias, "qwen3-4b-instruct-2507")  // same alias the gateway uses
    }

    func testServerModelHeuristics() {
        XCTAssertEqual(llama8b.qualityTier, 3)
        XCTAssertEqual(llama8b.costTier, 0)
        XCTAssertTrue(llama8b.isLocal)
        XCTAssertFalse(llama8b.isOnDevice)
        XCTAssertEqual(llama8b.locationSymbol, "desktopcomputer")

        let coder = AIModel.server(
            ServerModelInfo(id: "ollama/qwen2.5-coder:32b", kind: nil, size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
        XCTAssertTrue(coder.capabilities.contains(.coding))
        XCTAssertEqual(coder.qualityTier, 4)
        XCTAssertTrue(ltxVideo.isMedia)
    }

    func testParameterParsing() {
        XCTAssertEqual(AIModel.parameterBillions("8.0B"), 8)
        XCTAssertEqual(AIModel.parameterBillions("751.63M")!, 0.75163, accuracy: 0.001)
        XCTAssertEqual(AIModel.parameterBillions("qwen2.5-coder:14b"), 14)
        XCTAssertNil(AIModel.parameterBillions("llama3.2"))
    }

    func testOpenAIBaseURL() {
        XCTAssertEqual(server.openAIBaseURL.absoluteString, "http://mac.local:8765/v1")
        let ollama = LocalServer(name: "Ollama", baseURL: URL(string: "http://mac.local:11434/v1")!, kind: .openAICompatible)
        XCTAssertEqual(ollama.openAIBaseURL.absoluteString, "http://mac.local:11434/v1")
    }
}
