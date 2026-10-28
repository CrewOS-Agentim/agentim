import Foundation
import Observation

/// Drives first-run setup: Docker → model picks → install (stack, models, voice, helpers).
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable { case welcome, docker, models, install, done }

    struct SetupTask: Identifiable, Equatable {
        enum Status: Equatable { case waiting, running(Double?), done, skipped(String), failed(String) }
        var id: String
        var title: String
        var status: Status = .waiting
    }

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingComplete") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingComplete") }
    }

    var step: Step = .welcome
    let docker = DockerSetup()
    var selections: [ModelCategory: String] = [:]
    var keepAwake = true
    private(set) var tasks: [SetupTask] = []
    private(set) var isInstalling = false
    private(set) var log: [String] = []

    let ltxInstalled = FileManager.default.fileExists(atPath: "/Applications/LTX Desktop.app")
    private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo {
            docker.markReadyForDemo(memoryBytes: 32 * 1_073_741_824)
            seedDemo()
        }
    }

    /// What models must fit into: Docker's memory once known, else half the Mac's RAM (Docker's default).
    var memoryBudget: Int64 { docker.memoryBytes ?? DeviceMemory.physicalBytes / 2 }

    func choice(for category: ModelCategory) -> ModelChoice {
        selections[category].flatMap(ModelCatalog.choice(id:))
            ?? ModelCatalog.recommended(for: category, memory: memoryBudget, ltxInstalled: ltxInstalled)
    }

    func recommended(_ category: ModelCategory) -> ModelChoice {
        ModelCatalog.recommended(for: category, memory: memoryBudget, ltxInstalled: ltxInstalled)
    }

    var plan: OnboardingPlan {
        OnboardingPlan(chat: choice(for: .chat), coding: choice(for: .coding),
                       voice: choice(for: .voice), media: choice(for: .media))
    }

    var freeDiskBytes: Int64 { DeviceMemory.freeDiskBytes }
    var enoughDisk: Bool { plan.downloadBytes + 2 * 1_073_741_824 < freeDiskBytes }

    // MARK: - Install

    func install(host: HostController, store: AppStore) async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        let plan = plan
        tasks = [
            SetupTask(id: "stack", title: "Set up agentim's Docker stack"),
            SetupTask(id: "start", title: "Start the containers"),
        ] + plan.ollamaRefs.map { SetupTask(id: $0, title: "Download \(name(for: $0))") }
        if case .voice = plan.voice.kind { tasks.append(SetupTask(id: "voice", title: "Download \(plan.voice.name)")) }
        tasks.append(SetupTask(id: "always-on", title: "Keep agentim running (restart watchdog\(plan.media.kind == .ltx ? " + LTX runner" : ""))"))
        tasks.append(SetupTask(id: "connect", title: "Connect this Mac to the app"))

        do {
            // 1. Files + .env
            update("stack", .running(nil))
            let root = try StackFiles.ensureInstalled(repoRoot: host.stackRoot ?? HostController.findStackRoot())
            host.stackRoot = root
            let envURL = root.appendingPathComponent(".env")
            // Keep the user's .env (tokens, allow-list) and only update the model settings.
            let text = try (try? String(contentsOf: envURL, encoding: .utf8))
                ?? String(contentsOf: root.appendingPathComponent(".env.example"), encoding: .utf8)
            var env = EnvFile(text: text)
            env.fillSecrets()
            plan.apply(to: &env)
            try env.text.write(to: envURL, atomically: true, encoding: .utf8)
            update("stack", .done)

            // 2. Core containers first; voice starts in its own step so a voice problem can't block chat.
            update("start", .running(nil))
            let up = await Shell.run(["docker", "compose", "--progress", "quiet", "up", "-d", "--build"] + Self.coreServices, in: root)
            guard up.ok else { throw SetupError(Self.explainDockerFailure(up.output)) }
            append(up.output)
            update("start", .done)

            // 3. Models through the runner (memory-checked; refuses what doesn't fit).
            let token = env["RUNNER_TOKEN"] ?? ""
            let runner = RunnerClient(server: LocalServer(name: "This Mac (Docker)", baseURL: URL(string: "http://localhost:8765")!), token: token)
            try await waitFor(URL(string: "http://localhost:8765/health")!)
            for ref in plan.ollamaRefs { await pull(ref, with: runner) }

            // 4. Voice models
            if case .voice(let stt, let tts) = plan.voice.kind {
                update("voice", .running(nil))
                do {
                    var voiceUp = await Shell.run(["docker", "compose", "--progress", "quiet", "up", "-d", "voice"], in: root)
                    var listenOnly = false
                    if !voiceUp.ok, Self.isRegistryBlocked(voiceUp.output) {
                        // Some Docker setups only allow Docker Hub: use its build (speech-to-text only).
                        env.set("VOICE_IMAGE", Self.fallbackVoiceImage)
                        env.set("AGENTIM_VOICE_REPLIES", "false")
                        try env.text.write(to: envURL, atomically: true, encoding: .utf8)
                        voiceUp = await Shell.run(["docker", "compose", "--progress", "quiet", "up", "-d", "voice"], in: root)
                        listenOnly = true
                    }
                    guard voiceUp.ok else { throw SetupError(Self.explainDockerFailure(voiceUp.output)) }
                    try await waitFor(URL(string: "http://localhost:8000/health")!, timeout: 600)
                    for model in listenOnly ? [stt] : [stt, tts] { try await downloadVoiceModel(model) }
                    if listenOnly {
                        // The gateway picks up the new voice settings.
                        _ = await Shell.run(["docker", "compose", "--progress", "quiet", "up", "-d", "--no-deps", "gateway"], in: root)
                        update("voice", .skipped("Voice notes are understood; replies stay in text. Your Docker only allows Docker Hub, which has no text-to-speech build."))
                    } else {
                        update("voice", .done)
                    }
                } catch {
                    update("voice", .failed(error.localizedDescription))
                }
            }

            // 5. Always on (no password needed); the lid guard is optional and asks in Terminal.
            update("always-on", .running(nil))
            var args = ["bash", root.appendingPathComponent("deploy/macos/install.sh").path, "--no-power"]
            if plan.media.kind != .ltx { args.append("--no-runner") }
            let helpers = await Shell.run(args, in: root)
            update("always-on", helpers.ok ? .done : .failed(String(helpers.output.suffix(300))))
            if keepAwake { host.installHelpers() }

            // 6. Connect
            update("connect", .running(nil))
            host.connectThisMac(to: store)
            await store.refreshServers()
            update("connect", .done)

            Self.isComplete = true
            step = .done
            await host.refresh()
        } catch {
            if let running = tasks.firstIndex(where: { if case .running = $0.status { true } else { false } }) {
                tasks[running].status = .failed(error.localizedDescription)
            }
        }
    }

    /// Everything except the optional voice service.
    static let coreServices = ["ollama", "runner", "gateway", "whatsapp"]

    /// Turns Docker's pull errors into something a person can act on.
    nonisolated static func explainDockerFailure(_ output: String) -> String {
        let tail = String(output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))
        let lower = output.lowercased()
        if lower.contains("error getting credentials") || lower.contains("denied") || lower.contains("unauthorized") {
            return "Docker couldn't download an image (\(tail)). If a Keychain prompt is open, allow Docker to use it; "
                + "otherwise quit and reopen Docker Desktop (or sign out of it), then press Install again."
        }
        if lower.contains("no space left") {
            return "Docker ran out of disk space. Free some space in Docker Desktop → Settings → Resources, then try again."
        }
        if lower.contains("cannot connect to the docker daemon") || lower.contains("is the docker daemon running") {
            return "Docker isn't running. Open Docker Desktop, wait for it to start, then press Install again."
        }
        return tail
    }

    private func name(for ref: String) -> String {
        ModelCatalog.all.first { $0.ollamaRef == ref }?.name ?? ref
    }

    private func pull(_ ref: String, with runner: RunnerClient) async {
        update(ref, .running(0))
        do {
            for try await event in runner.pull(ref, hfToken: nil) {
                if let message = event.error { throw SetupError(message) }
                if let total = event.total, total > 0, let done = event.completed {
                    update(ref, .running(Double(done) / Double(total)))
                }
            }
            update(ref, .done)
        } catch {
            update(ref, .failed(error.localizedDescription))
        }
    }

    /// Speech-to-text-only voice server on Docker Hub (Speaches' earlier name).
    static let fallbackVoiceImage = "fedirz/faster-whisper-server:0.6.0-rc.3-cpu"

    nonisolated static func isRegistryBlocked(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("denied") || lower.contains("unauthorized") || lower.contains("forbidden")
    }

    private func downloadVoiceModel(_ model: String) async throws {
        let path = model.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._"))) ?? model
        // Current Speaches: POST /v1/models/{id}. Older builds: POST /api/pull/{id}.
        for endpoint in ["v1/models", "api/pull"] {
            var request = URLRequest(url: URL(string: "http://localhost:8000/\(endpoint)/\(path)")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 1800
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) || code == 409 { return }  // 409: already present
            if code == 404, endpoint == "v1/models" { continue }
            throw SetupError("Voice model \(model): HTTP \(code) \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    private func waitFor(_ url: URL, timeout: TimeInterval = 180) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let (_, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(for: .seconds(2))
        }
        throw SetupError("\(url.host() ?? "service"):\(url.port ?? 0) didn't come up. Check Docker Desktop.")
    }

    private func update(_ id: String, _ status: SetupTask.Status) {
        if let i = tasks.firstIndex(where: { $0.id == id }) { tasks[i].status = status }
    }

    private func append(_ output: String) {
        log += output.split(separator: "\n").suffix(20).map(String.init)
    }

    private func seedDemo() {
        selections = [.chat: "chat-qwen3-14b", .coding: "code-qwen2.5-7b", .voice: "voice-small", .media: "media-ltx"]
        if let section = UserDefaults.standard.string(forKey: "onboardingStep"),
           let value = ["welcome": Step.welcome, "docker": .docker, "models": .models, "install": .install, "done": .done][section] {
            step = value
        }
        tasks = [
            SetupTask(id: "stack", title: "Set up agentim's Docker stack", status: .done),
            SetupTask(id: "start", title: "Start the containers", status: .done),
            SetupTask(id: "chat", title: "Download Qwen3 14B", status: .done),
            SetupTask(id: "code", title: "Download Qwen2.5 Coder 7B", status: .running(0.62)),
            SetupTask(id: "voice", title: "Download Whisper Small + Kokoro"),
            SetupTask(id: "always-on", title: "Keep agentim running (restart watchdog + LTX runner)"),
            SetupTask(id: "connect", title: "Connect this Mac to the app"),
        ]
    }
}
