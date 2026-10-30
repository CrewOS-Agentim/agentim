import SwiftUI

/// Edits one agent in place (the right side of Agents). Changes apply when you press Save.
struct AgentEditorView: View {
    @Environment(AppStore.self) private var store
    @State private var agent: Agent
    private let original: Agent
    let isNew: Bool
    let onSave: (Agent) -> Void
    var onDelete: ((Agent) -> Void)?
    @State private var confirmingDelete = false

    init(agent: Agent, isNew: Bool = false, onSave: @escaping (Agent) -> Void, onDelete: ((Agent) -> Void)? = nil) {
        _agent = State(initialValue: agent)
        original = agent
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
    }

    @State private var isRemote = false
    @State private var endpoint = ""
    @State private var remoteModel = ""
    @State private var remoteKey = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                Section {
                    TextField("Name", text: $agent.name)
                    TextField("Emoji", text: $agent.emoji)
                    TextField("What is this agent for?", text: $agent.summary, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    Picker("Type", selection: $isRemote) {
                        Text("Assistant").tag(false)
                        Text("Cloud agent").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(isRemote
                         ? "Connect a hosted agent that exposes an OpenAI-compatible /chat/completions endpoint. Messages go straight to it."
                         : "Instructions and skills, answered by the model the router picks.")
                }

                if isRemote {
                    Section("Endpoint") {
                        TextField("https://my-agent.example.com/v1/chat/completions", text: $endpoint)
                        .autocorrectionDisabled()
                        TextField("Model / agent id", text: $remoteModel)
                        .autocorrectionDisabled()
                        SecureField("Bearer token (optional)", text: $remoteKey)
                    }
                } else {
                    Section("Instructions") {
                        TextEditor(text: $agent.systemPrompt).frame(minHeight: 120)
                    }
                    Section {
                        Picker("Model", selection: $agent.modelPreference) {
                            Label("Auto (router)", systemImage: "wand.and.rays").tag(ModelPreference.auto)
                            ForEach(store.allModels) { model in
                                Text(model.displayName).tag(ModelPreference.pinned(model.id))
                            }
                        }
                        Toggle("Prefer private models (this Mac or your servers)", isOn: $agent.preferLocal)
                    } header: {
                        Text("Routing")
                    } footer: {
                        Text("You can still override per conversation, or per message with @alias.")
                    }
                    Section("Skills") {
                        if store.skills.isEmpty { Text("No skills yet").foregroundStyle(.secondary) }
                        ForEach(store.skills) { skill in
                            Toggle(isOn: skillBinding(skill.id)) {
                                VStack(alignment: .leading) {
                                    Text(skill.name)
                                    Text(skill.summary).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    // Models that fit this agent's skills (design, frontend, coding, images); Use pins one.
                    SkillModelSuggestions(skills: store.skills.filter { agent.skillIDs.contains($0.id) }) { id in
                        agent.modelPreference = .pinned(id)
                    }
                }
            }
            .formStyle(.grouped)
            .onAppear {
                if case .remote(let url, let model) = agent.kind {
                    isRemote = true
                    endpoint = url.absoluteString
                    remoteModel = model
                    remoteKey = Keychain.get(agent.keychainAccount) ?? ""
                }
            }
        }
    }

    /// Avatar, name and the actions, always visible above the form.
    private var header: some View {
        HStack(spacing: Theme.s3) {
            AvatarView(agent: agent, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name.isEmpty ? "New agent" : agent.name).headlineStyle(20).lineLimit(1)
                if hasChanges {
                    Text("Unsaved changes").font(.caption).foregroundStyle(.orange)
                } else if !agent.summary.isEmpty {
                    Text(agent.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let onDelete {
                Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .help(isNew ? "Discard this agent" : "Delete \(agent.name)")
                    .confirmationDialog(isNew ? "Discard this new agent?" : "Delete \(agent.name)?", isPresented: $confirmingDelete) {
                        Button(isNew ? "Discard" : "Delete", role: .destructive) { onDelete(agent) }
                    } message: {
                        Text(isNew ? "It hasn't been saved yet." : "Its conversations stay, but they'll use the default agent.")
                    }
            }
            Button("Revert") { agent = original }
                .disabled(!hasChanges || isNew)
            Button(isNew ? "Create" : "Save", action: save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!isValid || !(hasChanges || isNew))
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s3)
    }

    private var hasChanges: Bool {
        if agent != original { return true }
        if case .remote(let url, let model) = original.kind {
            return !isRemote || endpoint != url.absoluteString || remoteModel != model
        }
        return isRemote
    }

    private var isValid: Bool {
        guard !agent.name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !isRemote || URL(string: endpoint)?.scheme?.hasPrefix("http") == true
    }

    private func skillBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { agent.skillIDs.contains(id) },
            set: { on in
                if on { agent.skillIDs.append(id) } else { agent.skillIDs.removeAll { $0 == id } }
            })
    }

    private func save() {
        if isRemote, let url = URL(string: endpoint) {
            agent.kind = .remote(endpoint: url, model: remoteModel)
            Keychain.set(remoteKey, for: agent.keychainAccount)
        } else {
            agent.kind = .assistant
        }
        onSave(agent)
    }
}
