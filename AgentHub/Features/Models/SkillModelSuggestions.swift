import SwiftUI

/// Models that suit some skills: get them into Docker, use them from Hugging Face, or open them on the Hub.
struct SkillModelSuggestions: View {
    @Environment(AppStore.self) private var store
    let skills: [Skill]
    /// Set by the agent editor: pins the agent to a model that's ready to use.
    var onUse: ((String) -> Void)?
    var limit = 5
    @State private var pulling: SuggestedModel?

    var body: some View {
        let models = Array(SkillModels.suggestions(for: skills).prefix(limit))
        if !models.isEmpty {
            Section {
                ForEach(models) { row($0) }
            } header: {
                Text("Suggested models for \(skills.count == 1 ? "this skill" : "these skills")")
            } footer: {
                Text("Downloads are checked against your memory first. Cloud models use your Hugging Face token.")
            }
            .sheet(item: $pulling) { model in
                if let server = runner, let ref = model.ollamaRef {
                    NavigationStack {
                        PullModelView(server: server, initialReference: ref)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { pulling = nil } } }
                    }
                    .frame(minWidth: 520, minHeight: 480)
                }
            }
        }
    }

    private func row(_ model: SuggestedModel) -> some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).fontWeight(.medium)
                    Text(sourceLabel(model)).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(model.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(model.uses.sorted { $0.rawValue < $1.rawValue }.map(\.label).joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            action(model)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func action(_ model: SuggestedModel) -> some View {
        switch model.source {
        case .ollama(let ref):
            if let installed = installed(ref) {
                if let onUse { Button("Use") { onUse(installed.id) } } else { Text("Installed").foregroundStyle(.secondary) }
            } else {
                Button("Get") { pulling = model }
                    .disabled(runner == nil)
                    .help(runner == nil ? "Add a server running the agentim runner in Models first." : "Check memory, then download into Docker")
            }
        case .cloud(let id):
            if store.isConnected(.huggingFace) {
                if let onUse { Button("Use") { onUse(id) } } else { Text("Ready").foregroundStyle(.secondary) }
            } else {
                Link("Get a token", destination: Provider.huggingFace.keyHelpURL!)
                    .help("Connect Hugging Face in Settings to use \(model.name)")
            }
        case .hub:
            Link("Open on Hugging Face", destination: model.hubURL)
        }
    }

    private func sourceLabel(_ model: SuggestedModel) -> String {
        switch model.source {
        case .ollama: ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .memory)
        case .cloud: "Hugging Face cloud"
        case .hub: "external"
        }
    }

    /// The first server with the agentim runner (the Docker stack), where pulls go.
    private var runner: LocalServer? { store.servers.first { $0.kind == .runner } }

    /// A pulled copy of this model on one of your servers.
    private func installed(_ ref: String) -> AIModel? {
        store.serverModels.first { $0.modelName.lowercased() == ref.lowercased() }
    }
}
