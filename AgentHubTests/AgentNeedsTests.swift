import XCTest
@testable import AgentHub

/// Agents get models that fit their work: no LTX for a Data Analyst, reasoning for analysts, coding for engineers.
final class AgentNeedsTests: XCTestCase {
    private let server = LocalServer(name: "Mac", baseURL: URL(string: "http://localhost:8766")!)
    private lazy var ltxImage = AIModel.server(ServerModelInfo(id: "ltx/image", kind: "image", size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
    private lazy var ltxVideo = AIModel.server(ServerModelInfo(id: "ltx/video", kind: "video", size_bytes: nil, parameter_size: nil, loaded: nil), on: server)
    private let sonnet = AIModel.cloudCatalog.first { $0.alias == "sonnet" }!
    private let haiku = AIModel.cloudCatalog.first { $0.alias == "haiku" }!
    private let analyst = Agent(name: "Data Analyst", emoji: "", summary: "Sets up your metrics, tracking and dashboards, then tells you what the numbers say to do next.", systemPrompt: "")
    private let youtube = Agent(name: "YouTube Creator", emoji: "", summary: "Plans, scripts and grows your YouTube channel.", systemPrompt: "")
    private let engineer = Agent(name: "Software Engineer", emoji: "", summary: "Pair programmer for design, debugging and code review.", systemPrompt: "")
    private let tim = Agent(name: "Agent Tim", emoji: "", summary: "The switchboard octopus. Helpful, quick, a little goofy. Knows every skill.", systemPrompt: "")

    private func route(_ text: String, _ agent: Agent?) throws -> RoutingDecision {
        try ModelRouter(available: [haiku, sonnet, ltxImage, ltxVideo], settings: .init()).route(RoutingRequest(text: text, agent: agent))
    }

    func testNeedsComeFromTheJob() {
        XCTAssertEqual(AgentNeeds.of(analyst), AgentNeeds(primary: .reasoning, makesMedia: false))
        XCTAssertEqual(AgentNeeds.of(engineer), AgentNeeds(primary: .coding, makesMedia: false))
        XCTAssertEqual(AgentNeeds.of(youtube).makesMedia, true)
        XCTAssertEqual(AgentNeeds.of(tim), .anything, "a generalist fits anything")
        XCTAssertEqual(AgentNeeds.of(nil), .anything)
        XCTAssertFalse(AgentNeeds.of(name: "CTO", summary: "Architecture, build vs. buy, delivery speed").makesMedia)
        XCTAssertEqual(AgentNeeds.of(name: "Product Manager", summary: "Turns fuzzy ideas into specs").primary, .reasoning)
    }

    func testADataAnalystNeverGetsLTX() throws {
        for text in ["make an image of our funnel", "draw a picture of churn by month", "make a video of signups"] {
            let decision = try route(text, analyst)
            XCTAssertFalse(decision.model.isMedia, text)
            XCTAssertEqual(decision.profile.primary, .reasoning, text)
        }
    }

    func testMediaAgentsAndExplicitCommandsStillRender() throws {
        XCTAssertEqual(try route("make a video of an octopus surfing", youtube).model.id, ltxVideo.id)
        XCTAssertEqual(try route("make an image of an octopus", tim).model.id, ltxImage.id, "Agent Tim can make pictures")
        XCTAssertEqual(try route("/image churn by month as a poster", analyst).model.id, ltxImage.id, "you asked for it")
        XCTAssertEqual(try route("@ltx-image anything", analyst).model.id, ltxImage.id)
    }

    func testQuickQuestionsGoToTheKindOfModelTheAgentNeeds() throws {
        XCTAssertEqual(try route("how was churn?", analyst).profile.primary, .reasoning)
        XCTAssertEqual(try route("hey", engineer).profile.primary, .coding)
        XCTAssertEqual(try route("hey", tim).profile.primary, .fast, "a generalist keeps the quick path")
    }

    func testDrawingConclusionsIsNotAPicture() {
        XCTAssertNotEqual(PromptClassifier.classify("draw conclusions from the survey").primary, .image)
        XCTAssertNotEqual(PromptClassifier.classify("illustrate the trade-offs").primary, .image)
        XCTAssertEqual(PromptClassifier.classify("draw a fox in a hat").primary, .image)
    }

    func testGroupChatsReadTheTaskNotTheTranscript() throws {
        // A member said "image of" and "@CTO" in the transcript; the task is a plan, and @CTO is a member, not a model.
        let prompt = "Here's the conversation so far:\n\nCMO: picture of our hero image of the launch @CTO thoughts?\n\nReply now as Data Analyst."
        let decision = try ModelRouter(available: [haiku, sonnet, ltxImage], settings: .init()).route(
            RoutingRequest(text: prompt, agent: tim, taskText: "Plan our launch metrics", parseOverride: false))
        XCTAssertFalse(decision.model.isMedia)
        XCTAssertEqual(decision.profile.primary, .reasoning)
        XCTAssertGreaterThan(decision.profile.estimatedTokens, 20, "sized on the whole prompt")
    }

    @MainActor
    func testEachMemberGetsAModelForItsWork() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        let coder = AIModel.server(ServerModelInfo(id: "ollama/qwen2.5-coder:14b", kind: "chat", size_bytes: nil, parameter_size: "14B", loaded: true), on: server)
        let thinker = AIModel.server(ServerModelInfo(id: "ollama/deepseek-r1:14b", kind: "chat", size_bytes: nil, parameter_size: "14B", loaded: true), on: server)
        store.servers = [server]
        store.serverModels = [coder, thinker, ltxImage, ltxVideo]
        store.markOnline(server.id, system: nil)
        store.agents = [engineer, analyst]
        let group = store.newMeeting(with: [engineer, analyst])
        store.setAutoDivide(true, in: group.id)
        let conversation = store.conversations.first { $0.id == group.id }!
        let members = store.members(in: conversation)
        XCTAssertEqual(store.model(for: members[0], in: conversation)?.id, coder.id, "the engineer codes")
        XCTAssertEqual(store.model(for: members[1], in: conversation)?.id, thinker.id, "the analyst reasons")
    }
}
