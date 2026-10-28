import XCTest
@testable import AgentHub

final class IssueReporterTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    func testBugReportOpensGitHubWithDetails() {
        let url = IssueReporter.url(kind: .bug, title: "Crash", details: "It broke & stopped",
                                    environment: ["agentim": "1.0 (1)", "macOS": "26.5"])
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/doron2402/agentim/issues/new")
        let q = query(url)
        XCTAssertEqual(q["title"], "Crash")
        XCTAssertEqual(q["labels"], "bug")
        XCTAssertTrue(q["body"]!.contains("It broke & stopped"), "special characters survive encoding")
        XCTAssertTrue(q["body"]!.contains("- agentim: 1.0 (1)\n- macOS: 26.5"))
        XCTAssertTrue(q["body"]!.contains("### Steps to reproduce"))
    }

    func testFeatureRequest() {
        let q = query(IssueReporter.url(kind: .feature, environment: [:]))
        XCTAssertEqual(q["labels"], "enhancement")
        XCTAssertTrue(q["body"]!.contains("What would you like agentim to do?"))
    }

    func testCurrentEnvironmentHasTheBasics() {
        let env = IssueReporter.currentEnvironment()
        XCTAssertEqual(Set(env.keys), ["agentim", "macOS", "Chip", "Memory"])
        XCTAssertFalse(env["Chip"]!.isEmpty)
    }

    func testClaudeConfigDetection() {
        XCTAssertTrue(HostController.configHasAgentim(Data(#"{"mcpServers":{"agentim":{"command":"x"}}}"#.utf8)))
        XCTAssertFalse(HostController.configHasAgentim(Data(#"{"mcpServers":{"other":{}}}"#.utf8)))
        XCTAssertFalse(HostController.configHasAgentim(Data("not json".utf8)))
    }
}
