import XCTest
@testable import AgentHub

/// Messages sent while a chat is answering wait their turn, then go out in order.
final class QueueTests: XCTestCase {
    /// A remote agent on a closed port: each reply starts, then fails fast, which ends it.
    @MainActor
    private func storeWithChat() -> (AppStore, Conversation) {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        var agent = Agent(name: "Echo", emoji: "🔁", summary: "", systemPrompt: "")
        agent.kind = .remote(endpoint: URL(string: "http://127.0.0.1:9/v1/chat/completions")!, model: "x")
        store.agents = [agent]
        return (store, store.newConversation(agent: agent))
    }

    @MainActor
    func testMessagesQueueWhileAnsweringAndGoOutInOrder() {
        let (store, chat) = storeWithChat()
        store.submit("one", in: chat.id)
        XCTAssertTrue(store.isStreaming(chat.id))
        store.submit("two", in: chat.id)
        store.submit("three", in: chat.id)
        XCTAssertEqual(store.queuedMessages[chat.id]?.map(\.text), ["two", "three"])

        func sent() -> [String] {
            store.conversations.first { $0.id == chat.id }!.messages.filter { $0.role == .user }.map(\.content)
        }
        let deadline = Date().addingTimeInterval(10)
        while (sent().count < 3 || store.isStreaming(chat.id)) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(sent(), ["one", "two", "three"], "each waits for the reply before it")
        XCTAssertNil(store.queuedMessages[chat.id])
    }

    @MainActor
    func testQueuedMessagesCanBeRemovedOrTakenBack() {
        let (store, chat) = storeWithChat()
        store.submit("one", in: chat.id)
        store.submit("two", in: chat.id)
        store.submit("three", in: chat.id)
        let queued = store.queuedMessages[chat.id]!
        store.removeQueued(queued[0].id, in: chat.id)
        XCTAssertEqual(store.takeQueued(queued[1].id, in: chat.id)?.text, "three")
        XCTAssertTrue(store.queuedMessages[chat.id]?.isEmpty ?? true)
        store.deleteConversation(chat.id)
        XCTAssertNil(store.queuedMessages[chat.id])
    }
}
