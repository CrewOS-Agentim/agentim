import Foundation
import Observation

/// Startup Mode as the gateway reports it (`GET /v1/startup`).
struct StartupState: Decodable, Equatable {
    struct Role: Decodable, Equatable, Identifiable {
        let key: String
        let name: String
        let emoji: String
        let focus: String
        var id: String { key }
    }

    struct RoleInfo: Decodable, Equatable {
        let name: String
        let emoji: String
    }

    struct Message: Decodable, Equatable, Identifiable {
        let round: Int
        let role: String
        let content: String
        let ts: Double
        var id: String { "\(round)-\(role)-\(ts)" }
    }

    let configured: Bool
    var idea: String?
    var enabled: Bool?
    var plan: String?
    var min_minutes: Int?
    var max_minutes: Int?
    var next_run: Double?
    var rounds: Int?
    var now: Double?
    var team: [Role]
    var roles: [String: RoleInfo]?
    var messages: [Message]?

    /// Minutes until the next meeting, from the gateway's own clock.
    var minutesToNext: Int? {
        guard enabled == true, let next_run, let now else { return nil }
        return max(0, Int(((next_run - now) / 60).rounded(.up)))
    }

    func role(_ key: String) -> RoleInfo { roles?[key] ?? RoleInfo(name: key.capitalized, emoji: "🤖") }
}

/// Talks to the gateway's Startup Mode API on this Mac.
struct StartupClient {
    var baseURL = URL(string: "http://localhost:8780")!
    var token: String

    func state() async throws -> StartupState {
        try await send("v1/startup", body: nil)
    }

    func start(idea: String, minMinutes: Int, maxMinutes: Int) async throws -> StartupState {
        try await send("v1/startup", body: ["idea": idea, "min_minutes": minMinutes, "max_minutes": maxMinutes, "enabled": true])
    }

    func pause() async throws -> StartupState {
        try await send("v1/startup", body: ["enabled": false])
    }

    func meetNow() async throws {
        var request = makeRequest("v1/startup/run")
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        _ = try await check(URLSession.shared.data(for: request))
    }

    private func makeRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        return request
    }

    private func send<T: Decodable>(_ path: String, body: [String: Any]?) async throws -> T {
        var request = makeRequest(path)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data = try await check(URLSession.shared.data(for: request))
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func check(_ result: (Data, URLResponse)) throws -> Data {
        let (data, response) = result
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
    private(set) var state: StartupState?
    private(set) var error: String?
    private(set) var busy = false
    var draftIdea = ""
    var minMinutes = 10
    var maxMinutes = 30

    private var timer: Timer?
    private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo { state = Self.demoState }
    }

    var isRunning: Bool { state?.enabled == true }

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
            state = try await client.state()
            error = nil
            if let idea = state?.idea, draftIdea.isEmpty { draftIdea = idea }
        } catch {
            self.error = "Can't reach agentim's gateway. Start the stack in This Mac. (\(error.localizedDescription))"
        }
    }

    func start(stackRoot: URL?) async {
        await act(stackRoot) { try await $0.start(idea: self.draftIdea, minMinutes: self.minMinutes, maxMinutes: self.maxMinutes) }
    }

    func pause(stackRoot: URL?) async {
        await act(stackRoot) { try await $0.pause() }
    }

    func meetNow(stackRoot: URL?) async {
        guard let client = Self.client(stackRoot: stackRoot) else { return }
        busy = true
        defer { busy = false }
        do { try await client.meetNow() } catch { self.error = error.localizedDescription }
    }

    private func act(_ stackRoot: URL?, _ call: (StartupClient) async throws -> StartupState) async {
        guard !isDemo, let client = Self.client(stackRoot: stackRoot) else { return }
        busy = true
        defer { busy = false }
        do {
            state = try await call(client)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static let demoState: StartupState = {
        let now = Date().timeIntervalSince1970
        let roles: [String: StartupState.RoleInfo] = [
            "sales": .init(name: "Sales", emoji: "💼"), "bizdev": .init(name: "Business Development", emoji: "🤝"),
            "marketing": .init(name: "Marketing & Social", emoji: "📣"), "automation": .init(name: "Marketing Automation", emoji: "⚙️"),
            "engineering": .init(name: "Engineering", emoji: "🛠️"), "product": .init(name: "Product", emoji: "🧭"),
            "design": .init(name: "Design", emoji: "🎨"), "finance": .init(name: "Finance & Fundraising", emoji: "💰"),
            "chief": .init(name: "Chief of Staff", emoji: "🗂️"),
        ]
        let team = roles.filter { $0.key != "chief" }.map { StartupState.Role(key: $0.key, name: $0.value.name, emoji: $0.value.emoji, focus: "") }
            .sorted { $0.name < $1.name }
        let messages: [StartupState.Message] = [
            .init(round: 3, role: "sales", content: "The first buyers are landlords of shared workspaces, not office managers: one contract covers 40 desks. Pitch: \"happier tenants, zero plant care\". This week: 15 cold emails to coworking operators in Austin, goal 3 calls. @Finance can we price per floor instead of per plant?", ts: now - 1_500),
            .init(round: 3, role: "finance", content: "Per-floor pricing works: $290/floor/month, 62% gross margin at 2 swaps/month. CAC must stay under $900 to pay back in 6 months. @Marketing Automation track cost per booked call from day one.", ts: now - 1_380),
            .init(round: 3, role: "automation", content: "Set up a 3-step email sequence for workspace operators (photo of a dead plant → ROI calc → 15-min call link). Score leads by desks > 30. @Design we need a one-page ROI calculator.", ts: now - 1_250),
            .init(round: 3, role: "chief", content: "Target coworking landlords with per-floor pricing ($290). Next action: Sales sends 15 emails using the new sequence; Design ships the ROI page by Friday.", ts: now - 1_100),
        ]
        return StartupState(
            configured: true,
            idea: "A monthly subscription that delivers and swaps office plants so offices always look alive.",
            enabled: true,
            plan: """
            # Office plant subscription

            ## Top 3 priorities
            1. Sell to coworking landlords (one contract, many desks)
            2. Price per floor: $290/month, 62% margin
            3. 3 paid pilots in Austin by month end

            ## By area
            ### 💼 Sales
            - 15 cold emails/week to coworking operators, goal 3 calls
            ### 🎨 Design
            - One-page ROI calculator for operators
            ### ⚙️ Marketing Automation
            - 3-step email sequence, lead score = desks > 30

            ## Experiments this week
            - Pre-sell 3 pilots at 50% off the first month

            ## Open questions
            - Do we own the plants or lease them?
            """,
            min_minutes: 10, max_minutes: 30, next_run: now + 14 * 60, rounds: 3, now: now,
            team: team, roles: roles, messages: messages)
    }()
}
