import XCTest
@testable import AgentHub

final class BuiltInsTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "BuiltInsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private func store() -> AppStore {
        AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
    }

    func testQAAgentAndSkillsShip() {
        let slugs = Set(Skill.builtIn.map(\.slug))
        XCTAssertTrue(slugs.isSuperset(of: ["web-qa", "mobile-qa", "api-testing"]))
        let qa = Agent.starters(skills: Skill.builtIn).first { $0.name == "QA Engineer" }
        XCTAssertNotNil(qa)
        XCTAssertEqual(qa?.skillIDs.count, 4, "web, mobile, API testing + software engineer")
    }

    @MainActor
    func testNewBuiltInsReachExistingUsersOnce() {
        let store = store()
        let defaults = defaults()
        // Someone who installed before QA existed: no QA agent or QA skills yet.
        store.agents.removeAll { $0.name == "QA Engineer" }
        store.skills.removeAll { ["web-qa", "mobile-qa", "api-testing"].contains($0.slug) }
        defaults.set(store.agents.map { "agent:\($0.name)" } + store.skills.map { "skill:\($0.slug)" }, forKey: "seenBuiltIns")

        store.addNewBuiltIns(defaults: defaults)
        XCTAssertTrue(store.agents.contains { $0.name == "QA Engineer" })
        XCTAssertTrue(store.skills.contains { $0.slug == "api-testing" })
        let qa = store.agents.first { $0.name == "QA Engineer" }!
        XCTAssertTrue(qa.skillIDs.allSatisfy { id in store.skills.contains { $0.id == id } }, "wired to the store's skills")

        // Deleted on purpose: not brought back.
        store.agents.removeAll { $0.name == "QA Engineer" }
        store.addNewBuiltIns(defaults: defaults)
        XCTAssertFalse(store.agents.contains { $0.name == "QA Engineer" })
    }

    @MainActor
    func testNoDuplicates() {
        let store = store()
        let before = store.agents.count
        store.addNewBuiltIns(defaults: defaults())
        XCTAssertEqual(store.agents.count, before)
    }

    func testLocalCodingAgentsAreOnlyUsedByName() throws {
        let server = LocalServer(name: "This Mac (LTX)", baseURL: URL(string: "http://localhost:8766")!)
        let claude = AIModel.server(ServerModelInfo(id: "local/claude-code", kind: "agent", size_bytes: nil,
                                                    parameter_size: nil, loaded: nil, name: "Claude Code"), on: server)
        XCTAssertEqual(claude.alias, "claude-code")
        XCTAssertTrue(claude.isExplicitOnly)
        XCTAssertTrue(claude.displayName.hasPrefix("Claude Code"))
    }

    func testAvatarSlugs() {
        XCTAssertEqual(Avatars.slug("QA Engineer"), "qa-engineer")
        XCTAssertEqual(Avatars.slug("YouTube Creator"), "youtube-creator")
    }

    @MainActor
    func testRetiredBuiltInsAreRemovedButYourOwnStay() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "retired-\(UUID().uuidString)"))
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        store.addNewBuiltIns(defaults: defaults)
        let old = Agent(name: "Old Built-in", emoji: "🧳", summary: "", systemPrompt: "")
        let mine = Agent(name: "My Own Agent", emoji: "🙂", summary: "", systemPrompt: "")
        store.agents += [old, mine]
        defaults.set((defaults.stringArray(forKey: "seenBuiltIns") ?? []) + ["agent:Old Built-in"], forKey: "seenBuiltIns")
        store.addNewBuiltIns(defaults: defaults)
        XCTAssertFalse(store.agents.contains { $0.name == "Old Built-in" }, "its source is gone: removed")
        XCTAssertTrue(store.agents.contains { $0.name == "My Own Agent" }, "never touches agents you made")
        XCTAssertTrue(store.agents.contains { $0.name == "Business Development" }, "the generic one is built in")
    }
}
