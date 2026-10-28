import XCTest
@testable import AgentHub

final class StartupTests: XCTestCase {
    /// Shapes from gateway/agentim/startup.py `listing()` and `detail()`.
    private let listingJSON = """
    {"now": 1000000, "team": [{"key": "product", "name": "Maya Chen", "title": "Product Manager", "emoji": "🧭", "owns": "x"}],
     "startups": [{"id": "a1", "name": "Leafy", "pitch": "Plants", "status": "running", "rounds": 2, "next_run": 1000600,
                   "min_minutes": 10, "max_minutes": 30, "created": 1, "updated": 2},
                  {"id": "b2", "name": "Walkies", "pitch": "Dogs", "status": "interview", "rounds": 0, "next_run": null,
                   "min_minutes": 10, "max_minutes": 30, "created": 3, "updated": 4}]}
    """

    private let detailJSON = """
    {"id": "a1", "name": "Leafy", "pitch": "Plants", "questions": ["Who pays?", "How much?"], "answers": ["Offices", "$300"],
     "status": "running", "plan": "# Leafy", "min_minutes": 10, "max_minutes": 30, "next_run": 1000600, "rounds": 2,
     "notify_channel": null, "notify_chat": null, "created": 1, "updated": 2, "now": 1000000,
     "team": [{"key": "product", "name": "Maya Chen", "title": "Product Manager", "emoji": "🧭", "owns": "x"}],
     "people": {"product": {"name": "Maya Chen", "title": "Product Manager", "emoji": "🧭"},
                "ceo": {"name": "Agent Tim", "title": "CEO", "emoji": "🐙"}},
     "messages": [{"round": 2, "role": "product", "content": "Cut scope.", "ts": 999000},
                  {"round": 2, "role": "ceo", "content": "Ship it.", "ts": 999100}]}
    """

    func testDecodesTheListing() throws {
        let listing = try JSONDecoder().decode(StartupListing.self, from: Data(listingJSON.utf8))
        XCTAssertEqual(listing.startups.map(\.name), ["Leafy", "Walkies"])
        XCTAssertNil(listing.startups[1].next_run)
        XCTAssertEqual(listing.team.first?.name, "Maya Chen")
    }

    func testDecodesTheDetail() throws {
        let detail = try JSONDecoder().decode(StartupDetail.self, from: Data(detailJSON.utf8))
        XCTAssertTrue(detail.isRunning)
        XCTAssertFalse(detail.isInterview)
        XCTAssertEqual(detail.minutesToNext, 10)
        XCTAssertEqual(detail.person("ceo").name, "Agent Tim")
        XCTAssertEqual(detail.person("product").title, "Product Manager")
        XCTAssertEqual(detail.person("ghost").emoji, "🤖")
        XCTAssertEqual(detail.answers, ["Offices", "$300"])
    }

    func testPausedHasNoCountdown() throws {
        var detail = try JSONDecoder().decode(StartupDetail.self, from: Data(detailJSON.utf8))
        detail.status = "paused"
        XCTAssertNil(detail.minutesToNext)
    }

    func testClientBuildsRequests() throws {
        let client = StartupClient(token: "t")
        let create = try client.request("v1/startups", method: "POST", body: ["pitch": "Plants for offices"])
        XCTAssertEqual(create.url?.absoluteString, "http://localhost:8780/v1/startups")
        XCTAssertEqual(create.value(forHTTPHeaderField: "authorization"), "Bearer t")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: create.httpBody!) as? [String: String], ["pitch": "Plants for offices"])
        XCTAssertEqual(try client.request("v1/startups/a1", method: "DELETE", body: nil).httpMethod, "DELETE")
    }

    @MainActor
    func testTokenComesFromTheStackEnv() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertNil(StartupModel.client(stackRoot: dir), "no .env yet")
        try "RUNNER_TOKEN=runner\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StartupModel.client(stackRoot: dir)?.token, "runner")
        try "RUNNER_TOKEN=runner\nAGENTIM_API_TOKEN=api\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        XCTAssertEqual(StartupModel.client(stackRoot: dir)?.token, "api", "the gateway's own token wins")
    }

    @MainActor
    func testNewStartupResetsTheDraft() {
        let model = StartupModel(demo: true)
        model.draftPitch = "old"
        model.newStartup()
        XCTAssertTrue(model.composing)
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.draftPitch, "")
    }

    @MainActor
    func testDemoHasManyStartupsAndNamedPeople() {
        let demo = StartupModel(demo: true)
        XCTAssertEqual(demo.listing?.startups.count, 3)
        XCTAssertEqual(Set(demo.listing?.startups.map(\.status) ?? []), ["running", "paused", "interview"])
        XCTAssertEqual(demo.detail?.team.count, 8)
        XCTAssertEqual(demo.detail?.person("ceo").name, "Agent Tim")
    }
}
