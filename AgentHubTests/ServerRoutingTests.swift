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
        let decision = try route("@llama3.1-8b hi", [opus, llama8b])
        XCTAssertEqual(decision.model.id, llama8b.id)
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
