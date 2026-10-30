import XCTest
@testable import AgentHub

/// Replies with code and designs, codebases, coding-agent results and pull requests.
final class ResultsTests: XCTestCase {
    func testRepliesSplitIntoTextCodeAndDesigns() {
        let reply = """
        Here's the plan.

        ```swift
        let x = 1
        ```

        And the screen:

        ```html
        <html><body><main><h1>Welcome</h1></main></body></html>
        ```
        """
        XCTAssertEqual(MessageSegment.parse(reply), [
            .text("Here's the plan."),
            .code(language: "swift", code: "let x = 1", complete: true),
            .text("And the screen:"),
            .design(language: "html", code: "<html><body><main><h1>Welcome</h1></main></body></html>"),
        ])
        XCTAssertEqual(MessageSegment.parse("Just text, no code."), [.text("Just text, no code.")])
    }

    func testAStreamingBlockIsCodeUntilItCloses() {
        XCTAssertEqual(MessageSegment.parse("Designing:\n```html\n<html><body>"),
                       [.text("Designing:"), .code(language: "html", code: "<html><body>", complete: false)])
    }

    func testOnlyRealMarkupIsADesign() {
        XCTAssertTrue(MessageSegment.isDesign(language: "svg", code: "<svg viewBox='0 0 10 10'></svg>"))
        XCTAssertFalse(MessageSegment.isDesign(language: "html", code: "&lt;b&gt;"), "a snippet, not a screen")
        XCTAssertFalse(MessageSegment.isDesign(language: "swift", code: "<div>"))
    }

    func testGitHubLinksBecomeCards() {
        let text = """
        Opened https://github.com/acme/shop/pull/7, see https://github.com/acme/shop/blob/main/src/app.ts and \
        commit https://github.com/acme/shop/commit/abcdef1234567. Repo: https://github.com/acme/shop.
        Again https://github.com/acme/shop/pull/7
        """
        XCTAssertEqual(GitHubLinks.items(in: text).map(\.title),
                       ["acme/shop #7", "acme/shop: src/app.ts", "acme/shop @ abcdef1", "acme/shop"])
    }

    func testGitHubCodebaseFromNameOrLink() {
        for text in ["acme/shop", "https://github.com/acme/shop", "https://github.com/acme/shop.git", "git@github.com:acme/shop.git", " acme/shop/ "] {
            XCTAssertEqual(Codebase.github(text)?.location, "acme/shop", text)
        }
        XCTAssertNil(Codebase.github("not a repo"))
        XCTAssertNil(Codebase.github("https://gitlab.com/acme/shop"))
        XCTAssertEqual(Codebase(kind: .folder, location: "/Users/me/code/shop").source, ["type": "dir", "path": "/Users/me/code/shop"])
        XCTAssertEqual(Codebase.github("acme/shop")?.source, ["type": "github", "repo": "acme/shop"])
    }

    func testResultLinksGoToGitHubOncePushed() {
        let file = FileChange(path: "src/app view.ts", status: "modified", added: 3, removed: 1)
        var work = WorkResult(state: .done, agentName: "Claude Code", request: "Add dark mode", folder: "/tmp/shop",
                              repo: "acme/shop", branch: "agentim/add-dark-mode-1030-1200", files: [file])
        XCTAssertEqual(work.link(for: file), URL(fileURLWithPath: "/tmp/shop/src/app view.ts"), "local until pushed")
        XCTAssertTrue(work.summary.contains("changed 1 file: src/app view.ts (+3 −1)"))
        work.pullRequestURL = "https://github.com/acme/shop/pull/7"
        work.pullRequestNumber = 7
        XCTAssertEqual(work.link(for: file)?.absoluteString,
                       "https://github.com/acme/shop/blob/agentim/add-dark-mode-1030-1200/src/app%20view.ts")
        XCTAssertEqual(work.pullRequestFilesURL?.absoluteString, "https://github.com/acme/shop/pull/7/files")
        XCTAssertTrue(work.summary.contains("Pull request #7: https://github.com/acme/shop/pull/7"))
        XCTAssertEqual(work.linesAdded, 3)
    }

    func testPullRequestTitle() {
        XCTAssertEqual(AppStore.pullRequestTitle("Add dark mode\nwith a toggle in settings"), "Add dark mode")
        let long = String(repeating: "word ", count: 30)
        XCTAssertLessThanOrEqual(AppStore.pullRequestTitle(long).count, 72)
    }

    @MainActor
    func testDesignersGetThePreviewInstructionOthersDont() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        let design = Skill(name: "UI UX Designer", summary: "Design screens", instructions: "Design well.")
        let code = Skill(name: "Software Engineer", summary: "design trade-offs and code review", instructions: "Code well.")
        store.skills = [design, code]
        var designer = Agent(name: "Designer", emoji: "", summary: "", systemPrompt: "You design.")
        designer.skillIDs = [design.id]
        var engineer = Agent(name: "Engineer", emoji: "", summary: "", systemPrompt: "You code.")
        engineer.skillIDs = [code.id]
        XCTAssertTrue(store.systemPrompt(agent: designer, message: "a login screen").contains("```html"))
        XCTAssertFalse(store.systemPrompt(agent: engineer, message: "a login screen").contains("Show the design"))
    }

    @MainActor
    func testBuildItSendsTheRequestAndThePlan() {
        let store = AppStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json"))
        let agent = Agent(name: "Engineer", emoji: "", summary: "", systemPrompt: "")
        store.agents = [agent]
        var chat = store.newConversation(agent: agent)
        XCTAssertNil(store.buildRequest(in: chat.id), "nothing asked yet")
        chat.messages = [ChatMessage(role: .user, content: "Add a dark mode toggle"),
                         ChatMessage(role: .assistant, content: "1. Add a setting 2. Use it in Theme")]
        chat.codebase = Codebase(kind: .github, location: "acme/shop")
        store.conversations[0] = chat
        let request = store.buildRequest(in: chat.id)
        XCTAssertTrue(request?.hasPrefix("Add a dark mode toggle") ?? false)
        XCTAssertTrue(request?.contains("1. Add a setting 2. Use it in Theme") ?? false)
        store.setCodebase(nil, in: chat.id)
        XCTAssertNil(store.conversations[0].codebase)
    }

    func testOldChatsStillDecode() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00CF4FC964FF","role":"assistant","content":"hi","createdAt":0,"isError":false}"#
        let message = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.work)
    }
}
