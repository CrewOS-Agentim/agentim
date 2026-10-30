import SwiftUI

extension AppStore {
    /// The Mac's own runner (not the Docker one): LoRA models run there, with llama-server on the GPU.
    var macRunner: LocalServer? {
        servers.first { server in
            guard server.kind == .runner, case .online(let system?)? = serverStatus[server.id] else { return false }
            return !system.in_container
        }
    }

    /// Downloaded Hugging Face GGUF models an adapter can go on ("ollama/hf.co/…").
    var loraBases: [AIModel] {
        serverModels.filter { $0.modelName.hasPrefix("ollama/hf.co/") }
    }
}

/// Adds a LoRA adapter from Hugging Face on top of a downloaded model: suggestions for that model, a check of the
/// adapter (is it really an adapter, and made for this model?), then live progress until it's a model of its own.
struct AddLoRAView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var base: String
    @State private var adapter = ""
    @State private var suggestions: RunnerClient.AdapterSearch?
    @State private var searching = false
    @State private var plan: RunnerClient.AdapterPlan?
    @State private var checking = false
    @State private var error: String?
    @State private var progress: Double?
    @State private var status = ""
    @State private var created: String?

    var body: some View {
        Form {
            if store.macRunner == nil {
                Section {
                    Label("LoRA models run on this Mac's own runner, which isn't connected. Open This Mac and connect it.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                }
            }
            Section {
                Picker("Base model", selection: $base) {
                    ForEach(store.loraBases) { Text($0.displayName).tag($0.modelName) }
                }
                .onChange(of: base) { plan = nil; Task { await search() } }
                TextField("owner/adapter on Hugging Face, or a link", text: $adapter)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await check() } }
                Button("Check adapter") { Task { await check() } }
                    .disabled(adapter.trimmingCharacters(in: .whitespaces).isEmpty || checking || store.macRunner == nil)
            } header: {
                Text("LoRA adapter")
            } footer: {
                Text("An adapter is a small add-on (usually 10–500 MB) that teaches a model a style, a domain or a task. "
                     + "It runs with llama.cpp on this Mac's GPU and shows up as its own model.")
            }

            if checking { ProgressView("Checking the adapter…") }
            if let error { Text(error).foregroundStyle(.red) }
            if let plan { planSection(plan) }
            if let created {
                Section {
                    Label("Added \(created). Pick it in any chat or agent.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Done") { dismiss() }
                }
            }

            Section {
                if searching {
                    ProgressView()
                } else if let suggestions, !suggestions.adapters.isEmpty {
                    ForEach(suggestions.adapters) { item in
                        Button {
                            adapter = item.repo
                            Task { await check() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.repo).lineLimit(1).truncationMode(.middle)
                                    Text("\(item.format == "gguf" ? "GGUF" : "Safetensors (converted on this Mac)") · \(item.downloads) downloads")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("No adapters listed for this model on Hugging Face. Paste any adapter repo above.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Adapters for \(suggestions?.base_repo ?? "this model")")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add a LoRA adapter")
        .task { await search() }
    }

    @ViewBuilder
    private func planSection(_ plan: RunnerClient.AdapterPlan) -> some View {
        Section("Adapter") {
            LabeledContent("Repo", value: plan.repo)
            LabeledContent("Format", value: plan.format == "gguf" ? "GGUF" : "Safetensors (converted to GGUF on this Mac)")
            LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: plan.size_bytes, countStyle: .file))
            LabeledContent("Made for") {
                switch plan.matches {
                case true?: Label("This model", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case false?:
                    Label(plan.base_model.map { "Another model (\($0))" } ?? "Another model (\(plan.architecture ?? "?"))",
                          systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                case nil: Label("Can't tell: it's tested before it's added", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                }
            }
            LabeledContent("New model", value: plan.name)
            if let size = plan.base_size_bytes {
                Text("The first adapter on \(plan.base_repo ?? "this model") downloads the base for llama.cpp too (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if plan.llama_cpp == false {
                Label("llama.cpp isn't installed on this Mac. Run: brew install llama.cpp", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
            }
            if !plan.enough_disk {
                Label("Not enough disk space.", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.red)
            }
        }
        Section {
            if let progress {
                ProgressView(value: progress) { Text(status) }
            } else if created == nil {
                Button(plan.exists ? "Replace \(plan.name)" : plan.matches == false ? "Add anyway" : "Add adapter",
                       systemImage: "plus.circle.fill") { create(force: plan.matches == false) }
                    .disabled(!plan.enough_disk || plan.llama_cpp == false)
            }
        } footer: {
            if plan.matches == false, progress == nil {
                Text("It probably won't load on this model; agentim tests it and removes it if it doesn't.")
            }
        }
    }

    private func search() async {
        guard let runner = store.macRunner else { return }
        searching = true
        defer { searching = false }
        suggestions = try? await store.runnerClient(runner).adapterSearch(base: base, hfToken: store.huggingFaceToken)
    }

    private func check() async {
        guard let runner = store.macRunner else { return }
        let text = adapter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        checking = true
        defer { checking = false }
        error = nil
        plan = nil
        created = nil
        do {
            plan = try await store.runnerClient(runner).adapterCheck(base: base, adapter: text, hfToken: store.huggingFaceToken)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func create(force: Bool) {
        guard let runner = store.macRunner, let plan else { return }
        progress = 0
        status = "Starting…"
        error = nil
        Task {
            do {
                for try await event in store.runnerClient(runner).adapterCreate(
                    base: base, adapter: plan.repo, hfToken: store.huggingFaceToken, force: force) {
                    if let message = event.error { throw ChatClientError.http(0, message) }
                    status = event.status ?? status
                    if let total = event.total, total > 0, let done = event.completed { progress = Double(done) / Double(total) }
                    if event.status == "success" { created = event.model ?? plan.name }
                }
                await store.refreshServers()
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
        }
    }
}
