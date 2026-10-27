import AppKit
import Foundation
import Observation
import ServiceManagement

/// The Mac as agentim's always-on host: the Docker stack, power, helpers, launch at login.
@MainActor
@Observable
final class HostController {
    struct Service: Identifiable, Equatable {
        var name: String
        var state: String
        var health: String
        var id: String { name }
        var isRunning: Bool { state == "running" }
    }

    enum Power: Equatable { case charger, battery, unknown }

    static let services = ["ollama", "runner", "gateway", "whatsapp"]
    static let helperPlists = [
        "watchdog": "~/Library/LaunchAgents/com.agentim.watchdog.plist",
        "runner": "~/Library/LaunchAgents/com.agentim.runner.plist",
        "power": "/Library/LaunchDaemons/com.agentim.power.plist",
    ]

    var stackRoot: URL? {
        didSet { UserDefaults.standard.set(stackRoot?.path, forKey: "stackRoot") }
    }
    private(set) var dockerRunning = false
    private(set) var services: [Service] = []
    private(set) var power: Power = .unknown
    private(set) var lidSleepDisabled = false
    private(set) var helpers: [String: Bool] = [:]
    private(set) var busy: String?
    private(set) var lastError: String?
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                lastError = "Launch at login: \(error.localizedDescription)"
            }
        }
    }

    private var timer: Timer?
    private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if let saved = UserDefaults.standard.string(forKey: "stackRoot") {
            stackRoot = URL(fileURLWithPath: saved)
        } else {
            stackRoot = Self.findStackRoot()
        }
        if demo { seedDemo() }
    }

    var summary: String {
        if !dockerRunning { return "Docker is off" }
        let up = services.filter(\.isRunning).count
        return up == Self.services.count ? "All \(up) services running" : "\(up)/\(Self.services.count) services running"
    }

    var isHealthy: Bool { dockerRunning && services.filter(\.isRunning).count == Self.services.count }

    // MARK: - Polling

    func startPolling() {
        guard timer == nil, !isDemo else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isDemo else { return }
        dockerRunning = await Shell.run(["docker", "info", "--format", "{{.ServerVersion}}"]).ok
        if dockerRunning, let root = stackRoot {
            let ps = await Shell.run(["docker", "compose", "ps", "--all", "--format", "json"], in: root)
            services = ps.ok ? Self.parseComposePS(ps.output) : []
        } else {
            services = []
        }
        power = Self.parsePower(await Shell.run(["pmset", "-g", "ps"]).output)
        lidSleepDisabled = Self.parseSleepDisabled(await Shell.run(["pmset", "-g"]).output)
        helpers = Self.helperPlists.mapValues {
            FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath)
        }
    }

    // MARK: - Actions

    func start() async { await compose(["up", "-d", "--build"], label: "Starting…") }
    func stop() async { await compose(["stop"], label: "Stopping…") }
    func restart() async { await compose(["restart"], label: "Restarting…") }

    func startDocker() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Docker.app"))
    }

    private func compose(_ arguments: [String], label: String) async {
        guard let root = stackRoot else { lastError = "Choose the agentim folder first."; return }
        busy = label
        defer { busy = nil }
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(".env").path) {
            lastError = "No .env yet. Run “Install always-on helpers” once, or copy .env.example to .env."
            return
        }
        let result = await Shell.run(["docker", "compose"] + arguments, in: root)
        lastError = result.ok ? nil : String(result.output.suffix(400))
        await refresh()
    }

    func installHelpers() {
        guard let root = stackRoot else { return }
        Shell.runInTerminal("cd '\(root.path)' && ./deploy/macos/install.sh")
    }

    func openWhatsAppQR() { NSWorkspace.shared.open(URL(string: "http://localhost:3000/dashboard")!) }

    func openLogs() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/agentim")
        NSWorkspace.shared.open(logs)
    }

    func editSettings() {
        guard let env = stackRoot?.appendingPathComponent(".env") else { return }
        NSWorkspace.shared.open(env)
    }

    func chooseStackRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the agentim folder (the one with docker-compose.yml)"
        if panel.runModal() == .OK, let url = panel.url { stackRoot = url }
    }

    /// Adds this Mac's runners as servers: Docker (Hugging Face models) and native (LTX video).
    func connectThisMac(to store: AppStore) {
        guard let root = stackRoot,
              let env = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8),
              let token = Self.parseEnv(env)["RUNNER_TOKEN"], !token.isEmpty
        else {
            lastError = "Couldn't read RUNNER_TOKEN from .env."
            return
        }
        let targets = [("This Mac (Docker)", "http://localhost:8765"), ("This Mac (LTX)", "http://localhost:8766")]
        for (name, url) in targets where !store.servers.contains(where: { $0.baseURL.absoluteString == url }) {
            store.saveServer(LocalServer(name: name, baseURL: URL(string: url)!), token: token)
        }
    }

    // MARK: - Parsing (pure, unit-tested)

    /// `docker compose ps --format json` prints one object per line (newer) or one array (older).
    nonisolated static func parseComposePS(_ output: String) -> [Service] {
        struct Row: Decodable {
            let Service: String
            let State: String
            let Health: String?
        }
        let decoder = JSONDecoder()
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [Row] = []
        if trimmed.hasPrefix("["), let all = try? decoder.decode([Row].self, from: Data(trimmed.utf8)) {
            rows = all
        } else {
            rows = trimmed.split(separator: "\n").compactMap { try? decoder.decode(Row.self, from: Data($0.utf8)) }
        }
        return rows.map { Service(name: $0.Service, state: $0.State, health: $0.Health ?? "") }
            .sorted { $0.name < $1.name }
    }

    nonisolated static func parsePower(_ output: String) -> Power {
        if output.contains("'AC Power'") { return .charger }
        if output.contains("'Battery Power'") { return .battery }
        return .unknown
    }

    /// pmset omits SleepDisabled when it's off.
    nonisolated static func parseSleepDisabled(_ output: String) -> Bool {
        output.split(separator: "\n").contains {
            let parts = $0.split(whereSeparator: \.isWhitespace)
            return parts.first == "SleepDisabled" && parts.last == "1"
        }
    }

    nonisolated static func parseEnv(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        }
        return values
    }

    /// Walks up from the app (e.g. a build inside the repo) looking for the agentim checkout.
    nonisolated static func findStackRoot(from start: URL = Bundle.main.bundleURL) -> URL? {
        var url = start
        for _ in 0..<12 {
            let compose = url.appendingPathComponent("docker-compose.yml")
            if FileManager.default.fileExists(atPath: compose.path),
               FileManager.default.fileExists(atPath: url.appendingPathComponent("gateway").path) {
                return url
            }
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return nil
    }

    private func seedDemo() {
        stackRoot = URL(fileURLWithPath: "/Users/you/agentim")
        dockerRunning = true
        services = Self.services.map { Service(name: $0, state: "running", health: $0 == "gateway" ? "healthy" : "") }
        power = .charger
        lidSleepDisabled = true
        helpers = ["watchdog": true, "runner": true, "power": true]
    }
}
