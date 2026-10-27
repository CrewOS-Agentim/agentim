import SwiftUI

struct AgentEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var agent: Agent
    let onSave: (Agent) -> Void

    @State private var isRemote = false
    @State private var endpoint = ""
    @State private var remoteModel = ""
    @State private var remoteKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("🤖", text: $agent.emoji).frame(width: 44).font(.largeTitle)
                        TextField("Name", text: $agent.name).font(.title3)
                    }
                    TextField("What is this agent for?", text: $agent.summary)
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
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Model / agent id", text: $remoteModel)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
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
                        Toggle("Prefer on-device models", isOn: $agent.preferLocal)
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
                }
            }
            .navigationTitle(agent.name.isEmpty ? "New Agent" : agent.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!isValid)
                }
            }
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
        dismiss()
    }
}
