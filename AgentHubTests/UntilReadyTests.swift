import XCTest
@testable import AgentHub

/// Group chats that keep working until it's ready and everyone agrees, within the limits from Settings.
final class UntilReadyTests: XCTestCase {
    /// Answers from a script: each call gets the next reply (repeating the last one).
    private final class ScriptedClient: ChatClient, @unchecked Sendable {
        private var replies: [String]
        private let lock = NSLock()
        private(set) var prompts: [String] = []
        /// The members' turns (when it ends, the notification's summary is asked of a model too).
        var turns: [String] { prompts.filter { $0.contains("You're in a group chat") } }
        init(_ replies: [String]) { self.replies = replies }

        func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            prompts.append(request.messages.last?.content ?? "")
            let reply = replies.count > 1 ? replies.removeFirst() : replies.first ?? ""
            lock.unlock()
            return AsyncThrowingStream { continuation in
                continuation.yield(reply)
                continuation.finish()
            }
        }
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "discussionMaxDisagreements")
        UserDefaults.standard.removeObject(forKey: "discussionMaxMinutes")
    }

    @MainActor
    private func group(_ client: ScriptedClient) -> (AppStore, Conversation) {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        let server = LocalServer(name: "Test", baseURL: URL(string: "http://localhost:1")!)
        store.servers = [server]
        store.serverModels = [AIModel.server(ServerModelInfo(id: "ollama/test-model:4b", kind: "chat", size_bytes: nil,
                                                             parameter_size: "4B", loaded: true), on: server)]
        store.markOnline(server.id, system: nil)
        store.clientOverride = { _ in client }
        let cto = Agent(name: "CTO", emoji: "", summary: "", systemPrompt: "")
        let cmo = Agent(name: "CMO", emoji: "", summary: "", systemPrompt: "")
        store.agents = [cto, cmo]
        return (store, store.newMeeting(with: [cto, cmo]))
    }

    @MainActor
    private func waitUntilDone(_ store: AppStore, _ id: UUID) {
        let deadline = Date().addingTimeInterval(10)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        while store.isStreaming(id) && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    @MainActor
    private func texts(_ store: AppStore, _ id: UUID) -> [String] {
        store.conversations.first { $0.id == id }!.messages.map(\.content)
    }

    func testDefaultsAreTwentyDisagreementsOrFourHours() {
        XCTAssertEqual(AppStore.maxDisagreements, 20)
        XCTAssertEqual(AppStore.maxDiscussionMinutes, 240)
        UserDefaults.standard.set(3, forKey: "discussionMaxDisagreements")
        UserDefaults.standard.set(90, forKey: "discussionMaxMinutes")
        XCTAssertEqual(AppStore.maxDisagreements, 3)
        XCTAssertEqual(AppStore.maxDiscussionMinutes, 90)
        XCTAssertEqual(AppStore.duration(minutes: 240), "4 h")
        XCTAssertEqual(AppStore.duration(minutes: 90), "1 h 30 min")
        XCTAssertEqual(AppStore.duration(minutes: 45), "45 min")
    }

    @MainActor
    func testNewGroupsWorkUntilReady() {
        let (_, chat) = group(ScriptedClient(["ok"]))
        XCTAssertEqual(chat.discussionRounds, AppStore.maxRounds)
    }

    @MainActor
    func testTheyKeepGoingUntilEveryoneAgreesThenWriteTheResult() {
        // Round 1: both answer. Rounds 2–3: still improving (2 disagreements). Round 4: both PASS. Then the final result.
        let client = ScriptedClient(["Draft A", "Draft B", "Better A", "Better B", "Even better", "Fixed", "PASS", "PASS",
                                     "THE FINISHED PLAN"])
        let (store, chat) = group(client)
        store.sendToMeeting("Write our launch plan", in: chat.id)
        XCTAssertNotNil(store.discussions[chat.id], "the progress bar shows while they work")
        waitUntilDone(store, chat.id)
        let messages = texts(store, chat.id)
        XCTAssertTrue(messages.contains("Everyone agreed after 4 rounds and 2 disagreements."), messages.joined(separator: " | "))
        XCTAssertEqual(messages.last, "THE FINISHED PLAN")
        XCTAssertFalse(messages.contains("PASS"), "agreeing leaves no empty bubbles")
        XCTAssertTrue(client.turns.contains { $0.contains("only when the result is ready and you fully agree") })
        XCTAssertTrue(client.turns.last?.contains("write the FINISHED result") ?? false)
        XCTAssertNil(store.discussions[chat.id])
    }

    @MainActor
    func testTheyStopAtTheDisagreementLimitAndHandOverTheBestVersion() {
        UserDefaults.standard.set(3, forKey: "discussionMaxDisagreements")
        let client = ScriptedClient(["I disagree"])  // never agrees
        let (store, chat) = group(client)
        store.sendToMeeting("Pick a name", in: chat.id)
        waitUntilDone(store, chat.id)
        let messages = texts(store, chat.id)
        XCTAssertTrue(messages.contains("Stopped at the limit of 3 disagreements without full agreement."))
        // Round 1 + 3 disagreeing rounds, 2 members each, then the lead's best version.
        XCTAssertEqual(client.turns.count, 4 * 2 + 1)
        XCTAssertTrue(client.turns.last?.contains("what's still disputed") ?? false)
    }

    @MainActor
    func testYouCanStopIt() {
        let client = ScriptedClient(["I disagree"])
        let (store, chat) = group(client)
        store.sendToMeeting("Pick a name", in: chat.id)
        store.stopDiscussion(chat.id)
        waitUntilDone(store, chat.id)
        XCTAssertTrue(texts(store, chat.id).contains { $0.hasPrefix("You stopped the discussion") })
    }

    @MainActor
    func testNoModelsMeansItStopsInsteadOfSpinning() {
        let (store, chat) = group(ScriptedClient(["x"]))
        store.clientOverride = { _ in nil }
        store.sendToMeeting("Pick a name", in: chat.id)
        waitUntilDone(store, chat.id)
        XCTAssertTrue(texts(store, chat.id).contains { $0.hasPrefix("The discussion stopped: no member could answer") })
    }

    @MainActor
    func testFixedRoundsStillWork() {
        let client = ScriptedClient(["I disagree"])
        let (store, chat) = group(client)
        store.setDiscussionRounds(2, in: chat.id)
        store.sendToMeeting("Pick a name", in: chat.id)
        waitUntilDone(store, chat.id)
        XCTAssertEqual(client.turns.count, 4, "2 rounds × 2 members, no final turn")
        XCTAssertNil(store.discussions[chat.id])
    }
}
