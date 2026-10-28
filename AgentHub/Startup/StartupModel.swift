import Foundation
import Observation

// Shapes of the gateway's Startup Mode API (gateway/agentim/startup.py).

struct StartupPerson: Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var title: String
    var emoji: String
    var owns: String?
    var id: String { key }
}

/// A role you can hire beyond the default team (gateway ROLE_PRESETS).
struct RolePreset: Decodable, Equatable, Identifiable {
    let title: String
    let emoji: String
    let owns: String
    var id: String { title }
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
}

struct StartupListing: Decodable, Equatable {
    let now: Double
    let team: [StartupPerson]
    let startups: [StartupSummary]
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

    let id: String
    let name: String
    let pitch: String
    let questions: [String]
    var answers: [String]
    var status: String
    let plan: String
    let min_minutes: Int
    let max_minutes: Int
    let next_run: Double?
    let rounds: Int
    let now: Double
    let team: [StartupPerson]
    let people: [String: PersonInfo]
    var presets: [RolePreset]? = nil
    let messages: [Message]

    var isInterview: Bool { status == "interview" }
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

    func create(pitch: String, name: String, minMinutes: Int, maxMinutes: Int) async throws -> StartupDetail {
        try await send("v1/startups", body: ["pitch": pitch, "name": name, "min_minutes": minMinutes, "max_minutes": maxMinutes])
    }

    func answer(_ id: String, answers: [String]) async throws -> StartupDetail {
        try await send("v1/startups/\(id)/answers", body: ["answers": answers])
    }

    func skip(_ id: String) async throws -> StartupDetail { try await send("v1/startups/\(id)/answers", body: ["skip": true]) }
    func setEnabled(_ id: String, _ on: Bool) async throws -> StartupDetail { try await send("v1/startups/\(id)", body: ["enabled": on]) }

    func setTeam(_ id: String, _ team: [StartupPerson]) async throws -> StartupDetail {
        let members = team.map { ["key": $0.key, "name": $0.name, "title": $0.title, "emoji": $0.emoji, "owns": $0.owns ?? ""] }
        return try await send("v1/startups/\(id)/team", body: ["team": members])
    }

    func meetNow(_ id: String) async throws {
        _ = try await raw("v1/startups/\(id)/run", method: "POST", body: [:])
    }

    func delete(_ id: String) async throws {
        _ = try await raw("v1/startups/\(id)", method: "DELETE", body: nil)
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
    private(set) var listing: StartupListing?
    private(set) var detail: StartupDetail?
    private(set) var error: String?
    private(set) var busy: String?
    var selection: String?
    var composing = false
    var draftName = ""
    var draftPitch = ""
    var draftAnswers: [String] = []
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
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { await self?.refresh(stackRoot: stackRoot) }
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
    func submitPitch(stackRoot: URL?) async {
        await act("Agent Tim is reading your pitch…", stackRoot) { client in
            let created = try await client.create(pitch: self.draftPitch, name: self.draftName,
                                                  minMinutes: self.minMinutes, maxMinutes: self.maxMinutes)
            self.composing = false
            self.selection = created.id
            self.detail = created
            self.draftAnswers = Array(repeating: "", count: created.questions.count)
        }
    }

    func submitAnswers(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act("Hiring the team…", stackRoot) { client in
            self.detail = try await client.answer(id, answers: self.draftAnswers)
        }
    }

    func skipQuestions(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act("Hiring the team…", stackRoot) { client in self.detail = try await client.skip(id) }
    }

    func setEnabled(_ on: Bool, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act(nil, stackRoot) { client in self.detail = try await client.setEnabled(id, on) }
    }

    // MARK: - Team editing

    var editingTeam = false
    var teamDraft: [StartupPerson] = []

    func beginTeamEdit() {
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
        await act("Updating the team…", stackRoot) { client in
            self.detail = try await client.setTeam(id, team)
            self.editingTeam = false
        }
        if isDemo { editingTeam = false }
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

    func meetNow(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act("Calling the team in…", stackRoot) { client in try await client.meetNow(id) }
    }

    func delete(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act(nil, stackRoot) { client in
            try await client.delete(id)
            self.selection = nil
            self.detail = nil
        }
    }

    private func act(_ label: String?, _ stackRoot: URL?, _ work: (StartupClient) async throws -> Void) async {
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
        .init(key: "product", name: "Maya Chen", title: "Product Manager", emoji: "🧭", owns: "the problem, MVP scope and success metrics"),
        .init(key: "design", name: "Leo Park", title: "Designer", emoji: "🎨", owns: "onboarding, key screens and brand"),
        .init(key: "engineering", name: "Noah Patel", title: "Engineering Lead", emoji: "🛠️", owns: "architecture and the smallest shippable version"),
        .init(key: "marketing", name: "Ava Brooks", title: "Marketing & Social Lead", emoji: "📣", owns: "positioning, content and launch"),
        .init(key: "automation", name: "Sam Rivera", title: "Marketing Automation", emoji: "⚙️", owns: "funnels, email sequences and lead scoring"),
        .init(key: "sales", name: "Zoe Kim", title: "Head of Sales", emoji: "💼", owns: "the first 10 customers, pricing and pipeline"),
        .init(key: "bizdev", name: "Omar Haddad", title: "Business Development", emoji: "🤝", owns: "partnerships and distribution"),
        .init(key: "finance", name: "Grace Liu", title: "Finance & Fundraising", emoji: "💰", owns: "unit economics, runway and fundraising"),
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
