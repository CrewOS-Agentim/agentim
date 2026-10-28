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

    func testAvatarSlugs() {
        XCTAssertEqual(Avatars.slug("QA Engineer"), "qa-engineer")
        XCTAssertEqual(Avatars.slug("YouTube Creator"), "youtube-creator")
    }
}
