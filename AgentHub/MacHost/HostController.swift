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
    static let optionalServices = ["voice", "tunnel"]
    static let helperPlists = [
        "watchdog": "~/Library/LaunchAgents/com.agentim.watchdog.plist",
        "runner": "~/Library/LaunchAgents/com.agentim.runner.plist",
        "power": "/Library/LaunchDaemons/com.agentim.power.plist",
    ]

    var stackRoot: URL? {
        // Demo mode (screenshots) must never overwrite the real setting.
        didSet { if !isDemo { UserDefaults.standard.set(stackRoot?.path, forKey: "stackRoot") } }
    }
    private(set) var dockerRunning = false
    private(set) var services: [Service] = []
    private(set) var power: Power = .unknown
    private(set) var lidSleepDisabled = false
    private(set) var helpers: [String: Bool] = [:]
    private(set) var busy: String?
    private(set) var lastError: String?
    /// The ChatGPT connector URL while the tunnel is up (it contains the MCP secret: show, don't log).
    private(set) var chatGPTConnectorURL: String?
    private(set) var connectorNote: String?
    /// Models in memory right now (from the Docker runner) and whether LTX Desktop is running (native runner).
    private(set) var loadedModels: [LoadedModel] = []
    private(set) var ltxRunning = false

    struct LoadedModel: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let size_bytes: Int64?
        var gigabytes: String { String(format: "%.1f GB", Double(size_bytes ?? 0) / 1_000_000_000) }
    }

    var memoryInUse: String {
        String(format: "%.1f GB", Double(loadedModels.compactMap(\.size_bytes).reduce(0, +)) / 1_000_000_000)
    }
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
        stackRoot = Self.validStackRoot(UserDefaults.standard.string(forKey: "stackRoot")) ?? Self.findStackRoot()
        if demo { seedDemo() }
    }

    /// Services Compose created: the core four, plus voice when it's enabled.
    var expectedCount: Int { max(Self.services.count, services.count) }

    var summary: String {
        if !dockerRunning { return "Docker is off" }
        let up = services.filter(\.isRunning).count
        return up == expectedCount ? "All \(up) services running" : "\(up)/\(expectedCount) services running"
    }

    var isHealthy: Bool { dockerRunning && services.filter(\.isRunning).count == expectedCount }

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
        await refreshMemory()
        power = Self.parsePower(await Shell.run(["pmset", "-g", "ps"]).output)
        lidSleepDisabled = Self.parseSleepDisabled(await Shell.run(["pmset", "-g"]).output)
        helpers = Self.helperPlists.mapValues {
            FileManager.default.fileExists(atPath: NSString(string: $0).expandingTildeInPath)
        }
    }

    // MARK: - Memory: models and LTX

    private var runnerToken: String? {
        guard let root = stackRoot,
              let env = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
        else { return nil }
        return Self.parseEnv(env)["RUNNER_TOKEN"]
    }

    private func runner(_ port: Int, _ path: String, post: Bool = false) async -> Data? {
        guard let token = runnerToken, let url = URL(string: "http://localhost:\(port)/\(path)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: post ? 90 : 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if post {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    struct LoadedResponse: Decodable { let models: [LoadedModel]; let ltx_running: Bool? }

    func refreshMemory() async {
        if let data = await runner(8765, "v1/models/loaded"),
           let loaded = try? JSONDecoder().decode(LoadedResponse.self, from: data) {
            loadedModels = loaded.models
        } else {
            loadedModels = []
        }
        if let data = await runner(8766, "v1/models/loaded"),
           let native = try? JSONDecoder().decode(LoadedResponse.self, from: data) {
            ltxRunning = native.ltx_running ?? false
        }
    }

    /// Unloads every model from memory now; they load again on the next chat.
    func freeMemory() async {
        busy = "Freeing memory…"
        defer { busy = nil }
        _ = await runner(8765, "v1/models/unload", post: true)
        await refreshMemory()
    }

    /// Quits LTX Desktop (it opens again by itself when someone asks for a video or image).
    func stopLTX() async {
        busy = "Stopping LTX…"
        defer { busy = nil }
        _ = await runner(8766, "v1/ltx/stop", post: true)
        try? await Task.sleep(for: .seconds(2))
        await refreshMemory()
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

    // MARK: - Claude & ChatGPT connectors (agentim as an MCP server)

    static let claudeDesktopConfig = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")

    /// Claude Desktop's config already lists agentim.
    var claudeConnected: Bool {
        guard let data = try? Data(contentsOf: Self.claudeDesktopConfig) else { return false }
        return Self.configHasAgentim(data)
    }

    nonisolated static func configHasAgentim(_ data: Data) -> Bool {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["mcpServers"] as? [String: Any])?["agentim"] != nil
    }

    func connectClaude(remove: Bool = false) async {
        guard let root = stackRoot else { lastError = "Choose the agentim folder first."; return }
        busy = remove ? "Disconnecting Claude…" : "Connecting Claude…"
        defer { busy = nil }
        let result = await Shell.run(["bash", "deploy/macos/connect-claude.sh"] + (remove ? ["remove"] : []), in: root)
        if result.ok {
            lastError = nil
            connectorNote = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            lastError = String(result.output.suffix(400))
        }
    }

    func connectChatGPT() async {
        guard let root = stackRoot else { lastError = "Choose the agentim folder first."; return }
        busy = "Opening a tunnel for ChatGPT…"
        defer { busy = nil }
        let result = await Shell.run(["bash", "deploy/macos/connect-chatgpt.sh"], in: root)
        let url = result.output.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        if result.ok, let url, url.hasPrefix("https://") {
            chatGPTConnectorURL = url
            lastError = nil
        } else {
            lastError = String(result.output.suffix(400))
        }
    }

    func disconnectChatGPT() async {
        guard let root = stackRoot else { return }
        busy = "Closing the ChatGPT tunnel…"
        defer { busy = nil }
        _ = await Shell.run(["bash", "deploy/macos/connect-chatgpt.sh", "stop"], in: root)
        chatGPTConnectorURL = nil
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
    /// A saved stack folder is only trusted if it still holds the compose file.
    nonisolated static func validStackRoot(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("docker-compose.yml").path) ? url : nil
    }

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
