import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var editingServer: LocalServer?

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    NavigationLink { HuggingFaceAccountView() } label: {
                        LabeledContent {
                            Text(store.huggingFaceAccount?.name ?? "Not connected")
                        } label: {
                            Label("Hugging Face", systemImage: "face.smiling")
                        }
                    }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("Download on-device models and use Hugging Face Inference Providers with one token.")
                }

                Section {
                    ForEach(store.servers) { server in
                        Button { editingServer = server } label: {
                            LabeledContent {
                                if case .online? = store.serverStatus[server.id] {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                } else {
                                    Image(systemName: "circle").foregroundStyle(.secondary)
                                }
                            } label: {
                                Label(server.name, systemImage: "desktopcomputer")
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .onDelete { offsets in offsets.map { store.servers[$0] }.forEach(store.removeServer) }
                    Button("Add server", systemImage: "plus") {
                        editingServer = LocalServer(name: "", baseURL: URL(string: "http://localhost")!)
                    }
                } header: {
                    Text("Local servers")
                } footer: {
                    Text("Models on your own computers: the agentim runner (native or Docker, with memory checks and LTX), or Ollama, LM Studio and other OpenAI-compatible servers.")
                }

                ClaudeSection()

                Section("Cloud providers") {
                    ForEach(store.providers.filter { $0.id != Provider.huggingFace.id }) { provider in
                        NavigationLink { ProviderKeyView(provider: provider) } label: {
                            LabeledContent {
                                Image(systemName: store.isConnected(provider) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(store.isConnected(provider) ? .green : .secondary)
                            } label: {
                                Label(provider.name, systemImage: provider.symbol)
                            }
                        }
                    }
                }

                Section {
                    Picker("Optimize for", selection: $store.router.priority) {
                        ForEach(RouterSettings.Priority.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Keep sensitive prompts private", isOn: $store.router.keepSensitiveLocal)
                    Toggle("Prefer private models (this Mac or your servers)", isOn: $store.router.preferLocal)
                    Picker("Fallback model", selection: $store.router.fallbackModelID) {
                        Text("Best available").tag(String?.none)
                        ForEach(store.availableModels) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                } header: {
                    Text("Router")
                } footer: {
                    Text("Precedence: @alias in a message → conversation pin → agent pin → offline/sensitive/on-device rules → best match for the task. If a model errors before answering, the next best is tried.")
                }

                Section("About") {
                    LabeledContent("Models available", value: "\(store.availableModels.count)")
                    LabeledContent("Device memory", value: MemoryAssessment.format(DeviceMemory.physicalBytes))
                    LabeledContent("Network", value: store.isOnline ? "Online" : "Offline")
                    HStack {
                        Button("Report an issue", systemImage: "ladybug") { IssueReporter.open(kind: .bug) }
                        Button("Suggest a feature", systemImage: "lightbulb") { IssueReporter.open(kind: .feature) }
                        Button("Discussions", systemImage: "bubble.left.and.bubble.right") { IssueReporter.openIdeas() }
                    }
                    Text("Opens GitHub with your app and Mac details filled in. Nothing is sent until you submit it there.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $editingServer) { ServerEditorView(server: $0) }
        }
    }
}

private struct ProviderKeyView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let provider: Provider
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $key)
                        .autocorrectionDisabled()
                if let help = provider.keyHelpURL { Link("Get a key", destination: help) }
            } footer: {
                Text("Stored in the iOS Keychain on this device only.")
            }
            Section {
                Button("Save") {
                    store.setAPIKey(key, for: provider)
                    dismiss()
                }
                .disabled(key.isEmpty)
                if store.isConnected(provider) {
                    Button("Disconnect", role: .destructive) {
                        store.setAPIKey(nil, for: provider)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(provider.name)
    }
}

private struct HuggingFaceAccountView: View {
    @Environment(AppStore.self) private var store
    @State private var token = ""
    @State private var error: String?
    @State private var isConnecting = false

    var body: some View {
        Form {
            if let account = store.huggingFaceAccount {
                Section("Connected") {
                    LabeledContent("Username", value: account.name)
                    if let name = account.fullname { LabeledContent("Name", value: name) }
                    Button("Disconnect", role: .destructive) { store.disconnectHuggingFace() }
                }
            } else {
                Section {
                    SecureField("hf_…", text: $token)
                        .autocorrectionDisabled()
                    Link("Create a read token", destination: Provider.huggingFace.keyHelpURL!)
                } header: {
                    Text("Access token")
                } footer: {
                    Text("A read token is enough to download models. Enable \"Make calls to Inference Providers\" to also use Hugging Face cloud models.")
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button {
                    Task {
                        isConnecting = true
                        defer { isConnecting = false }
                        do {
                            try await store.connectHuggingFace(token: token.trimmingCharacters(in: .whitespaces))
                            error = nil
                        } catch {
                            self.error = "Couldn't verify the token: \(error.localizedDescription)"
                        }
                    }
                } label: {
                    if isConnecting { ProgressView() } else { Text("Connect") }
                }
                .disabled(token.isEmpty || isConnecting)
            }
        }
        .navigationTitle("Hugging Face")
    }
}

/// How Claude is used: your Claude login in a background terminal (tmux), or an API key.
struct ClaudeSection: View {
    @Environment(AppStore.self) private var store
    @Environment(HostController.self) private var host

    var body: some View {
        Section {
            Picker("Use Claude through", selection: Binding(get: { store.claudeVia },
                                                            set: { via in Task { await host.setClaudeVia(via, store: store) } })) {
                Text("Your Claude login, in a background terminal (tmux)").tag("tmux")
                Text("An Anthropic API key").tag("api")
            }
            if store.claudeVia == "tmux" {
                LabeledContent("Claude Code") {
                    Label(host.claude.claudeInstalled ? "Installed" : "Not found",
                          systemImage: host.claude.claudeInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(host.claude.claudeInstalled ? .green : .orange)
                }
                LabeledContent("tmux") {
                    if host.claude.tmuxInstalled {
                        Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Install tmux") { Task { await host.installTmuxIfNeeded() } }
                    }
                }
                LabeledContent("Running now") {
                    HStack {
                        Text(host.claude.sessions.isEmpty ? "No Claude sessions"
                             : "\(host.claude.sessions.count) session\(host.claude.sessions.count == 1 ? "" : "s")")
                        Button("Watch in Terminal", systemImage: "terminal") { host.watchClaude() }
                            .disabled(host.claude.sessions.isEmpty)
                    }
                }
            }
        } header: {
            Text("Claude")
        } footer: {
            Text(store.claudeVia == "tmux"
                 ? "Claude Opus, Sonnet and Haiku run with claude -p in tmux sessions on this Mac, using your Claude login: no API key, and the Anthropic API is never called. Watch any session with tmux attach."
                 : "Claude runs through the Anthropic API with the key under Cloud providers.")
        }
        .task {
            while !Task.isCancelled {
                await host.refreshClaude()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
