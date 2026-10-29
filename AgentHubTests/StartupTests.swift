import AppKit
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

    func testDecodesFormerEmployeesAndPresets() throws {
        var json = try JSONSerialization.jsonObject(with: Data(detailJSON.utf8)) as! [String: Any]
        var people = json["people"] as! [String: Any]
        people["omar"] = ["name": "Omar Haddad", "title": "Business Development", "emoji": "🤝", "former": true]
        json["people"] = people
        json["presets"] = [["title": "CTO", "emoji": "🧠", "owns": "architecture"]]
        let detail = try JSONDecoder().decode(StartupDetail.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(detail.person("omar").former, true)
        XCTAssertNil(detail.person("product").former)
        XCTAssertEqual(detail.presets?.first?.title, "CTO")
    }

    @MainActor
    func testTeamEditing() {
        let model = StartupModel(demo: true)
        model.beginTeamEdit()
        XCTAssertTrue(model.editingTeam)
        let start = model.teamDraft.count
        model.hire(StartupModel.demoPresets.first)
        XCTAssertEqual(model.teamDraft.count, start + 1)
        let hire = model.teamDraft.last!
        XCTAssertEqual(hire.title, "CTO")
        XCTAssertFalse(model.teamDraft.dropLast().contains { $0.name == hire.name }, "suggested name is new")
        XCTAssertTrue(model.teamDraftIsValid)
        model.teamDraft[model.teamDraft.count - 1].name = ""
        XCTAssertFalse(model.teamDraftIsValid, "everyone needs a name")
        model.remove(model.teamDraft.last!)
        XCTAssertTrue(model.teamDraftIsValid)
        model.teamDraft.removeAll()
        XCTAssertFalse(model.teamDraftIsValid, "at least one person")
        for _ in 0..<13 { model.hire(nil) }
        XCTAssertFalse(model.teamDraftIsValid, "at most 12")
    }

    func testSetTeamRequestBody() throws {
        let client = StartupClient(token: "t")
        let team = [StartupPerson(key: "", name: "Jordan Lee", title: "Customer Success", emoji: "🫶", owns: "retention")]
        let members = team.map { ["key": $0.key, "name": $0.name, "title": $0.title, "emoji": $0.emoji, "owns": $0.owns ?? ""] }
        let request = try client.request("v1/startups/a1/team", method: "POST", body: ["team": members])
        XCTAssertEqual(request.url?.path, "/v1/startups/a1/team")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: [[String: String]]]
        XCTAssertEqual(body["team"]?.first?["name"], "Jordan Lee")
        XCTAssertEqual(body["team"]?.first?["key"], "", "new hires get their key from the gateway")
    }

    @MainActor
    func testInterviewOneQuestionAtATime() async throws {
        let model = StartupModel(demo: true)
        model.detail = try JSONDecoder().decode(StartupDetail.self, from: Data(detailJSON.utf8))
        model.detail?.status = "interview"
        model.detail?.answers = []
        model.prepareInterview()
        XCTAssertEqual(model.draftAnswers, ["", ""])
        XCTAssertEqual(model.questionIndex, 0)
        XCTAssertFalse(model.isLastQuestion)

        model.draftAnswers[0] = "Office managers"
        await model.nextQuestion(stackRoot: nil)
        XCTAssertEqual(model.questionIndex, 1, "Next moves on")
        XCTAssertTrue(model.isLastQuestion)

        model.previousQuestion()
        XCTAssertEqual(model.questionIndex, 0, "Back goes back")
        XCTAssertEqual(model.draftAnswers[0], "Office managers", "answers are kept")
        model.previousQuestion()
        XCTAssertEqual(model.questionIndex, 0, "can't go before the first")

        await model.nextQuestion(stackRoot: nil)
        model.draftAnswers[1] = "draft I'll throw away"
        await model.nextQuestion(skip: true, stackRoot: nil)
        XCTAssertEqual(model.draftAnswers[1], "", "Skip leaves it blank")
        XCTAssertEqual(model.answeredCount, 1)
    }

    @MainActor
    func testInterviewResumesWhereTheFounderStopped() throws {
        let model = StartupModel(demo: true)
        model.detail = try JSONDecoder().decode(StartupDetail.self, from: Data(detailJSON.utf8))
        model.detail?.answers = ["Offices"]
        model.draftAnswers = []
        model.prepareInterview()
        XCTAssertEqual(model.draftAnswers, ["Offices", ""])
        XCTAssertEqual(model.questionIndex, 1)
    }

    func testReturnSubmitsAndShiftReturnIsANewLine() {
        XCTAssertTrue(SubmitTextView.shouldSubmit([]))
        XCTAssertTrue(SubmitTextView.shouldSubmit(.command))
        XCTAssertFalse(SubmitTextView.shouldSubmit(.shift))
        XCTAssertFalse(SubmitTextView.shouldSubmit(.option))
        XCTAssertFalse(SubmitTextView.shouldSubmit([.control]))
    }

    @MainActor
    func testReturnKeyCallsSubmit() {
        let view = SubmitTextView()
        var submitted = 0
        view.onSubmit = { submitted += 1 }
        let returnKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                         isARepeat: false, keyCode: 36)!
        view.keyDown(with: returnKey)
        XCTAssertEqual(submitted, 1)
        XCTAssertEqual(view.string, "", "Return doesn't insert a new line")
    }

    @MainActor
    func testFounderTalksToTheAgents() async {
        let model = StartupModel(demo: true)
        XCTAssertFalse(model.canSendToAgents, "nothing to send")
        model.founderDraft = "   "
        XCTAssertFalse(model.canSendToAgents)
        model.founderDraft = String(repeating: "x", count: StartupModel.maxFounderMessage + 1)
        XCTAssertFalse(model.canSendToAgents, "too long")
        model.founderDraft = "Focus on enterprise pilots"
        XCTAssertTrue(model.canSendToAgents)
        let before = model.detail?.messages.count ?? 0
        await model.sendToAgents(stackRoot: nil)
        XCTAssertEqual(model.founderDraft, "", "cleared after sending")
        XCTAssertEqual(model.detail?.messages.count, before + 1)
        XCTAssertEqual(model.detail?.messages.last?.role, "founder")
        XCTAssertEqual(model.detail?.messages.last?.content, "Focus on enterprise pilots")
    }

    func testPostMessageRequest() throws {
        let request = try StartupClient(token: "t").request("v1/startups/a1/messages", method: "POST", body: ["text": "Hi agents"])
        XCTAssertEqual(request.url?.path, "/v1/startups/a1/messages")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String], ["text": "Hi agents"])
    }

    @MainActor
    func testDeleteNeedsConfirmation() async {
        let model = StartupModel(demo: true)
        let leafy = model.listing!.startups.first { $0.id == "leafy" }!
        model.askToDelete(leafy)
        XCTAssertEqual(model.pendingDelete?.id, "leafy", "the confirmation screen is showing")
        XCTAssertEqual(model.listing?.startups.count, 3, "nothing deleted yet")
        model.askToDelete(nil)  // Cancel
        XCTAssertNil(model.pendingDelete)
        XCTAssertEqual(model.listing?.startups.count, 3)
        model.askToDelete(leafy)
        await model.confirmDelete(stackRoot: nil)
        XCTAssertNil(model.pendingDelete)
        XCTAssertFalse(model.listing!.startups.contains { $0.id == "leafy" })
        XCTAssertNotEqual(model.selection, "leafy", "selection moves off the deleted startup")
    }

    @MainActor
    func testPersonaAndAvatarEdits() throws {
        CustomAvatars.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = StartupModel(demo: true)
        model.beginTeamEdit()
        model.teamDraft[0].persona = "Ex-Stripe PM, blunt, loves data"
        let size = NSSize(width: 40, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in NSColor.purple.setFill(); rect.fill(); return true }
        model.setAvatar(image, for: model.teamDraft[0])
        XCTAssertTrue(model.editorAvatar(for: model.teamDraft[0]) === image, "preview shows the pending avatar")
        let key = model.teamDraft[0].key
        model.applyAvatarEdits(model.avatarEdits, draftKeys: [key], savedKeys: [key], startup: "leafy")
        let saved = try XCTUnwrap(CustomAvatars.image(startup: "leafy", key: key))
        XCTAssertEqual(saved.size.width, saved.size.height, "center-cropped to a square")
        XCTAssertTrue(model.avatarEdits.isEmpty)

        model.resetAvatar(for: model.teamDraft[0])
        model.applyAvatarEdits(model.avatarEdits, draftKeys: [key], savedKeys: [key], startup: "leafy")
        XCTAssertNil(CustomAvatars.image(startup: "leafy", key: key), "back to the default")
    }

    func testNewHireAvatarFollowsTheRealKey() throws {
        CustomAvatars.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in NSColor.red.setFill(); rect.fill(); return true }
        let edits: [String: StartupModel.AvatarEdit] = ["new-abc": .image(image)]
        MainActor.assumeIsolated {
            StartupModel(demo: true).applyAvatarEdits(edits, draftKeys: ["product", "new-abc"],
                                                      savedKeys: ["product", "jordan-customer-success"], startup: "s1")
        }
        XCTAssertNotNil(CustomAvatars.image(startup: "s1", key: "jordan-customer-success"))
        XCTAssertNil(CustomAvatars.image(startup: "s1", key: "new-abc"))
    }

    func testLTXAvatarPromptAndReplyParsing() {
        let person = StartupPerson(key: "cto", name: "Kai Mori", title: "CTO", emoji: "🧠", owns: nil, persona: "dry humour")
        let prompt = LTXAvatar.prompt(for: person)
        XCTAssertTrue(prompt.contains("Kai Mori, a CTO (dry humour)"))
        XCTAssertTrue(prompt.contains("no text"))
        let reply = #"{"choices":[{"message":{"content":"Rendered.\n\n[image](http://localhost:8766/files/abc.png)"}}]}"#
        XCTAssertEqual(LTXAvatar.imageURL(in: Data(reply.utf8))?.absoluteString, "http://localhost:8766/files/abc.png")
        XCTAssertNil(LTXAvatar.imageURL(in: Data("{}".utf8)))
    }

    @MainActor
    func testMentionQuery() {
        XCTAssertEqual(StartupModel.mentionQuery(in: "@sa"), "sa")
        XCTAssertEqual(StartupModel.mentionQuery(in: "hey @"), "")
        XCTAssertNil(StartupModel.mentionQuery(in: "mail me at a@b"), "not after a word")
        XCTAssertNil(StartupModel.mentionQuery(in: "@sam do this"), "only while typing the name")
    }

    @MainActor
    func testMentionSuggestionsAndCompletion() {
        let model = StartupModel(demo: true)
        model.founderDraft = "Great work. @ni"
        XCTAssertEqual(model.mentionSuggestions().map(\.name), ["Nina Shah"])
        model.completeMention(model.mentionSuggestions()[0])
        XCTAssertEqual(model.founderDraft, "Great work. @Nina ")
        XCTAssertTrue(model.mentionSuggestions().isEmpty, "done typing the mention")
        model.founderDraft = "@"
        XCTAssertEqual(model.mentionSuggestions().count, model.detail?.team.count, "everyone after a bare @")
    }

    @MainActor
    func testMeetingNotesInDemo() async {
        let model = StartupModel(demo: true)
        await model.loadMeetings(stackRoot: nil)
        let meeting = try? XCTUnwrap(model.meetingList.first)
        XCTAssertEqual(meeting?.round, 6)
        XCTAssertNotNil(meeting?.summary, "Tim's summary is the meeting's headline")
        XCTAssertTrue(meeting?.when.contains("·") ?? false, "date · time")
        await model.open(meeting!, stackRoot: nil)
        XCTAssertEqual(model.openMeeting?.round, 6)
        XCTAssertEqual(model.openMeeting?.messages.last?.role, "ceo")
        XCTAssertEqual(model.openMeeting?.person("founder").name, "You")
    }

    func testMinutesSections() {
        let minutes = "## Summary\nWe picked landlords.\n## Decisions\n- Per-floor pricing\n## Action items\n- **Zoe**: 3 pilots\n- **Leo**: ROI page"
        XCTAssertEqual(MeetingNotes.section("Summary", in: minutes), "We picked landlords.")
        XCTAssertEqual(MeetingNotes.section("Action items", in: minutes), "- **Zoe**: 3 pilots\n- **Leo**: ROI page")
        XCTAssertNil(MeetingNotes.section("Metrics", in: minutes))
        XCTAssertNil(MeetingNotes.section("Summary", in: nil))
        let meeting = MeetingSummary(round: 1, started: 0, ended: 0, messages: 3, attendees: [], summary: "Tim's wrap-up",
                                     minutes: minutes)
        XCTAssertEqual(meeting.headline, "We picked landlords.", "the minutes' summary wins")
        XCTAssertEqual(MeetingSummary(round: 1, started: 0, ended: 0, messages: 3, attendees: [], summary: "Tim's wrap-up").headline,
                       "Tim's wrap-up", "falls back to Tim's wrap-up")
    }

    func testDecodesMeetingNotes() throws {
        let list = #"{"meetings":[{"round":2,"started":1000,"ended":1300,"messages":4,"attendees":["sales","ceo"],"summary":"Ship it."}]}"#
        let meetings = try JSONDecoder().decode(MeetingList.self, from: Data(list.utf8)).meetings
        XCTAssertEqual(meetings.first?.attendees, ["sales", "ceo"])
        XCTAssertEqual(meetings.first?.endDate.timeIntervalSince1970, 1300)
    }

    func testMentionsAreBoldInMessages() {
        let names = ["Sam", "Leo", "automation"]
        XCTAssertEqual(StartupDetail.boldMentions("@Sam come up with 2 designs, @leo help", names: names),
                       "**@Sam** come up with 2 designs, **@leo** help")
        XCTAssertEqual(StartupDetail.boldMentions("**@Sam** already bold", names: names), "**@Sam** already bold")
        XCTAssertEqual(StartupDetail.boldMentions("mail sam@leo.com or @Samantha", names: names),
                       "mail sam@leo.com or @Samantha", "no partial names or emails")
    }

    func testMentionRangesForHighlighting() {
        let text = "Hi @Nina and @nina, not @Ninja"
        let ranges = ComposerTextView.mentionRanges(in: text, names: ["Nina"])
        XCTAssertEqual(ranges.map { (text as NSString).substring(with: $0) }, ["@Nina", "@nina"])
    }

    @MainActor
    func testTabCompletesTheMention() {
        let model = StartupModel(demo: true)
        model.founderDraft = "@Le"
        XCTAssertTrue(model.completeMentionWithTab())
        XCTAssertEqual(model.founderDraft, "@Leo ")
        XCTAssertFalse(model.completeMentionWithTab(), "nothing left to complete: Tab acts normally")
        XCTAssertTrue(model.mentionNames.contains("Leo"))
    }

    @MainActor
    func testTabKeyGoesToTheOwnerFirst() {
        let view = SubmitTextView()
        var handled = 0
        view.onTab = { handled += 1; return true }
        view.insertTab(nil)
        XCTAssertEqual(handled, 1)
        XCTAssertEqual(view.string, "", "a handled Tab doesn't insert a tab character")
    }

    func testGitHubRepoSources() {
        XCTAssertEqual(ProjectSource.github("acme/web")?.repo, "acme/web")
        XCTAssertEqual(ProjectSource.github("https://github.com/CrewOS-Agentim/agentim.git")?.repo, "CrewOS-Agentim/agentim")
        XCTAssertNil(ProjectSource.github("just-a-name"))
        XCTAssertNil(ProjectSource.github("a/b/c"))
        XCTAssertEqual(ProjectSource.github("acme/web")?.json, ["type": "github", "repo": "acme/web"])
        XCTAssertEqual(ProjectSource.folder(URL(fileURLWithPath: "/Users/me/code/orders")).label, "orders")
    }

    func testPickedFoldersBecomeWorkspaces() {
        let env = "RUNNER_TOKEN=x\nAGENTIM_WORKSPACES=/Users/me/github\n"
        XCTAssertEqual(StartupModel.withWorkspace("/Users/me/github/orders", in: env), env, "already covered")
        XCTAssertEqual(StartupModel.withWorkspace("/Users/me/work/api", in: env),
                       "RUNNER_TOKEN=x\nAGENTIM_WORKSPACES=/Users/me/github:/Users/me/work/api\n")
        XCTAssertEqual(StartupModel.withWorkspace("/Users/me/work/api", in: "RUNNER_TOKEN=x\n"),
                       "RUNNER_TOKEN=x\nAGENTIM_WORKSPACES=/Users/me/work/api\n")
        XCTAssertNotEqual(StartupModel.withWorkspace("/Users/me/githubber", in: env), env, "a prefix that isn't a parent folder")
    }

    func testDecodesLaunchAndActionItems() throws {
        var json = try JSONSerialization.jsonObject(with: Data(detailJSON.utf8)) as! [String: Any]
        json["config"] = ["deploy": "vercel", "live_url": "https://leafy.vercel.app"]
        json["pipeline"] = [["stage": "design", "status": "done", "output": "One page"], ["stage": "build", "status": "waiting"]]
        json["providers"] = [["id": "vercel", "name": "Vercel", "command": "npx vercel"]]
        let detail = try JSONDecoder().decode(StartupDetail.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(detail.config?.deploy, "vercel")
        XCTAssertEqual(detail.config?.test_command, "", "missing settings decode as empty")
        XCTAssertEqual(detail.pipeline?.map(\.statusText), ["Done", "Ready"])
        XCTAssertEqual(LaunchConfig().json["deploy"] as? String, "none")
        XCTAssertEqual(LaunchConfig().json["versioning"] as? String, "auto")
        XCTAssertNil(LaunchConfig().json["version"], "the version is agentim's, not a setting")
        let history = #"{"commits":[{"sha":"abc1234","subject":"feat: build v1 of Leafy","ts":1800000000,"version":"v0.1.0"},{"sha":"def5678","subject":"wip","ts":1799999000}],"version":"v0.1.0","remote":""}"#
        let versions = try JSONDecoder().decode(ProjectVersions.self, from: Data(history.utf8))
        XCTAssertEqual(versions.commits.map(\.version), ["v0.1.0", nil])
        json["sprint"] = ["status": "running", "started": 1_800_000_000]
        let sprinting = try JSONDecoder().decode(StartupDetail.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(sprinting.sprint?.status, "running")

        let notes = #"{"round":1,"started":0,"ended":1,"summary":null,"messages":[],"people":{},"action_items":[{"owner":"Zoe","task":"Book pilots","eta":"Fri, Oct 30","proposed":true}]}"#
        let decoded = try JSONDecoder().decode(MeetingNotes.self, from: Data(notes.utf8))
        XCTAssertEqual(decoded.action_items?.first?.owner, "Zoe")

        let timed = #"{"round":2,"started":0,"ended":1,"summary":null,"messages":[],"people":{},"action_items":[{"owner":"Leo","task":"ROI page","eta":"in 45 min","due":1800000000},{"owner":"Sam","task":"Emails","eta":"after Leo's ROI page","after":"Leo's ROI page"}]}"#
        let items = try JSONDecoder().decode(MeetingNotes.self, from: Data(timed.utf8)).action_items
        XCTAssertEqual(items?.first?.due, 1_800_000_000)
        XCTAssertEqual(items?.last?.after, "Leo's ROI page")

        let boardJSON = #"{"tasks":[{"id":"a1","owner":"design","task":"ROI page","status":"done","from_role":"meeting","output":"Done."},{"id":"b2","owner":"automation","task":"Email","status":"todo","from_role":"design","depends_on":"a1","ready":true}],"working":[],"started_today":2,"budget":40}"#
        let board = try JSONDecoder().decode(WorkBoard.self, from: Data(boardJSON.utf8))
        XCTAssertEqual(board.tasks.map(\.status), ["done", "todo"])
        XCTAssertEqual(board.tasks.last?.from_role, "design", "a handoff from Leo")

        let chat = #"{"person":{"key":"sales","name":"Zoe Kim","title":"CRO","emoji":"💼"},"messages":[{"role":"founder","content":"Price?","ts":1},{"role":"sales","content":"$290/floor","ts":2}],"typing":false}"#
        let dm = try JSONDecoder().decode(DirectChat.self, from: Data(chat.utf8))
        XCTAssertEqual(dm.messages.map(\.fromFounder), [true, false])
    }

    func testDecodesIdeas() throws {
        var json = try JSONSerialization.jsonObject(with: Data(detailJSON.utf8)) as! [String: Any]
        json["kind"] = "idea"
        json["sources"] = [["type": "dir", "path": "/Users/me/code/orders"], ["type": "github", "repo": "acme/web"]]
        let detail = try JSONDecoder().decode(StartupDetail.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(detail.isIdea)
        XCTAssertEqual(detail.sources?.map(\.label), ["orders", "acme/web"])
        let old = try JSONDecoder().decode(StartupDetail.self, from: Data(detailJSON.utf8))
        XCTAssertFalse(old.isIdea, "startups from before ideas still decode")
    }

    @MainActor
    func testDemoHasManyStartupsAndNamedPeople() {
        let demo = StartupModel(demo: true)
        XCTAssertEqual(demo.listing?.startups.count, 3)
        XCTAssertEqual(Set(demo.listing?.startups.map(\.status) ?? []), ["running", "paused", "interview"])
        XCTAssertEqual(demo.detail?.team.count, 11)
        XCTAssertEqual(demo.detail?.person("ceo").name, "Agent Tim")
    }
}
