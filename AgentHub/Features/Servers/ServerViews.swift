import SwiftUI

/// Add or edit a computer that serves models.
struct ServerEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var server: LocalServer
    @State private var urlText = ""
    @State private var token = ""
    @State private var test: Result<String, Error>?
    @State private var isTesting = false

    private struct Preset: Identifiable {
        let name: String
        let port: Int
        let path: String
        var id: String { name }
    }

    private let presets = [
        Preset(name: "Ollama", port: 11434, path: "/v1"),
        Preset(name: "LM Studio", port: 1234, path: "/v1"),
        Preset(name: "Docker Model Runner", port: 12434, path: "/engines/v1"),
        Preset(name: "llama.cpp", port: 8080, path: "/v1"),
        Preset(name: "vLLM", port: 8000, path: "/v1"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $server.kind) {
                        ForEach(LocalServer.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(server.kind == .runner
                         ? "Run `python3 runner.py` (or `docker compose up`) from the runner folder. It prints the URL and token to use here. The runner reports the computer's memory, checks models fit before pulling, and bridges LTX Desktop."
                         : "Connect straight to any OpenAI-compatible server on your network. Chat only: no memory check or pulls.")
                }

                Section("Connection") {
                    TextField("Name", text: $server.name)
                    TextField(server.kind == .runner ? "http://my-mac.local:8765" : "http://my-mac.local:11434/v1", text: $urlText)
                        .autocorrectionDisabled()
                    SecureField(server.kind == .runner ? "Pairing token" : "API key (optional)", text: $token)
                        .autocorrectionDisabled()
                }

                if server.kind == .openAICompatible {
                    Section("Presets") {
                        ForEach(presets) { preset in
                            Button(preset.name) {
                                let host = URL(string: urlText)?.host() ?? "my-mac.local"
                                urlText = "http://\(host):\(preset.port)\(preset.path)"
                                if server.name.isEmpty { server.name = preset.name }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await runTest() }
                    } label: {
                        if isTesting { ProgressView() } else { Text("Test connection") }
                    }
                    .disabled(parsedURL == nil || isTesting)
                    switch test {
                    case .success(let summary)?: Label(summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure(let error)?: Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    case nil: EmptyView()
                    }
                }
            }
            .navigationTitle(server.name.isEmpty ? "Local Server" : server.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let url = parsedURL else { return }
                        server.baseURL = url
                        if server.name.isEmpty { server.name = url.host() ?? "Server" }
                        store.saveServer(server, token: token)
                        dismiss()
                    }
                    .disabled(parsedURL == nil)
                }
            }
            .onAppear {
                if urlText.isEmpty, server.baseURL.host() != nil { urlText = server.baseURL.absoluteString }
                token = store.serverToken(server) ?? ""
            }
        }
    }

    private var parsedURL: URL? {
        let text = urlText.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true, url.host() != nil else { return nil }
        return url
    }

    private func runTest() async {
        guard let url = parsedURL else { return }
        isTesting = true
        defer { isTesting = false }
        var candidate = server
        candidate.baseURL = url
        let client = RunnerClient(server: candidate, token: token)
        do {
            let models = try await client.models()
            if candidate.kind == .runner {
                let system = try await client.system()
                let memory = MemoryAssessment.format(system.memory.total_bytes)
                test = .success("\(system.hostname): \(memory) RAM, \(models.count) models\(system.ltx ? ", LTX ready" : "")")
            } else {
                test = .success("Connected: \(models.count) models")
            }
        } catch {
            test = .failure(error)
        }
    }
}

/// One server's block in the Models tab.
struct ServerSection: View {
    @Environment(AppStore.self) private var store
    let server: LocalServer
    /// The base model a LoRA adapter is being added to (opens the sheet).
    @State private var loraBase: LoRABase?

    struct LoRABase: Identifiable { let id: String }

    var body: some View {
        Section {
            switch store.serverStatus[server.id] {
            case .online(let system?)?:
                HostMemoryRow(system: system)
            case .offline(let message)?:
                Label(message, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.red)
            case .checking?:
                ProgressView()
            default:
                EmptyView()
            }
            ForEach(store.models(on: server)) { model in
                ModelRow(model: model, available: isOnline)
                    .contextMenu {
                        if model.modelName.hasPrefix("ollama/hf.co/") {
                            Button("Add LoRA adapter…", systemImage: "plus.square.on.square") { loraBase = LoRABase(id: model.modelName) }
                        }
                    }
                    .swipeActions {
                        if server.kind == .runner, model.modelName.hasPrefix("ollama/") || model.modelName.hasPrefix("lora/") {
                            Button("Delete", role: .destructive) {
                                Task { try? await store.deleteServerModel(model) }
                            }
                        }
                    }
            }
            if server.kind == .runner {
                NavigationLink { PullModelView(server: server) } label: {
                    Label("Pull a model", systemImage: "arrow.down.circle")
                }
                if let first = store.models(on: server).first(where: { $0.modelName.hasPrefix("ollama/hf.co/") }) {
                    Button { loraBase = LoRABase(id: first.modelName) } label: {
                        Label("Add a LoRA adapter", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.borderless)
                    .help("A small add-on from Hugging Face that teaches a model a style or a domain; runs with llama.cpp on the GPU")
                }
            }
        } header: {
            HStack {
                Label(server.name, systemImage: "desktopcomputer")
                Spacer()
                Text(isOnline ? "Online" : "Offline").foregroundStyle(isOnline ? .green : .secondary)
            }
        }
        .sheet(item: $loraBase) { AddLoRASheet(base: $0.id) }
    }

    private var isOnline: Bool {
        if case .online? = store.serverStatus[server.id] { return true }
        return false
    }
}

/// The Add LoRA sheet (its own navigation, a Done button).
struct AddLoRASheet: View {
    let base: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddLoRAView(base: base)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .frame(minWidth: 560, minHeight: 600)
    }
}

private struct HostMemoryRow: View {
    let system: RunnerClient.System

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text("\(MemoryAssessment.format(system.memory.available_bytes)) free")
            } label: {
                Label("\(system.hostname) · \(MemoryAssessment.format(system.memory.total_bytes))",
                      systemImage: system.in_container ? "shippingbox" : "memorychip")
            }
            ProgressView(value: Double(system.memory.total_bytes - system.memory.available_bytes),
                         total: Double(max(1, system.memory.total_bytes)))
            HStack(spacing: 6) {
                ForEach(system.backends.filter(\.value.healthy).keys.sorted(), id: \.self) { Tag(text: $0, symbol: "server.rack") }
                if system.ltx { Tag(text: "LTX", symbol: "film") }
                if system.in_container { Tag(text: "Docker", symbol: "shippingbox") }
            }
        }
        .font(.subheadline)
    }
}

/// Pick a model, see whether the server can hold it, then pull it with live progress.
struct PullModelView: View {
    @Environment(AppStore.self) private var store
    let server: LocalServer
    /// Prefilled (and checked) when opened from a skill's model suggestions.
    var initialReference = ""
    @State private var reference = ""
    @State private var check: RunnerClient.Check?
    @State private var error: String?
    @State private var isChecking = false
    @State private var progress: Double?
    @State private var status = ""

    private let suggestions = [
        "qwen3:4b", "qwen3:14b", "llama3.2:3b", "gemma3:12b", "qwen2.5-coder:7b", "deepseek-r1:8b",
        "hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
    ]

    var body: some View {
        Form {
            Section {
                TextField("qwen3:4b or hf.co/user/repo:Q4_K_M", text: $reference)
                        .autocorrectionDisabled()
                    .onSubmit { Task { await runCheck() } }
                Button("Check memory") { Task { await runCheck() } }
                    .disabled(reference.isEmpty || isChecking)
            } header: {
                Text("Ollama model or Hugging Face GGUF")
            } footer: {
                Text("Sizes are looked up before anything downloads.")
            }

            if isChecking { ProgressView("Checking size…") }
            if let error { Text(error).foregroundStyle(.red) }

            if let check {
                Section("Will it run on \(server.name)?") {
                    AssessmentView(assessment: check.assessment)
                    LabeledContent("Download", value: MemoryAssessment.format(check.weight_bytes))
                    if let gpu = check.fits_gpu {
                        LabeledContent("Fits in GPU memory", value: gpu ? "Yes" : "No, part will run on CPU")
                    }
                }
                Section {
                    if let progress {
                        ProgressView(value: progress) { Text(status) }
                    } else {
                        Button("Pull \(reference)", systemImage: "arrow.down.circle.fill") { pull() }
                            .disabled(!check.can_pull)
                    }
                }
            }

            Section("Suggestions") {
                ForEach(suggestions, id: \.self) { name in
                    Button(name) {
                        reference = name
                        Task { await runCheck() }
                    }
                }
            }

            Section("For design, frontend and screenshots") {
                ForEach(SkillModels.all.filter { $0.ollamaRef != nil }) { model in
                    Button {
                        reference = model.ollamaRef!
                        Task { await runCheck() }
                    } label: {
                        LabeledContent(model.name, value: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .memory))
                    }
                }
            }
        }
        .navigationTitle("Pull Model")
        .task {
            guard !initialReference.isEmpty, reference.isEmpty else { return }
            reference = initialReference
            await runCheck()
        }
    }

    private func runCheck() async {
        let model = reference.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        check = nil
        error = nil
        do {
            check = try await store.runnerClient(server).check(model, hfToken: store.huggingFaceToken)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pull() {
        let model = reference.trimmingCharacters(in: .whitespaces)
        progress = 0
        status = "Starting…"
        Task {
            do {
                for try await event in store.runnerClient(server).pull(model, hfToken: store.huggingFaceToken) {
                    if let message = event.error { throw ChatClientError.http(0, message) }
                    status = event.status ?? status
                    if let total = event.total, total > 0, let done = event.completed {
                        progress = Double(done) / Double(total)
                    }
                }
                status = "Installed"
                progress = 1
                await store.refresh(server)
            } catch {
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }
}

/// Verdict + numbers for a memory check, shared by on-device and server models.
struct AssessmentView: View {
    let assessment: MemoryAssessment

    var body: some View {
        Label(title, systemImage: symbol).foregroundStyle(color).font(.headline)
        Text(assessment.message).font(.subheadline)
        LabeledContent("Memory needed", value: MemoryAssessment.format(assessment.requiredBytes))
        LabeledContent("Free now", value: MemoryAssessment.format(assessment.availableBytes))
        LabeledContent("Limit for one model", value: MemoryAssessment.format(assessment.deviceBytes))
        LabeledContent("Free storage", value: MemoryAssessment.format(assessment.freeDiskBytes))
    }

    private var title: String {
        switch assessment.verdict {
        case .fits: "Fits"
        case .tight: "Tight fit"
        case .tooLarge: "Too large for \(assessment.hostLabel)"
        case .notEnoughDisk: "Not enough storage"
        }
    }

    private var symbol: String {
        switch assessment.verdict {
        case .fits: "checkmark.circle.fill"
        case .tight: "exclamationmark.triangle.fill"
        case .tooLarge, .notEnoughDisk: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch assessment.verdict {
        case .fits: .green
        case .tight: .orange
        case .tooLarge, .notEnoughDisk: .red
        }
    }
}
