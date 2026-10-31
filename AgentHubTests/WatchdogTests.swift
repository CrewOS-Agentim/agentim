import XCTest
@testable import AgentHub

/// A model that stops responding is cut off, and the agent switches to another model.
final class WatchdogTests: XCTestCase {
    /// Never says anything (until cancelled).
    private struct SilentClient: ChatClient {
        func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { _ in }
        }
    }

    /// Starts answering, then goes quiet.
    private struct StallingClient: ChatClient {
        func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in continuation.yield("The answer is") }
        }
    }

    private struct AnsweringClient: ChatClient {
        let text: String
        func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    override func setUp() {
        UserDefaults.standard.set(1, forKey: "modelFirstReplyTimeout")
        UserDefaults.standard.set(1, forKey: "modelStallTimeout")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "modelFirstReplyTimeout")
        UserDefaults.standard.removeObject(forKey: "modelStallTimeout")
    }

    private let server = LocalServer(name: "Test", baseURL: URL(string: "http://localhost:1")!)
    private func model(_ id: String) -> AIModel {
        AIModel.server(ServerModelInfo(id: id, kind: "chat", size_bytes: nil, parameter_size: "8B", loaded: true), on: server)
    }

    func testLimitsPerKindOfModel() {
        XCTAssertEqual(ModelWatchdog.limits(for: model("ollama/qwen3:8b")), .init(firstReply: 1, stall: 1))
        XCTAssertEqual(ModelWatchdog.limits(for: model("claude/sonnet"))?.firstReply, 240, "answers all at once")
        XCTAssertEqual(ModelWatchdog.limits(for: model("lora/x:qwen3.5-9b"))?.firstReply, 240, "loads first")
        let video = AIModel.server(ServerModelInfo(id: "ltx/video", kind: "video", size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
        XCTAssertNil(ModelWatchdog.limits(for: video), "renders take minutes")
        UserDefaults.standard.removeObject(forKey: "modelFirstReplyTimeout")
        UserDefaults.standard.removeObject(forKey: "modelStallTimeout")
        XCTAssertEqual(ModelWatchdog.standard, .init(firstReply: 90, stall: 45), "the defaults")
    }

    func testSilenceAndStallsTimeOut() async {
        let limits = ModelWatchdog.Limits(firstReply: 0.5, stall: 0.5)
        do {
            try await ModelWatchdog.watch(SilentClient().stream(ChatRequest(model: "", system: "", messages: [])), limits: limits) { _ in }
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? ModelWatchdog.Timeout, .noReply(0.5))
        }
        do {
            try await ModelWatchdog.watch(StallingClient().stream(ChatRequest(model: "", system: "", messages: [])), limits: limits) { _ in }
            XCTFail("should time out")
        } catch {
            XCTAssertEqual(error as? ModelWatchdog.Timeout, .stalled(0.5))
        }
        var got = ""
        try? await ModelWatchdog.watch(AnsweringClient(text: "hi").stream(ChatRequest(model: "", system: "", messages: [])),
                                       limits: limits) { got += $0 }
        XCTAssertEqual(got, "hi")
    }

    @MainActor
    func testTheAgentSwitchesToAnotherModelAndSkipsTheSlowOneNextTime() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        let slow = model("ollama/slow-model:8b"), fast = model("ollama/fast-model:8b")
        store.servers = [server]
        store.serverModels = [slow, fast]
        store.markOnline(server.id, system: nil)
        store.clientOverride = { model in model.id == slow.id ? StallingClient() as ChatClient : AnsweringClient(text: "Here you go") }
        var agent = Agent(name: "Helper", emoji: "", summary: "", systemPrompt: "")
        agent.modelPreference = .pinned(slow.id)
        store.agents = [agent]
        let chat = store.newConversation(agent: agent)

        func ask(_ text: String) -> ChatMessage? {
            store.send(text, in: chat.id)
            let deadline = Date().addingTimeInterval(8)
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            while store.isStreaming(chat.id) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return store.conversations.first { $0.id == chat.id }?.messages.last
        }

        let first = ask("hello")
        XCTAssertEqual(first?.content, "Here you go", "started over with the other model, no half answer left")
        XCTAssertEqual(first?.modelID, fast.id)
        XCTAssertTrue(first?.routingReason?.contains("stopped responding") ?? false, first?.routingReason ?? "")
        XCTAssertTrue(store.isUnresponsive(slow.id))

        let second = ask("again")
        XCTAssertEqual(second?.modelID, fast.id, "the slow model is tried last for a while")
        XCTAssertEqual(store.deprioritizingUnresponsive([slow, fast]).map(\.id), [fast.id, slow.id])
    }
}
