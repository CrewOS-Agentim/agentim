import SwiftUI

struct ModelsView: View {
    @Environment(AppStore.self) private var store
    /// `-modelsFilter Servers` on launch picks the starting filter (used for screenshots).
    @State private var filter = Filter(rawValue: UserDefaults.standard.string(forKey: "modelsFilter") ?? "") ?? .all
    @State private var addingCustom = false
    @State private var browsingHub = false
    @State private var editingServer: LocalServer?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", local = "This Mac", servers = "Servers", cloud = "Cloud"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                if filter == .all || filter == .local { localSections }
                if filter == .all || filter == .servers { serverSections }
                if filter == .all || filter == .cloud { cloudSections }
            }
            .refreshable { await store.refreshServers() }
            .navigationTitle("Models")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Browse Hugging Face", systemImage: "magnifyingglass") { browsingHub = true }
                        Button("Add local server", systemImage: "desktopcomputer") { editingServer = newServer }
                        Button("Add cloud model id", systemImage: "cloud") { addingCustom = true }
                    } label: { Image(systemName: "plus") }
                }
            }
            .navigationDestination(isPresented: $browsingHub) { HuggingFaceBrowserView() }
            .sheet(isPresented: $addingCustom) { CustomModelView() }
            .sheet(item: $editingServer) { ServerEditorView(server: $0) }
        }
    }

    private var newServer: LocalServer {
        LocalServer(name: "", baseURL: URL(string: "http://localhost")!)
    }

    @ViewBuilder
    private var serverSections: some View {
        ForEach(store.servers) { ServerSection(server: $0) }
        if store.servers.isEmpty {
            Section {
                Button { editingServer = newServer } label: {
                    Label("Add a computer running the agentim runner, Ollama, LM Studio or Docker", systemImage: "plus.circle")
                }
            } header: {
                Text("Your servers")
            } footer: {
                Text("Run bigger models on your Mac or PC (natively or in Docker) and LTX video, all private to your network.")
            }
        }
    }

    @ViewBuilder
    private var localSections: some View {
        Section {
            DeviceMemoryRow()
            ForEach(store.installedLocalModels) { model in
                ModelRow(model: model, available: true)
                    .swipeActions {
                        Button("Delete", role: .destructive) { store.deleteLocal(model) }
                    }
            }
            ForEach(Array(store.localModels.downloads.keys.sorted()), id: \.self) { repo in
                DownloadRow(repo: repo)
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text("Runs privately with MLX, works offline, free. Swipe to delete and free up storage.")
        }

        let suggestions = AIModel.suggestedLocal.filter { s in
            !store.installedLocalModels.contains { $0.id == s.id } && store.localModels.downloads[s.modelName] == nil
        }
        if !suggestions.isEmpty {
            Section("Suggested for this Mac") {
                ForEach(suggestions) { model in
                    NavigationLink { LocalModelDetailView(repo: model.modelName) } label: {
                        ModelRow(model: model, available: false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cloudSections: some View {
        ForEach(store.providers) { provider in
            let models = (AIModel.cloudCatalog + store.customModels).filter { $0.providerID == provider.id }
            if !models.isEmpty {
                Section {
                    ForEach(models) { model in
                        ModelRow(model: model, available: store.isConnected(provider))
                            .swipeActions {
                                if !model.isBuiltIn {
                                    Button("Delete", role: .destructive) {
                                        store.customModels.removeAll { $0.id == model.id }
                                    }
                                }
                            }
                    }
                } header: {
                    HStack {
                        Label(provider.name, systemImage: provider.symbol)
                        Spacer()
                        Text(store.isConnected(provider) ? "Connected" : "Not connected")
                            .foregroundStyle(store.isConnected(provider) ? .green : .secondary)
                    }
                }
            }
        }
    }
}

struct ModelRow: View {
    let model: AIModel
    let available: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: model.locationSymbol).foregroundStyle(.tint)
                Text(model.displayName).font(.headline)
                Spacer()
                Text("@\(model.alias)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(model.capabilities.sorted { $0.rawValue < $1.rawValue }) { Tag(text: $0.label, symbol: "checkmark") }
            }
            HStack(spacing: 12) {
                if !model.isMedia { Text("\(model.contextWindow / 1_000)K context") }
                Text(model.costTier == 0 ? "Free" : String(repeating: "$", count: model.costTier))
                Text(String(repeating: "★", count: model.qualityTier))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .opacity(available ? 1 : 0.6)
    }
}

private struct DeviceMemoryRow: View {
    var body: some View {
        LabeledContent {
            Text("\(MemoryAssessment.format(DeviceMemory.availableToAppBytes)) free for models")
        } label: {
            Label("\(MemoryAssessment.format(DeviceMemory.physicalBytes)) RAM", systemImage: "memorychip")
        }
        .font(.subheadline)
    }
}

private struct DownloadRow: View {
    @Environment(AppStore.self) private var store
    let repo: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(repo).font(.subheadline)
            switch store.localModels.downloads[repo] {
            case .downloading(let progress)?:
                HStack {
                    ProgressView(value: progress)
                    Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit())
                    Button("Cancel", role: .destructive) { store.localModels.delete(repo) }.font(.caption)
                }
            case .failed(let message)?:
                Text(message).font(.caption).foregroundStyle(.red)
                Button("Dismiss") { store.localModels.delete(repo) }.font(.caption)
            case .checking?:
                ProgressView()
            case nil:
                EmptyView()
            }
        }
    }
}

private struct CustomModelView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var providerID = Provider.openRouter.id
    @State private var modelName = ""
    @State private var displayName = ""
    @State private var alias = ""
    @State private var capabilities: Set<Capability> = [.general]
    @State private var context = 128
    @State private var cost = 2
    @State private var quality = 3

    var body: some View {
        NavigationStack {
            Form {
                Picker("Provider", selection: $providerID) {
                    ForEach(store.providers) { Text($0.name).tag($0.id) }
                }
                TextField("Model id (e.g. deepseek/deepseek-r1)", text: $modelName)
                        .autocorrectionDisabled()
                TextField("Display name", text: $displayName)
                TextField("Alias for @mentions", text: $alias)
                        .autocorrectionDisabled()
                Section("Router hints") {
                    ForEach(Capability.allCases) { cap in
                        Toggle(cap.label, isOn: Binding(
                            get: { capabilities.contains(cap) },
                            set: { if $0 { capabilities.insert(cap) } else { capabilities.remove(cap) } }))
                    }
                    Stepper("Context: \(context)K", value: $context, in: 4...2_000, step: 4)
                    Stepper("Cost tier: \(cost)", value: $cost, in: 1...4)
                    Stepper("Quality tier: \(quality)", value: $quality, in: 1...5)
                }
            }
            .navigationTitle("Add Model")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let provider = store.provider(id: providerID) else { return }
                        var model = AIModel.cloud(
                            provider, modelName, display: displayName.isEmpty ? modelName : displayName,
                            alias: alias.isEmpty ? modelName.lowercased() : alias, caps: capabilities,
                            context: context * 1_000, cost: cost, quality: quality)
                        model.isBuiltIn = false
                        store.customModels.append(model)
                        dismiss()
                    }
                    .disabled(modelName.isEmpty)
                }
            }
        }
    }
}
