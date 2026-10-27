import XCTest
@testable import AgentHub

final class RouterTests: XCTestCase {
    private let opus = AIModel.cloudCatalog.first { $0.alias == "opus" }!
    private let haiku = AIModel.cloudCatalog.first { $0.alias == "haiku" }!
    private let qwenCoder = AIModel.cloudCatalog.first { $0.alias == "qwencoder" }!
    private let local = AIModel.suggestedLocal[0]

    private func router(_ models: [AIModel], _ settings: RouterSettings = .init()) -> ModelRouter {
        ModelRouter(available: models, settings: settings)
    }

    func testAliasOverrideWinsAndIsStripped() throws {
        let decision = try router([opus, haiku]).route(RoutingRequest(text: "@opus hi there"))
        XCTAssertEqual(decision.model.id, opus.id)
        XCTAssertEqual(decision.cleanedText, "hi there")
    }

    func testUnknownAliasThrows() {
        XCTAssertThrowsError(try router([haiku]).route(RoutingRequest(text: "@nope hello"))) {
            XCTAssertEqual($0 as? RoutingError, .unknownOverride("nope"))
        }
    }

    func testEmailAddressIsNotAnOverride() throws {
        let decision = try router([haiku]).route(RoutingRequest(text: "email bob@example.com"))
        XCTAssertEqual(decision.cleanedText, "email bob@example.com")
    }

    func testConversationPinBeatsAgentPin() throws {
        var agent = Agent.defaults[0]
        agent.modelPreference = .pinned(haiku.id)
        let decision = try router([opus, haiku]).route(
            RoutingRequest(text: "hi", agent: agent, conversationPin: opus.id))
        XCTAssertEqual(decision.model.id, opus.id)
    }

    func testQuickQuestionGoesToCheapFastModel() throws {
        let decision = try router([opus, haiku]).route(RoutingRequest(text: "what's the capital of France?"))
        XCTAssertEqual(decision.model.id, haiku.id)
    }

    func testCodingTaskGoesToStrongCoder() throws {
        let prompt = "Refactor this Swift function so it doesn't crash:\n```swift\nfunc load() { try! data() }\n```"
        let decision = try router([haiku, opus, local]).route(RoutingRequest(text: prompt))
        XCTAssertTrue(decision.model.capabilities.contains(.coding))
        XCTAssertNotEqual(decision.model.id, local.id)
        XCTAssertEqual(decision.profile.primary, .coding)
    }

    func testQualityModePrefersStrongestModel() throws {
        var settings = RouterSettings()
        settings.priority = .quality
        let decision = try router([haiku, opus, qwenCoder], settings).route(
            RoutingRequest(text: "Analyze the trade-offs of event sourcing for a payments ledger in depth."))
        XCTAssertEqual(decision.model.id, opus.id)
    }

    func testOfflineUsesLocal() throws {
        let decision = try router([opus, local]).route(RoutingRequest(text: "hello", isOnline: false))
        XCTAssertEqual(decision.model.id, local.id)
        XCTAssertTrue(decision.fallbacks.allSatisfy(\.isLocal))
    }

    func testOfflineWithoutLocalThrows() {
        XCTAssertThrowsError(try router([opus]).route(RoutingRequest(text: "hello", isOnline: false)))
    }

    func testSensitivePromptStaysLocal() throws {
        let decision = try router([opus, local]).route(RoutingRequest(text: "my bank account password is hunter2"))
        XCTAssertEqual(decision.model.id, local.id)
    }

    func testSensitivePromptCanGoToCloudWhenDisabled() throws {
        var settings = RouterSettings()
        settings.keepSensitiveLocal = false
        let prompt = "Analyze my salary negotiation strategy step by step and compare the options."
        XCTAssertTrue(PromptClassifier.classify(prompt).isSensitive)
        let decision = try router([opus, local], settings).route(RoutingRequest(text: prompt))
        XCTAssertFalse(decision.model.isLocal)
    }

    func testLongContextExcludesSmallWindows() throws {
        let history = [ChatMessage(role: .user, content: String(repeating: "word ", count: 30_000))]
        let decision = try router([local, opus]).route(RoutingRequest(text: "summarize all of it", history: history))
        XCTAssertEqual(decision.model.id, opus.id)
        XCTAssertFalse(decision.fallbacks.contains { $0.id == local.id })
    }

    func testNoModelsThrows() {
        XCTAssertThrowsError(try router([]).route(RoutingRequest(text: "hi"))) {
            XCTAssertEqual($0 as? RoutingError, .noModelsAvailable)
        }
    }

    func testAgentPreferLocal() throws {
        let agent = Agent.defaults.first { $0.preferLocal }!
        let decision = try router([opus, local]).route(RoutingRequest(text: "jot this down", agent: agent))
        XCTAssertEqual(decision.model.id, local.id)
    }
}

final class ClassifierTests: XCTestCase {
    func testPlainEnglishIsNotCode() {
        XCTAssertNotEqual(PromptClassifier.classify("let me know when you're free for lunch").primary, .coding)
    }

    func testCardNumberIsSensitive() {
        XCTAssertTrue(PromptClassifier.classify("charge 4111 1111 1111 1111").isSensitive)
    }

    func testCreative() {
        XCTAssertEqual(PromptClassifier.classify("Write a short poem about autumn in Tel Aviv for my mom").primary, .creative)
    }
}

final class MemoryTests: XCTestCase {
    private let gb: Int64 = 1_024 * 1_024 * 1_024

    func testSmallModelFits() {
        let result = DeviceMemory.assess(weightBytes: gb, available: 4 * gb, ceiling: 5 * gb, freeDisk: 50 * gb)
        XCTAssertEqual(result.verdict, .fits)
        XCTAssertTrue(result.canDownload)
    }

    func testModelLargerThanDeviceIsRejected() {
        let result = DeviceMemory.assess(weightBytes: 8 * gb, available: 4 * gb, ceiling: 5 * gb, freeDisk: 50 * gb)
        XCTAssertEqual(result.verdict, .tooLarge)
        XCTAssertFalse(result.canDownload)
    }

    func testTightWhenOtherAppsHoldMemory() {
        let result = DeviceMemory.assess(weightBytes: 3 * gb, available: 2 * gb, ceiling: 5 * gb, freeDisk: 50 * gb)
        XCTAssertEqual(result.verdict, .tight)
        XCTAssertTrue(result.canDownload)
    }

    func testNotEnoughDisk() {
        let result = DeviceMemory.assess(weightBytes: 2 * gb, available: 4 * gb, ceiling: 5 * gb, freeDisk: gb)
        XCTAssertEqual(result.verdict, .notEnoughDisk)
        XCTAssertFalse(result.canDownload)
    }

    func testRequiredIncludesOverhead() {
        XCTAssertGreaterThan(DeviceMemory.requiredBytes(weightBytes: gb), gb)
    }

    func testRuntimeFileFilterAndWeights() {
        let files = [
            HuggingFaceClient.RepoFile(type: "file", path: "model.safetensors", size: 100),
            HuggingFaceClient.RepoFile(type: "file", path: "config.json", size: 1),
            HuggingFaceClient.RepoFile(type: "file", path: "README.md", size: 5),
            HuggingFaceClient.RepoFile(type: "file", path: ".gitattributes", size: 1),
        ]
        let runtime = HuggingFaceClient.runtimeFiles(files)
        XCTAssertEqual(runtime.map(\.path), ["model.safetensors", "config.json"])
        XCTAssertEqual(HuggingFaceClient.weightBytes(runtime), 100)
    }
}

final class SkillTests: XCTestCase {
    func testParseFrontMatter() throws {
        let skill = try XCTUnwrap(Skill.parse(markdown: """
        ---
        name: Release Notes
        description: "Write release notes"
        triggers: changelog, release notes
        ---
        Group changes by feature.
        """))
        XCTAssertEqual(skill.name, "Release Notes")
        XCTAssertEqual(skill.summary, "Write release notes")
        XCTAssertEqual(skill.triggers, ["changelog", "release notes"])
        XCTAssertEqual(skill.instructions, "Group changes by feature.")
        XCTAssertEqual(skill.slug, "release-notes")
    }

    func testParseRejectsMissingName() {
        XCTAssertNil(Skill.parse(markdown: "---\ndescription: x\n---\nbody"))
        XCTAssertNil(Skill.parse(markdown: "no front matter"))
    }

    func testMatchesTriggerAndSlash() {
        let skill = Skill(name: "Code Review", summary: "", instructions: "", triggers: ["diff"])
        XCTAssertTrue(skill.matches("please look at this DIFF"))
        XCTAssertTrue(skill.matches("/code-review now"))
        XCTAssertFalse(skill.matches("hello"))
    }

    @MainActor
    func testSystemPromptIncludesOnlyActiveSkills() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let store = AppStore(fileURL: url)
        var agent = store.agents[0]
        agent.skillIDs = [store.skills[0].id]  // Code Review (trigger: review)
        let prompt = store.systemPrompt(agent: agent, message: "can you review this and /summarize")
        XCTAssertTrue(prompt.contains("Skill: Code Review"))
        XCTAssertTrue(prompt.contains("Skill: Summarize"))
        XCTAssertFalse(prompt.contains("Skill: Email Writer"))
    }
}

final class SSETests: XCTestCase {
    func testPayloadParsing() {
        XCTAssertEqual(SSE.payload(fromLine: "data: {\"a\":1}"), "{\"a\":1}")
        XCTAssertNil(SSE.payload(fromLine: "data: [DONE]"))
        XCTAssertNil(SSE.payload(fromLine: "event: message_start"))
        XCTAssertNil(SSE.payload(fromLine: ""))
    }
}
