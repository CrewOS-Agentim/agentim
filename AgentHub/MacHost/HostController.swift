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
    /// agentim's containers as `docker ps` sees them (running or not).
    private(set) var containers: [Container] = []

    struct Container: Identifiable, Equatable {
        let name: String      // agentim-ollama-1
        let service: String   // ollama
        let state: String     // running / exited / restarting
        let status: String    // "Up 2 hours (healthy)"
        var id: String { name }
        var isRunning: Bool { state == "running" }
    }

    /// Where logs come from: a container, or the native runner on this Mac (LTX, local coding agents).
    enum LogSource: Hashable, Identifiable {
        case container(String)  // compose service name
        case nativeRunner
        var id: String { title }
        var title: String {
            switch self {
            case .container(let service): service
            case .nativeRunner: "runner (this Mac)"
            }
        }
    }

    /// The log the Logs window shows.
    var logSource: LogSource = .container("ollama")
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
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        guard !isDemo else { return }
        dockerRunning = await Shell.run(["docker", "info", "--format", "{{.ServerVersion}}"]).ok
        if dockerRunning, let root = stackRoot {
            let ps = await Shell.run(["docker", "compose", "ps", "--all", "--format", "json"], in: root)
            services = ps.ok ? Self.parseComposePS(ps.output) : []
            let docker = await Shell.run(["docker", "ps", "--all", "--filter", "label=com.docker.compose.project=agentim",
                                          "--format", "{{json .}}"])
            containers = docker.ok ? Self.parseDockerPS(docker.output) : []
        } else {
            services = []
            containers = []
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

    /// GET a runner endpoint with the stack's token (nil if it isn't reachable).
    func runnerData(_ port: Int, _ path: String) async -> Data? { await runner(port, path) }

    private func runner(_ port: Int, _ path: String, post: Bool = false, body: [String: Any]? = nil) async -> Data? {
        guard let token = runnerToken, let url = URL(string: "http://localhost:\(port)/\(path)") else { return nil }
        let post = post || body != nil
        var request = URLRequest(url: url, timeoutInterval: post ? 180 : 5)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if post {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
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

    /// What the launch check is doing ("Starting your models…"), shown in the status bar; nil when ready.
    private(set) var startupNote: String?

    /// On launch: Docker and the agentim containers up, this Mac's runners added, local Claude Code and Codex
    /// enabled, agentim connected to Claude, then wait for the models and preload the default one.
    func bringUp(store: AppStore) async {
        guard !isDemo, let root = stackRoot,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".env").path) else { return }
        startupNote = "Starting agentim…"
        defer { startupNote = nil }
        if !(await Shell.run(["docker", "info", "--format", "{{.ServerVersion}}"]).ok) {
            startupNote = "Starting Docker…"
            startDocker()
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(2))
                if await Shell.run(["docker", "info", "--format", "{{.ServerVersion}}"]).ok { break }
            }
        }
        await refresh()
        if dockerRunning, services.isEmpty || services.contains(where: { !$0.isRunning }) {
            startupNote = "Starting your models…"
            let result = await Shell.run(["docker", "compose", "up", "-d"], in: root)
            if !result.ok { lastError = String(result.output.suffix(400)) }
            await refresh()
        }
        if store.servers.isEmpty { connectThisMac(to: store) }
        await enableLocalAgents()
        await connectClaudeIfNeeded()
        await syncCloudKeys(store: store)
        startupNote = "Waiting for the models…"
        for _ in 0..<40 {
            await store.refreshServers()
            if store.hasChatModel { break }
            try? await Task.sleep(for: .seconds(3))
        }
        await preloadDefaultModel(store: store)
    }

    /// The Claude and ChatGPT (OpenAI) keys saved in the app also go to the gateway's .env (git-ignored), and the
    /// gateway restarts to pick them up, so startups and Telegram/WhatsApp/Slack can use Claude and ChatGPT too.
    func syncCloudKeys(store: AppStore) async {
        guard let env = stackRoot?.appendingPathComponent(".env"),
              let text = try? String(contentsOf: env, encoding: .utf8), let root = stackRoot else { return }
        var updated = text
        for (provider, name) in [(Provider.anthropic, "ANTHROPIC_API_KEY"), (Provider.openAI, "OPENAI_API_KEY")] {
            if let key = store.apiKey(for: provider), !key.isEmpty {
                updated = Self.withEnv(name, key, in: updated)
            }
        }
        guard updated != text else { return }
        try? updated.write(to: env, atomically: true, encoding: .utf8)
        _ = await Shell.run(["docker", "compose", "up", "-d", "--no-deps", "gateway"], in: root)
    }

    /// Sets `name=value` in a .env text (replacing the line, or adding it).
    nonisolated static func withEnv(_ name: String, _ value: String, in env: String) -> String {
        var lines = env.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("\(name)=") }) {
            if lines[i] == "\(name)=\(value)" { return env }
            lines[i] = "\(name)=\(value)"
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("\(name)=\(value)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Turns on the coding agents installed on this Mac (Claude Code, Codex for ChatGPT) for chats and startups.
    func enableLocalAgents() async {
        guard let env = stackRoot?.appendingPathComponent(".env"),
              let text = try? String(contentsOf: env, encoding: .utf8) else { return }
        var installed: [String] = []
        for (name, bin) in [("claude-code", "claude"), ("codex", "codex")]
        where await Shell.run(["/bin/zsh", "-lc", "command -v \(bin)"]).ok {
            installed.append(name)
        }
        let updated = Self.withLocalAgents(installed, in: text)
        if updated != text { try? updated.write(to: env, atomically: true, encoding: .utf8) }
    }

    /// Adds `agents` to AGENTIM_LOCAL_AGENTS (keeping what's there, never removing).
    nonisolated static func withLocalAgents(_ agents: [String], in env: String) -> String {
        guard !agents.isEmpty else { return env }
        var lines = env.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("AGENTIM_LOCAL_AGENTS=") }) {
            var current = String(lines[i].dropFirst("AGENTIM_LOCAL_AGENTS=".count)).split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let missing = agents.filter { !current.contains($0) }
            guard !missing.isEmpty else { return env }
            current += missing
            lines[i] = "AGENTIM_LOCAL_AGENTS=" + current.joined(separator: ",")
        } else {
            if lines.last == "" { lines.removeLast() }
            lines.append("AGENTIM_LOCAL_AGENTS=" + agents.joined(separator: ","))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// agentim in Claude (Desktop and Code), if it isn't there yet. Local only: no tunnel, nothing public.
    func connectClaudeIfNeeded() async {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        let desktop = (try? Data(contentsOf: config)).map(Self.configHasAgentim) ?? false
        let code = await Shell.run(["/bin/zsh", "-lc", "command -v claude >/dev/null && claude mcp get agentim"]).ok
        let hasClaudeCode = await Shell.run(["/bin/zsh", "-lc", "command -v claude"]).ok
        if !desktop || (hasClaudeCode && !code) { await connectClaude() }
    }

    /// Loads the model chats will use first, so the first answer doesn't wait for it.
    func preloadDefaultModel(store: AppStore) async {
        guard let decision = try? ModelRouter(available: store.availableModels, settings: store.router).route(
            RoutingRequest(text: "Hello", history: [], agent: store.agents.first, conversationPin: nil, isOnline: true)),
              decision.model.serverID != nil, !decision.model.capabilities.contains(.agent) else { return }
        startupNote = "Loading \(decision.model.displayName)…"
        _ = await runner(8765, "v1/models/load", body: ["model": decision.model.modelName])
    }

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
    /// `docker ps --format '{{json .}}'` lines → containers, by compose service.
    nonisolated static func parseDockerPS(_ output: String) -> [Container] {
        struct Row: Decodable {
            let Names: String
            let State: String
            let Status: String
            let Labels: String?
        }
        return output.split(separator: "\n").compactMap { line -> Container? in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)) else { return nil }
            let service = (row.Labels ?? "").split(separator: ",")
                .first { $0.hasPrefix("com.docker.compose.service=") }
                .map { String($0.dropFirst("com.docker.compose.service=".count)) } ?? row.Names
            return Container(name: row.Names, service: service, state: row.State, status: row.Status)
        }
        .sorted { $0.service < $1.service }
    }

    // MARK: - Logs

    static let nativeRunnerLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/agentim/runner.log")

    var logSources: [LogSource] {
        containers.map { LogSource.container($0.service) } + [.nativeRunner]
    }

    /// The last `lines` lines of a log (stdout and stderr together).
    func logs(_ source: LogSource, lines: Int = 300) async -> String {
        switch source {
        case .container(let service):
            guard let container = containers.first(where: { $0.service == service }) else {
                return "\(service) isn't created yet. Start the stack in This Mac."
            }
            let result = await Shell.run(["docker", "logs", "--tail", String(lines), "--timestamps", container.name])
            return result.output.isEmpty ? "(no output yet)" : result.output
        case .nativeRunner:
            guard let text = try? String(contentsOf: Self.nativeRunnerLog, encoding: .utf8) else {
                return "No log yet at \(Self.nativeRunnerLog.path). Install the always-on helpers in This Mac."
            }
            return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        }
    }

    /// Follows the log live in Terminal.
    func openLogsInTerminal(_ source: LogSource) {
        switch source {
        case .container(let service):
            guard let container = containers.first(where: { $0.service == service }) else { return }
            Shell.runInTerminal("docker logs -f --tail 200 \(container.name)")
        case .nativeRunner:
            Shell.runInTerminal("tail -n 200 -f '\(Self.nativeRunnerLog.path)'")
        }
    }

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
        containers = [
            Container(name: "agentim-gateway-1", service: "gateway", state: "running", status: "Up 3 hours (healthy)"),
            Container(name: "agentim-ollama-1", service: "ollama", state: "running", status: "Up 3 hours"),
            Container(name: "agentim-runner-1", service: "runner", state: "running", status: "Up 3 hours"),
            Container(name: "agentim-voice-1", service: "voice", state: "running", status: "Up 3 hours"),
            Container(name: "agentim-whatsapp-1", service: "whatsapp", state: "running", status: "Up 3 hours"),
        ]
        loadedModels = [LoadedModel(id: "ollama/qwen3-4b", name: "qwen3-4b-instruct-2507", size_bytes: 2_500_000_000)]
        stackRoot = URL(fileURLWithPath: "/Users/you/agentim")
        dockerRunning = true
        services = Self.services.map { Service(name: $0, state: "running", health: $0 == "gateway" ? "healthy" : "") }
        power = .charger
        lidSleepDisabled = true
        helpers = ["watchdog": true, "runner": true, "power": true]
    }
}
