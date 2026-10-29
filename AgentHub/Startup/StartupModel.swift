import AppKit
import Foundation
import Observation

// Shapes of the gateway's Startup Mode API (gateway/agentim/startup.py).

struct StartupPerson: Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var title: String
    var emoji: String
    var owns: String?
    /// Personality, background and how they talk (the agent stays in character).
    var persona: String?
    var id: String { key }
}

/// A role you can hire beyond the default team (gateway ROLE_PRESETS).
struct RolePreset: Decodable, Equatable, Identifiable {
    let title: String
    let emoji: String
    let owns: String
    var id: String { title }
}

/// Code a startup or idea is about: a folder on this Mac or a GitHub repo.
struct ProjectSource: Codable, Hashable, Identifiable {
    var type: String      // "dir" | "github"
    var path: String?
    var repo: String?
    var id: String { repo ?? path ?? UUID().uuidString }
    var isRepo: Bool { type == "github" }
    var label: String { repo ?? URL(fileURLWithPath: path ?? "").lastPathComponent }
    var symbol: String { isRepo ? "chevron.left.forwardslash.chevron.right" : "folder" }

    static func folder(_ url: URL) -> ProjectSource { ProjectSource(type: "dir", path: url.path) }

    /// "owner/name" or a github.com URL → a repo source (nil if it isn't one).
    static func github(_ text: String) -> ProjectSource? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "https://github.com/", with: "")
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = trimmed.split(separator: "/")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
        else { return nil }
        return ProjectSource(type: "github", repo: trimmed)
    }

    var json: [String: String] {
        isRepo ? ["type": "github", "repo": repo ?? ""] : ["type": "dir", "path": path ?? ""]
    }
}

struct StartupSummary: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let pitch: String
    let status: String
    let rounds: Int
    let next_run: Double?
    let min_minutes: Int
    let max_minutes: Int
    var kind: String? = nil
    var sources: [ProjectSource]? = nil
    var isIdea: Bool { kind == "idea" }
}

struct StartupListing: Decodable, Equatable {
    let now: Double
    let team: [StartupPerson]
    var startups: [StartupSummary]
}

struct StartupDetail: Decodable, Equatable {
    struct PersonInfo: Decodable, Equatable {
        let name: String
        let title: String
        let emoji: String
        var former: Bool? = nil
    }

    struct Message: Decodable, Equatable, Identifiable {
        let round: Int
        let role: String
        let content: String
        let ts: Double
        var id: String { "\(round)-\(role)-\(ts)" }
    }

    var id: String
    var name: String
    var pitch: String
    var questions: [String]
    var answers: [String]
    var status: String
    let plan: String
    let min_minutes: Int
    let max_minutes: Int
    var kind: String? = nil
    var sources: [ProjectSource]? = nil
    var isIdea: Bool { kind == "idea" }
    var config: LaunchConfig? = nil
    var pipeline: [LaunchStage]? = nil
    var providers: [DeployProvider]? = nil
    var launch_running: Bool? = nil
    var sprint: SprintState? = nil
    let next_run: Double?
    var rounds: Int
    let now: Double
    let team: [StartupPerson]
    let people: [String: PersonInfo]
    var presets: [RolePreset]? = nil
    var messages: [Message]
    /// Set while the agents are meeting (gateway `StartupMode.live`).
    var meeting: Meeting? = nil

    struct Meeting: Decodable, Equatable {
        let round: Int
        let speaking: String?
        var speakers: [String]? = nil
    }

    var isInterview: Bool { status == "interview" }

    /// Makes "@Name" bold (markdown) for agents of this startup, in any message.
    func boldMentions(_ text: String) -> String {
        let names = people.values.map { StartupModel.firstName($0.name) } + Array(people.keys)
        return Self.boldMentions(text, names: names)
    }

    static func boldMentions(_ text: String, names: [String]) -> String {
        var result = text
        for range in ComposerTextView.mentionRanges(in: text, names: names).reversed() {
            guard let swiftRange = Range(range, in: result) else { continue }
            // Already bold ("**@Leo**")? Leave it.
            let before = result[..<swiftRange.lowerBound].suffix(2)
            if before == "**" { continue }
            result.replaceSubrange(swiftRange, with: "**\(result[swiftRange])**")
        }
        return result
    }

    /// Demo mode: show the founder's message without a gateway.
    mutating func appendDemoFounderMessage(_ text: String) {
        messages.append(Message(round: meeting?.round ?? rounds + 1, role: "founder", content: text,
                                ts: Date().timeIntervalSince1970))
    }
    var isRunning: Bool { status == "running" }

    /// Minutes until the next meeting, on the gateway's clock.
    var minutesToNext: Int? {
        guard isRunning, let next_run else { return nil }
        return max(0, Int(((next_run - now) / 60).rounded(.up)))
    }

    func person(_ key: String) -> PersonInfo { people[key] ?? PersonInfo(name: key.capitalized, title: "", emoji: "🤖") }
}

/// Talks to the gateway on this Mac.
struct StartupClient {
    var baseURL = URL(string: "http://localhost:8780")!
    var token: String

    func list() async throws -> StartupListing { try await send("v1/startups") }
    func detail(_ id: String) async throws -> StartupDetail { try await send("v1/startups/\(id)") }

    func create(pitch: String, name: String, minMinutes: Int, maxMinutes: Int, kind: String = "startup",
                sources: [ProjectSource] = []) async throws -> StartupDetail {
        try await send("v1/startups", body: ["pitch": pitch, "name": name, "min_minutes": minMinutes, "max_minutes": maxMinutes,
                                             "kind": kind, "sources": sources.map(\.json)])
    }

    func setSources(_ id: String, _ sources: [ProjectSource]) async throws -> StartupDetail {
        try await send("v1/startups/\(id)", body: ["sources": sources.map(\.json)])
    }

    /// Claude Code plans (read-only) or builds (confirmed) the idea in each linked project; results land in the room.
    func work(_ id: String, build: Bool) async throws {
        _ = try await raw("v1/startups/\(id)/\(build ? "build" : "plan")", method: "POST", body: ["confirmed": build])
    }

    func answer(_ id: String, answers: [String]) async throws -> StartupDetail {
        try await send("v1/startups/\(id)/answers", body: ["answers": answers])
    }

    func skip(_ id: String) async throws -> StartupDetail { try await send("v1/startups/\(id)/answers", body: ["skip": true]) }
    func setEnabled(_ id: String, _ on: Bool) async throws -> StartupDetail { try await send("v1/startups/\(id)", body: ["enabled": on]) }

    func setTeam(_ id: String, _ team: [StartupPerson]) async throws -> StartupDetail {
        let members = team.map { ["key": $0.key, "name": $0.name, "title": $0.title, "emoji": $0.emoji, "owns": $0.owns ?? "",
                                  "persona": $0.persona ?? ""] }
        return try await send("v1/startups/\(id)/team", body: ["team": members])
    }

    func meetNow(_ id: String) async throws {
        _ = try await raw("v1/startups/\(id)/run", method: "POST", body: [:])
    }

    func meetings(_ id: String) async throws -> [MeetingSummary] {
        let data = try await raw("v1/startups/\(id)/meetings", method: "GET", body: nil)
        return try JSONDecoder().decode(MeetingList.self, from: data).meetings
    }

    /// Writes (or rewrites) a meeting's minutes on the gateway and returns the meeting.
    func writeMinutes(_ id: String, round: Int) async throws -> MeetingNotes {
        let data = try await raw("v1/startups/\(id)/meetings/\(round)/minutes", method: "POST", body: [:])
        return try JSONDecoder().decode(MeetingNotes.self, from: data)
    }

    func meeting(_ id: String, round: Int) async throws -> MeetingNotes {
        let data = try await raw("v1/startups/\(id)/meetings/\(round)", method: "GET", body: nil)
        return try JSONDecoder().decode(MeetingNotes.self, from: data)
    }

    /// The founder posts into the agents room (during a meeting or before the next one).
    func postMessage(_ id: String, text: String) async throws -> StartupDetail {
        try await send("v1/startups/\(id)/messages", body: ["text": text])
    }

    func delete(_ id: String) async throws {
        _ = try await raw("v1/startups/\(id)", method: "DELETE", body: nil)
    }

    /// AI drafts an answer to interview question `index` (0-based), using the pitch and the answers so far.
    func suggest(_ id: String, index: Int, answers: [String]) async throws -> String? {
        struct Reply: Decodable { let suggestions: [String: String] }
        let reply: Reply = try await send("v1/startups/\(id)/suggest", body: ["index": index, "answers": answers])
        return reply.suggestions[String(index)]
    }

    /// AI answers every question left blank, then the team starts.
    func autocomplete(_ id: String, answers: [String]) async throws -> StartupDetail {
        try await send("v1/startups/\(id)/autocomplete", body: ["answers": answers])
    }

    func getJSON<T: Decodable>(_ path: String) async throws -> T {
        try await send(path)
    }

    func sendDirectChat(_ path: String, body: [String: Any]?) async throws -> DirectChat {
        try await send(path, body: body)
    }

    func sendDetail(_ path: String, body: [String: Any]) async throws -> StartupDetail {
        try await send(path, body: body)
    }

    func post(_ path: String, body: [String: Any]) async throws {
        _ = try await raw(path, method: "POST", body: body)
    }

    private func send<T: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await raw(path, method: body == nil ? "GET" : "POST", body: body))
    }

    func request(_ path: String, method: String, body: [String: Any]?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Creating a startup asks the model for questions; give it time.
        request.timeoutInterval = 300
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return request
    }

    private func raw(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request(path, method: method, body: body))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ChatClientError.http(http.statusCode, message ?? String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

@MainActor
@Observable
final class StartupModel {
    var listing: StartupListing?
    var detail: StartupDetail?
    private(set) var error: String?
    private(set) var busy: String?
    var selection: String?
    var composing = false
    var draftName = ""
    var draftPitch = ""
    /// New: a startup (pitch → interview → team) or an idea (a feature across the linked code).
    var draftKind = "startup"
    var draftSources: [ProjectSource] = []
    var draftRepo = ""
    /// The project's commits and versions, and the GitHub repo form.
    var versions: ProjectVersions?
    var githubDraft: GitHubDraft?
    var confirmingGitHub = false
    /// The launch-mode confirmation dialog is open.
    var confirmingSprint = false
    /// The open 1:1 chat: who, the conversation, and the unsent message.
    var dmKey: String?
    var dmChat: DirectChat?
    var dmDraft = ""
    /// The launch settings being edited (nil when not editing).
    var launchDraft: LaunchConfig?
    /// "build" or "deploy" while its confirmation dialog is open.
    var confirmingStage: String?
    var draftAnswers: [String] = []
    /// The interview question on screen (0-based).
    var questionIndex = 0
    var minMinutes = 10
    var maxMinutes = 30

    private var timer: Timer?
    let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            listing = Self.demoListing
            selection = Self.demoDetail.id
            detail = Self.demoDetail
            // `-demoMeeting YES` shows Leafy's agents mid-meeting (screenshots).
            if UserDefaults.standard.bool(forKey: "demoMeeting") {
                detail?.meeting = .init(round: 7, speaking: "data", speakers: ["sales", "design", "data"])
            }
            // `-demoInterview YES` opens Tutorly mid-interview (screenshots).
            if UserDefaults.standard.bool(forKey: "demoInterview") {
                selection = Self.demoInterview.id
                detail = Self.demoInterview
                draftAnswers = ["Parents of 8–12 year olds who help with homework every night", "", ""] + Array(repeating: "", count: 7)
                draftAnswers[1] = "They Google it, then give up and text a friend"
                questionIndex = 2
            }
        }
    }

    /// The gateway token lives in the stack's .env (AGENTIM_API_TOKEN, else RUNNER_TOKEN).
    static func client(stackRoot: URL?) -> StartupClient? {
        guard let stackRoot,
              let text = try? String(contentsOf: stackRoot.appendingPathComponent(".env"), encoding: .utf8)
        else { return nil }
        let env = HostController.parseEnv(text)
        guard let token = [env["AGENTIM_API_TOKEN"], env["RUNNER_TOKEN"]].compactMap({ $0 }).first(where: { !$0.isEmpty })
        else { return nil }
        return StartupClient(token: token)
    }

    func startPolling(stackRoot: URL?) {
        guard !isDemo, timer == nil else { return }
        Task { await refresh(stackRoot: stackRoot) }
        // Every 3 s while the agents are meeting (to show the chat live), otherwise every 15 s.
        var ticks = 0
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                ticks += 1
                if self.detail?.meeting != nil || self.meetingRequested || ticks % 5 == 0 {
                    await self.refresh(stackRoot: stackRoot)
                }
            }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(stackRoot: URL?) async {
        guard !isDemo else { return }
        guard let client = Self.client(stackRoot: stackRoot) else {
            error = "agentim isn't set up yet. Run the setup from This Mac."
            return
        }
        do {
            listing = try await client.list()
            if selection == nil, !composing { selection = listing?.startups.last?.id }
            if let selection { detail = try await client.detail(selection) } else { detail = nil }
            error = nil
        } catch {
            self.error = "Can't reach agentim's gateway. Start the stack in This Mac. (\(error.localizedDescription))"
        }
    }

    func select(_ id: String?, stackRoot: URL?) async {
        selection = id
        composing = false
        draftAnswers = []
        questionIndex = 0
        if isDemo {
            detail = id == Self.demoInterview.id ? Self.demoInterview : Self.demoDetail
            return
        }
        await refresh(stackRoot: stackRoot)
    }

    func newStartup() {
        composing = true
        selection = nil
        detail = nil
        draftName = ""
        draftPitch = ""
    }

    /// Sends the pitch; the gateway replies with Tim's follow-up questions.
    // MARK: - Code: folders and repos

    /// Picks folders on this Mac (several at once) and adds them to the draft or to the open startup.
    func chooseFolders(stackRoot: URL?, forDraft: Bool) async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Choose the project folders (one per service)"
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls.map(ProjectSource.folder)
        for url in panel.urls { Self.allowWorkspace(url, stackRoot: stackRoot) }
        await addSources(picked, stackRoot: stackRoot, forDraft: forDraft)
    }

    func addRepo(stackRoot: URL?, forDraft: Bool) async {
        guard let source = ProjectSource.github(draftRepo) else {
            error = "Use owner/name or a github.com link."
            return
        }
        draftRepo = ""
        error = nil
        await addSources([source], stackRoot: stackRoot, forDraft: forDraft)
    }

    func removeSource(_ source: ProjectSource, stackRoot: URL?, forDraft: Bool) async {
        if forDraft {
            draftSources.removeAll { $0 == source }
        } else if let detail {
            await saveSources((detail.sources ?? []).filter { $0 != source }, id: detail.id, stackRoot: stackRoot)
        }
    }

    private func addSources(_ sources: [ProjectSource], stackRoot: URL?, forDraft: Bool) async {
        if forDraft {
            draftSources += sources.filter { !draftSources.contains($0) }
        } else if let detail {
            let current = detail.sources ?? []
            await saveSources(current + sources.filter { !current.contains($0) }, id: detail.id, stackRoot: stackRoot)
        }
    }

    private func saveSources(_ sources: [ProjectSource], id: String, stackRoot: URL?) async {
        if isDemo { detail?.sources = sources; return }
        await act("Updating the code…", stackRoot) { client in self.detail = try await client.setSources(id, sources) }
    }

    /// Folders you pick are added to AGENTIM_WORKSPACES so the runner may read them (and nothing else).
    nonisolated static func allowWorkspace(_ url: URL, stackRoot: URL?) {
        guard let env = stackRoot?.appendingPathComponent(".env"),
              let text = try? String(contentsOf: env, encoding: .utf8) else { return }
        let updated = withWorkspace(url.path, in: text)
        if updated != text { try? updated.write(to: env, atomically: true, encoding: .utf8) }
    }

    /// Adds `path` to AGENTIM_WORKSPACES unless a listed folder already contains it.
    nonisolated static func withWorkspace(_ path: String, in env: String) -> String {
        var lines = env.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("AGENTIM_WORKSPACES=") }) {
            let current = String(lines[i].dropFirst("AGENTIM_WORKSPACES=".count)).split(separator: ":").map(String.init)
            if current.contains(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return env }
            lines[i] = "AGENTIM_WORKSPACES=" + (current + [path]).joined(separator: ":")
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("AGENTIM_WORKSPACES=\(path)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Ideas: plan and build with Claude Code

    var confirmingBuild = false

    func planIdea(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        meetingRequested = true
        await act("Asking Claude Code to plan…", stackRoot) { client in try await client.work(id, build: false) }
    }

    func buildIdea(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        confirmingBuild = false
        meetingRequested = true
        await act("Claude Code is building…", stackRoot) { client in try await client.work(id, build: true) }
    }

    func submitPitch(stackRoot: URL?) async {
        await act("Agent Tim is reading your pitch…", stackRoot) { client in
            let created = try await client.create(pitch: self.draftPitch, name: self.draftName,
                                                  minMinutes: self.minMinutes, maxMinutes: self.maxMinutes,
                                                  kind: self.draftKind, sources: self.draftSources)
            self.draftSources = []
            self.composing = false
            self.selection = created.id
            self.detail = created
            self.draftAnswers = Array(repeating: "", count: created.questions.count)
            self.questionIndex = 0
        }
    }

    // MARK: - Interview: one question at a time

    var questionCount: Int { detail?.questions.count ?? 0 }
    var isLastQuestion: Bool { questionIndex >= questionCount - 1 }
    var answeredCount: Int { draftAnswers.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }

    /// Makes sure there's an answer slot per question (e.g. after reopening a startup mid-interview).
    func prepareInterview() {
        guard let questions = detail?.questions else { return }
        if draftAnswers.count != questions.count {
            let saved = detail?.answers ?? []
            draftAnswers = questions.indices.map { $0 < saved.count ? saved[$0] : "" }
            questionIndex = min(saved.count, max(questions.count - 1, 0))
        }
    }

    /// Next (or Skip, which leaves the answer empty). After the last question the team is hired.
    func nextQuestion(skip: Bool = false, stackRoot: URL?) async {
        guard questionIndex < draftAnswers.count else { return }
        if skip { draftAnswers[questionIndex] = "" }
        if isLastQuestion {
            await submitAnswers(stackRoot: stackRoot)
        } else {
            questionIndex += 1
        }
    }

    func previousQuestion() {
        questionIndex = max(0, questionIndex - 1)
    }

    func submitAnswers(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        let answers = draftAnswers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        await act("Starting the agents…", stackRoot) { client in
            self.detail = try await client.answer(id, answers: answers)
        }
    }

    /// The question the AI is drafting an answer for (shows a spinner on the Suggest button).
    var suggestingIndex: Int?

    /// ✨ Suggest: the AI writes an answer into the box; the founder can edit it before going on.
    func suggestAnswer(stackRoot: URL?) async {
        guard let id = detail?.id, questionIndex < draftAnswers.count else { return }
        let index = questionIndex
        suggestingIndex = index
        defer { suggestingIndex = nil }
        if isDemo {
            draftAnswers[index] = "Office managers at 50–200 person companies, paying $290 a month per floor."
            return
        }
        let answers = draftAnswers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        await act(nil, stackRoot) { client in
            if let text = try await client.suggest(id, index: index, answers: answers), index < self.draftAnswers.count {
                self.draftAnswers[index] = text
            }
        }
    }

    /// The AI answers every blank question (marked "suggested by AI"), then the agents start.
    func autocompleteAnswers(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        let answers = draftAnswers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        await act("The AI is answering the rest…", stackRoot) { client in
            self.detail = try await client.autocomplete(id, answers: answers)
        }
    }

    func skipQuestions(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act("Starting the agents…", stackRoot) { client in self.detail = try await client.skip(id) }
    }

    func setEnabled(_ on: Bool, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act(nil, stackRoot) { client in self.detail = try await client.setEnabled(id, on) }
    }

    // MARK: - Team editing

    var editingTeam = false
    var teamDraft: [StartupPerson] = []

    func beginTeamEdit() {
        avatarEdits = [:]
        avatarError = nil
        teamDraft = detail?.team ?? []
        editingTeam = true
    }

    func hire(_ preset: RolePreset?) {
        let title = preset?.title ?? "New role"
        teamDraft.append(StartupPerson(key: "new-\(UUID().uuidString.prefix(6))", name: Self.suggestedName(for: teamDraft),
                                       title: title, emoji: preset?.emoji ?? "🧑‍💼", owns: preset?.owns ?? ""))
    }

    func remove(_ person: StartupPerson) {
        teamDraft.removeAll { $0.key == person.key }
    }

    /// The team can be saved when everyone has a name and a title and nobody is left out.
    var teamDraftIsValid: Bool {
        !teamDraft.isEmpty && teamDraft.count <= 12 && teamDraft.allSatisfy {
            $0.name.trimmingCharacters(in: .whitespaces).count >= 2 && $0.title.trimmingCharacters(in: .whitespaces).count >= 2
        }
    }

    func saveTeam(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        // New people get their key from the gateway (it keeps keys unique and restores rehired alumni).
        let team = teamDraft.map { person -> StartupPerson in
            var person = person
            if person.key.hasPrefix("new-") { person.key = "" }
            return person
        }
        let draftKeys = teamDraft.map(\.key)
        let edits = avatarEdits
        await act("Updating the agents…", stackRoot) { client in
            let saved = try await client.setTeam(id, team)
            // The gateway keeps the order, so draft i is saved member i (new hires get their real key here).
            self.applyAvatarEdits(edits, draftKeys: draftKeys, savedKeys: saved.team.map(\.key), startup: id)
            self.detail = saved
            self.editingTeam = false
        }
        if isDemo {
            applyAvatarEdits(edits, draftKeys: draftKeys, savedKeys: draftKeys, startup: id)
            editingTeam = false
        }
    }

    // MARK: - Avatars in the agents editor

    enum AvatarEdit { case image(NSImage), useDefault }

    /// Pending avatar changes in the editor, by draft key (saved with the team).
    var avatarEdits: [String: AvatarEdit] = [:]
    var generatingAvatars: Set<String> = []
    var avatarError: String?

    /// What the editor shows for this agent: the pending change, else the saved custom/bundled avatar.
    func editorAvatar(for person: StartupPerson) -> NSImage? {
        switch avatarEdits[person.key] {
        case .image(let image): return image
        case .useDefault: return Avatars.teamMember(person.key)
        case nil: return Avatars.teamMember(person.key, startup: detail?.id)
        }
    }

    func setAvatar(_ image: NSImage, for person: StartupPerson) {
        avatarEdits[person.key] = .image(image)
    }

    func resetAvatar(for person: StartupPerson) {
        avatarEdits[person.key] = .useDefault
    }

    func chooseAvatar(for person: StartupPerson) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture for \(person.name)"
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            setAvatar(image, for: person)
        }
    }

    /// Asks LTX (through the runner on this Mac) for a cartoon portrait matching the agent.
    func generateAvatar(for person: StartupPerson, stackRoot: URL?) async {
        guard !isDemo else { return }
        guard let stackRoot,
              let env = try? String(contentsOf: stackRoot.appendingPathComponent(".env"), encoding: .utf8),
              let token = HostController.parseEnv(env)["RUNNER_TOKEN"], !token.isEmpty
        else { avatarError = "agentim isn't set up yet."; return }
        generatingAvatars.insert(person.key)
        defer { generatingAvatars.remove(person.key) }
        avatarError = nil
        do {
            let image = try await LTXAvatar.generate(prompt: LTXAvatar.prompt(for: person), token: token)
            setAvatar(image, for: person)
        } catch {
            avatarError = "Couldn't make an avatar: \(error.localizedDescription)"
        }
    }

    func applyAvatarEdits(_ edits: [String: AvatarEdit], draftKeys: [String], savedKeys: [String], startup: String) {
        for (index, draftKey) in draftKeys.enumerated() where index < savedKeys.count {
            switch edits[draftKey] {
            case .image(let image): try? CustomAvatars.save(image, startup: startup, key: savedKeys[index])
            case .useDefault: CustomAvatars.remove(startup: startup, key: savedKeys[index])
            case nil: break
            }
        }
        avatarEdits = [:]
    }

    static let firstNames = ["Jordan", "Riley", "Kai", "Nina", "Theo", "Priya", "Marco", "Elena", "Sami", "Lena"]
    static let lastNames = ["Lee", "Moreno", "Ito", "Shah", "Novak", "Brennan", "Okafor", "Silva", "Kowal", "Reyes"]

    static func suggestedName(for team: [StartupPerson]) -> String {
        let used = Set(team.map(\.name))
        for (first, last) in zip(firstNames, lastNames) where !used.contains("\(first) \(last)") {
            return "\(first) \(last)"
        }
        return "New Hire \(team.count + 1)"
    }

    /// "Meet now" was pressed: poll fast until the meeting shows up (and while it runs).
    var meetingRequested = false

    func meetNow(stackRoot: URL?) async {
        meetingRequested = true
        Task {
            try? await Task.sleep(for: .seconds(20))
            self.meetingRequested = false
        }
        guard let id = detail?.id else { return }
        await act("Calling the agents in…", stackRoot) { client in try await client.meetNow(id) }
    }

    // MARK: - Meeting notes

    var meetingList: [MeetingSummary] = []
    var openMeeting: MeetingNotes?

    func loadMeetings(stackRoot: URL?) async {
        guard let detail else { return }
        if isDemo {
            meetingList = MeetingSummary.fromMessages(detail.messages)
            return
        }
        guard let client = Self.client(stackRoot: stackRoot) else { return }
        meetingList = (try? await client.meetings(detail.id)) ?? []
    }

    func open(_ meeting: MeetingSummary, stackRoot: URL?) async {
        guard let detail else { return }
        if isDemo {
            openMeeting = MeetingNotes.fromMessages(detail.messages.filter { $0.round == meeting.round },
                                                     round: meeting.round, people: detail.people)
            return
        }
        guard let client = Self.client(stackRoot: stackRoot) else { return }
        do {
            openMeeting = try await client.meeting(detail.id, round: meeting.round)
        } catch {
            self.error = "Couldn't open meeting \(meeting.round): \(error.localizedDescription)"
        }
    }

    var writingMinutes = false

    func writeMinutes(for round: Int, stackRoot: URL?) async {
        guard let detail, !isDemo, let client = Self.client(stackRoot: stackRoot) else { return }
        writingMinutes = true
        defer { writingMinutes = false }
        do {
            openMeeting = try await client.writeMinutes(detail.id, round: round)
            await loadMeetings(stackRoot: stackRoot)
        } catch {
            self.error = "Couldn't write the summary: \(error.localizedDescription)"
        }
    }

    // MARK: - @mentions

    /// The partial "@na" at the end of the draft, if the founder is typing a mention.
    static func mentionQuery(in text: String) -> String? {
        guard let range = text.range(of: #"(^|\s)@([\w-]*)$"#, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces).dropFirst().lowercased()
    }

    /// Agents matching what's typed after "@".
    func mentionSuggestions() -> [StartupPerson] {
        guard let query = Self.mentionQuery(in: founderDraft), let team = detail?.team else { return [] }
        return team.filter { person in
            query.isEmpty || person.name.lowercased().hasPrefix(query) || person.key.lowercased().hasPrefix(query)
        }
    }

    /// First names (and keys) of the agents you can tag, for highlighting.
    var mentionNames: [String] {
        (detail?.team ?? []).flatMap { [Self.firstName($0.name), $0.key] }
    }

    nonisolated static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }

    /// Tab: complete the mention being typed with the first suggestion. Returns whether it did.
    func completeMentionWithTab() -> Bool {
        guard let first = mentionSuggestions().first else { return false }
        completeMention(first)
        return true
    }

    /// Replaces the partial "@na" with "@Nina ".
    func completeMention(_ person: StartupPerson) {
        guard let query = Self.mentionQuery(in: founderDraft) else { return }
        let first = person.name.split(separator: " ").first.map(String.init) ?? person.name
        founderDraft = String(founderDraft.dropLast(query.count + 1)) + "@\(first) "
    }

    // MARK: - Talking to the agents

    var founderDraft = ""
    static let maxFounderMessage = 2000

    var canSendToAgents: Bool {
        let text = founderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= Self.maxFounderMessage && busy == nil
    }

    func sendToAgents(stackRoot: URL?) async {
        guard canSendToAgents, let id = detail?.id else { return }
        let text = founderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        founderDraft = ""
        if isDemo {
            detail?.appendDemoFounderMessage(text)
            return
        }
        meetingRequested = true  // poll fast for the agents' answers
        Task {
            try? await Task.sleep(for: .seconds(20))
            self.meetingRequested = false
        }
        await act(nil, stackRoot) { client in self.detail = try await client.postMessage(id, text: text) }
        if error != nil { founderDraft = text }  // don't lose what they wrote
    }

    // MARK: - Deleting (always behind the confirmation screen)

    /// The startup waiting for "Delete" on the confirmation screen.
    var pendingDelete: StartupSummary?

    func askToDelete(_ startup: StartupSummary?) {
        pendingDelete = startup
    }

    /// The selected startup as a summary (for the confirmation screen).
    var selectedSummary: StartupSummary? {
        listing?.startups.first { $0.id == selection }
    }

    func confirmDelete(stackRoot: URL?) async {
        guard let target = pendingDelete else { return }
        pendingDelete = nil
        if isDemo {
            removeLocally(target.id)
            return
        }
        await act("Deleting \(target.name)…", stackRoot) { client in
            try await client.delete(target.id)
            self.removeLocally(target.id)
        }
        await refresh(stackRoot: stackRoot)
    }

    private func removeLocally(_ id: String) {
        listing?.startups.removeAll { $0.id == id }
        if selection == id {
            selection = listing?.startups.last?.id
            detail = nil
        }
    }

    func act(_ label: String?, _ stackRoot: URL?, _ work: (StartupClient) async throws -> Void) async {
        guard !isDemo, let client = Self.client(stackRoot: stackRoot) else { return }
        busy = label ?? "…"
        defer { busy = nil }
        do {
            try await work(client)
            error = nil
            listing = try? await client.list()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Demo (screenshots)

    static let demoTeam: [StartupPerson] = [
        .init(key: "product", name: "Maya Chen", title: "CPO", emoji: "🧭", owns: "product vision, MVP scope and success metrics"),
        .init(key: "design", name: "Leo Park", title: "Designer", emoji: "🎨", owns: "onboarding, key screens and brand"),
        .init(key: "engineering", name: "Noah Patel", title: "CTO", emoji: "🛠️", owns: "architecture and the smallest shippable version"),
        .init(key: "marketing", name: "Ava Brooks", title: "CMO", emoji: "📣", owns: "positioning, channels and launch"),
        .init(key: "automation", name: "Sam Rivera", title: "Marketing Automation", emoji: "⚙️", owns: "funnels, email sequences and lead scoring"),
        .init(key: "sales", name: "Zoe Kim", title: "CRO", emoji: "💼", owns: "the first 10 customers, pricing and pipeline"),
        .init(key: "bizdev", name: "Omar Haddad", title: "Business Development", emoji: "🤝", owns: "partnerships and distribution"),
        .init(key: "finance", name: "Grace Liu", title: "CFO", emoji: "💰", owns: "unit economics, runway and fundraising"),
        .init(key: "data", name: "Nina Shah", title: "Data Analyst", emoji: "📊", owns: "metrics, tracking, dashboards and experiments"),
        .init(key: "security", name: "Dana Cohen", title: "CISO", emoji: "🛡️", owns: "security, trust and compliance"),
        .init(key: "operations", name: "Marcus Reed", title: "COO", emoji: "⚙️", owns: "OKRs, operating rhythm and execution"),
    ]

    static let demoHire = StartupPerson(key: "jordan", name: "Jordan Lee", title: "Customer Success", emoji: "🫶",
                                        owns: "onboarding pilots and keeping them happy")

    static let demoPresets: [RolePreset] = [
        .init(title: "CTO", emoji: "🧠", owns: "technical vision, architecture decisions and hiring engineers"),
        .init(title: "Customer Success", emoji: "🫶", owns: "onboarding, retention and support"),
        .init(title: "Growth Lead", emoji: "📈", owns: "acquisition experiments and the weekly growth metric"),
        .init(title: "Data Scientist", emoji: "📊", owns: "metrics, dashboards and experiment analysis"),
        .init(title: "Legal & Compliance", emoji: "⚖️", owns: "contracts, terms, privacy and regulation"),
    ]

    static var demoListing: StartupListing {
        let now = Date().timeIntervalSince1970
        return StartupListing(now: now, team: demoTeam, startups: [
            .init(id: "leafy", name: "Leafy", pitch: "Office plant subscription", status: "running", rounds: 6,
                  next_run: now + 14 * 60, min_minutes: 10, max_minutes: 30),
            .init(id: "walkies", name: "Walkies", pitch: "Uber for dog walking", status: "paused", rounds: 3,
                  next_run: nil, min_minutes: 10, max_minutes: 30),
            .init(id: "tutorly", name: "Tutorly", pitch: "AI homework coach for parents", status: "interview", rounds: 0,
                  next_run: nil, min_minutes: 10, max_minutes: 30),
        ])
    }

    static var demoInterview: StartupDetail {
        var detail = demoDetail
        detail.id = "tutorly"
        detail.name = "Tutorly"
        detail.pitch = "An AI homework coach for parents: snap a photo of tonight's homework and get a 2-minute explanation you can give your kid."
        detail.status = "interview"
        detail.questions = [
            "Which parents feel this pain most, and how did you find out?",
            "What do they do tonight when they get stuck on homework?",
            "Why would a parent trust an AI explanation over the teacher's method?",
            "Who pays: parents, schools or tutoring centers, and how much?",
            "What single number will you grow every week?",
            "Why are you the right founders for Tutorly?",
            "Are you full-time on this, and how many months of runway do you have?",
            "Who builds, who sells, and who breaks ties?",
            "What ships in the next 90 days, and who are the first 10 families?",
            "What would make you stop or pivot, and when will you check?",
        ]
        detail.answers = []
        detail.rounds = 0
        return detail
    }

    static var demoDetail: StartupDetail {
        let now = Date().timeIntervalSince1970
        var people = Dictionary(uniqueKeysWithValues: demoTeam.map { ($0.key, StartupDetail.PersonInfo(name: $0.name, title: $0.title, emoji: $0.emoji)) })
        people["ceo"] = .init(name: "Agent Tim", title: "CEO", emoji: "🐙")
        people["bizdev"] = .init(name: "Omar Haddad", title: "Business Development", emoji: "🤝", former: true)
        people[demoHire.key] = .init(name: demoHire.name, title: demoHire.title, emoji: demoHire.emoji)
        return StartupDetail(
            id: "leafy", name: "Leafy",
            pitch: "A monthly subscription that delivers and swaps office plants so offices always look alive.",
            questions: ["Who manages plants at your target offices today?", "What would they pay per month?"],
            answers: ["Office managers; it's nobody's real job", "$250–350 per floor"],
            status: "running",
            plan: """
            # Leafy

            ## Top 3 priorities
            1. Sell to coworking landlords: one contract, many desks (Zoe)
            2. Per-floor pricing: $290/month at 62% margin (Grace)
            3. 3 paid pilots in Austin by month end (Zoe, Omar)

            ## By area
            ### 💼 Sales (Zoe)
            - 15 cold emails a week to coworking operators, goal 3 calls
            ### 🎨 Design (Leo)
            - One-page ROI calculator for operators by Friday
            ### ⚙️ Automation (Sam)
            - 3-step email sequence; lead score = desks > 30

            ## Experiments this week
            - Pre-sell 3 pilots at 50% off the first month

            ## Open questions
            - Own the plants or lease them? (Grace)
            """,
            min_minutes: 10, max_minutes: 30, next_run: now + 14 * 60, rounds: 6, now: now,
            team: demoTeam.filter { $0.key != "bizdev" } + [demoHire], people: people, presets: demoPresets,
            messages: [
                .init(round: 6, role: "sales", content: "Called 4 coworking operators this morning: 2 want a pilot if we handle setup. Next: send the ROI page with every follow-up and book 3 pilots by Friday. @Leo, can I have the ROI page by Thursday?", ts: now - 1_500),
                .init(round: 6, role: "design", content: "On it. The ROI page is one screen: desks → plants needed → monthly cost vs. a part-time plant person. I'll test it with Zoe's two warm leads. @Sam, can the email sequence link straight to it?", ts: now - 1_380),
                .init(round: 6, role: "finance", content: "Ran the pilot math: 50% off month one still clears 31% margin. Let's cap pilots at 3 so we don't train customers on discounts. @Zoe, push annual prepay at signing.", ts: now - 1_250),
                .init(round: 6, role: "ceo", content: "We're going after coworking landlords with per-floor pricing. Next: Zoe books 3 paid pilots by Friday using Leo's ROI page.", ts: now - 1_100),
            ])
    }
}

/// Cartoon avatars from LTX via the native runner (http://localhost:8766), the same style as the built-in ones.
enum LTXAvatar {
    static var runner = URL(string: "http://localhost:8766")!

    static func prompt(for person: StartupPerson) -> String {
        let persona = (person.persona ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "A friendly cartoon portrait of \(person.name), a \(person.title)"
            + (persona.isEmpty ? "" : " (\(persona.prefix(160)))")
            + ". Flat vector sticker illustration, thick dark outlines, soft shading, centered head-and-shoulders, "
            + "plain pastel background, square composition, no text, no letters, no watermark"
    }

    static func generate(prompt: String, token: String, session: URLSession = .shared) async throws -> NSImage {
        var request = URLRequest(url: runner.appendingPathComponent("v1/chat/completions"), timeoutInterval: 900)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "ltx/image", "stream": false, "messages": [["role": "user", "content": prompt]],
        ])
        let (data, _) = try await session.data(for: request)
        guard let url = imageURL(in: data) else { throw URLError(.cannotParseResponse) }
        let (imageData, _) = try await session.data(from: url)
        guard let image = NSImage(data: imageData) else { throw URLError(.cannotDecodeContentData) }
        return image
    }

    /// The `[image](http://…png)` link in the runner's reply.
    static func imageURL(in data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String,
              let range = content.range(of: #"\(https?://[^)\s]+\)"#, options: .regularExpression)
        else { return nil }
        return URL(string: String(content[range].dropFirst().dropLast()))
    }
}

// MARK: - Meeting notes

struct MeetingList: Decodable { let meetings: [MeetingSummary] }

/// One meeting in the notes list (GET /v1/startups/{id}/meetings).
struct MeetingSummary: Decodable, Equatable, Identifiable {
    let round: Int
    let started: Double
    let ended: Double
    let messages: Int
    let attendees: [String]
    let summary: String?
    /// Meeting minutes (markdown: Summary, Decisions, Action items, Metrics, Open questions).
    var minutes: String? = nil
    var id: Int { round }

    /// The "Summary" section of the minutes, else Tim's wrap-up.
    var headline: String? { MeetingNotes.section("Summary", in: minutes) ?? summary }

    var startDate: Date { Date(timeIntervalSince1970: started) }
    var endDate: Date { Date(timeIntervalSince1970: ended) }

    /// "Tue, Oct 28 · 2:14 – 2:19 PM"
    var when: String {
        let day = startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let start = startDate.formatted(date: .omitted, time: .shortened)
        let end = endDate.formatted(date: .omitted, time: .shortened)
        return start == end ? "\(day) · \(start)" : "\(day) · \(start) – \(end)"
    }

    /// Demo mode: group the demo messages by meeting.
    static func fromMessages(_ messages: [StartupDetail.Message]) -> [MeetingSummary] {
        Dictionary(grouping: messages, by: \.round).map { round, items in
            MeetingSummary(round: round, started: items.map(\.ts).min() ?? 0, ended: items.map(\.ts).max() ?? 0,
                           messages: items.count, attendees: Array(Set(items.map(\.role))).sorted(),
                           summary: items.last { $0.role == "ceo" }?.content,
                           minutes: MeetingNotes.demoMinutes(items))
        }
        .sorted { $0.round > $1.round }
    }
}

/// A full meeting to review (GET /v1/startups/{id}/meetings/{round}).
struct MeetingNotes: Decodable, Identifiable {
    let round: Int
    let started: Double
    let ended: Double
    let summary: String?
    var minutes: String? = nil
    let messages: [StartupDetail.Message]
    let people: [String: StartupDetail.PersonInfo]
    var action_items: [ActionItem]? = nil
    var id: Int { round }

    /// Who does what by when, from the meeting's minutes.
    struct ActionItem: Decodable, Equatable, Hashable {
        let owner: String
        let task: String
        let eta: String
        var proposed: Bool? = nil
        /// When it's due (for "in 45 min" / "by 15:30"), or what it waits for ("after Leo's ROI page").
        var due: Double? = nil
        var after: String? = nil
    }

    /// The body of one "## Section" of the minutes.
    static func section(_ name: String, in minutes: String?) -> String? {
        guard let minutes, let start = minutes.range(of: "## \(name)") else { return nil }
        let rest = minutes[start.upperBound...]
        let body = rest.range(of: "\n## ").map { rest[..<$0.lowerBound] } ?? rest
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Demo mode: minutes for the demo meeting.
    static func demoMinutes(_ messages: [StartupDetail.Message]) -> String? {
        guard messages.contains(where: { $0.role == "ceo" }) else { return nil }
        return """
        ## Summary
        The team picked coworking landlords as the first market, with per-floor pricing and three paid pilots in Austin.
        ## Decisions
        - Sell to coworking landlords first: one contract, many desks (Zoe)
        - Per-floor pricing at $290/month; cap pilots at 3 (Grace)
        ## Action items
        - **Zoe**: book 3 paid pilots (by Friday)
        - **Leo**: one-page ROI calculator for operators (by Thursday)
        - **Sam**: link the email sequence to the ROI page
        - **Grace**: push annual prepay at signing
        ## Metrics
        - Pilot margin: 31% with 50% off month one; target margin 62%
        - 2 of 4 operators called want a pilot
        ## Open questions
        - Own the plants or lease them?
        """
    }

    func person(_ key: String) -> StartupDetail.PersonInfo {
        if key == "founder" { return .init(name: "You", title: "Founder", emoji: "🧑‍🚀") }
        return people[key] ?? .init(name: key.capitalized, title: "", emoji: "🤖")
    }

    static func fromMessages(_ messages: [StartupDetail.Message], round: Int,
                             people: [String: StartupDetail.PersonInfo]) -> MeetingNotes {
        MeetingNotes(round: round, started: messages.first?.ts ?? 0, ended: messages.last?.ts ?? 0,
                     summary: messages.last { $0.role == "ceo" }?.content, minutes: demoMinutes(messages),
                     messages: messages, people: people)
    }
}
