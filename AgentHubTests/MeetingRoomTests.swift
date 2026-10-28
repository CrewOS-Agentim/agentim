import XCTest
@testable import AgentHub

final class MeetingRoomTests: XCTestCase {
    private let cto = Agent(name: "CTO", emoji: "🧠", summary: "", systemPrompt: "")
    private let cmo = Agent(name: "CMO", emoji: "📣", summary: "", systemPrompt: "")
    private let qa = Agent(name: "QA Engineer", emoji: "🐞", summary: "", systemPrompt: "")

    func testEveryoneAnswersUnlessSomeoneIsTagged() {
        let room = [cto, cmo, qa]
        XCTAssertEqual(AppStore.addressed("How should we launch?", among: room).map(\.name), ["CTO", "CMO", "QA Engineer"])
        XCTAssertEqual(AppStore.addressed("@cto can we ship Friday?", among: room).map(\.name), ["CTO"])
        XCTAssertEqual(AppStore.addressed("@CMO and @QA, thoughts?", among: room).map(\.name), ["CMO", "QA Engineer"])
        XCTAssertEqual(AppStore.addressed("@qa-engineer test it", among: room).map(\.name), ["QA Engineer"], "full name works too")
        XCTAssertEqual(AppStore.addressed("@nobody hi", among: room).count, 3, "an unknown tag falls back to everyone")
    }

    func testSpeakerPrefixIsDropped() {
        XCTAssertEqual(AppStore.withoutSpeakerPrefix("CTO: Ship it Friday.", name: "CTO"), "Ship it Friday.")
        XCTAssertEqual(AppStore.withoutSpeakerPrefix("**CTO:** Ship it.", name: "CTO"), "Ship it.")
        XCTAssertEqual(AppStore.withoutSpeakerPrefix("Ship it.", name: "CTO"), "Ship it.")
    }

    @MainActor
    func testRoomMembersAndTranscript() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        store.agents = [cto, cmo, qa]
        let meeting = store.newMeeting(with: [cto, cmo])
        XCTAssertTrue(meeting.isMeeting)
        XCTAssertEqual(meeting.title, "Meeting: CTO, CMO")
        XCTAssertEqual(store.participants(in: meeting).map(\.name), ["CTO", "CMO"])
        store.setParticipants([cto.id, cmo.id, qa.id], in: meeting.id)
        let updated = store.conversations.first { $0.id == meeting.id }!
        XCTAssertEqual(store.participants(in: updated).count, 3)

        let empty = store.newMeeting(with: [])
        XCTAssertTrue(empty.isMeeting, "an empty room is still a meeting (pick who joins)")
        XCTAssertFalse(store.newConversation(agent: cto).isMeeting)

        var withMessages = updated
        withMessages.messages = [ChatMessage(role: .user, content: "Launch plan?"),
                                 ChatMessage(role: .assistant, content: "Ship Friday.", agentID: cto.id)]
        let transcript = store.transcript(withMessages)
        XCTAssertTrue(transcript.contains("You (the founder): Launch plan?"))
        XCTAssertTrue(transcript.contains("CTO: Ship Friday."))
    }

    func testOldConversationsStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"Old","agentID":"6F9619FF-8B86-D011-B42D-00C04FC964FE","messages":[],"updatedAt":0}"#
        let conversation = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        XCTAssertFalse(conversation.isMeeting)
    }
}
