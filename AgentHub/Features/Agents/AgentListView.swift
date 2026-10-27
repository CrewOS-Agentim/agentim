import SwiftUI

struct AgentListView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Agent?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.agents) { agent in
                    Button { editing = agent } label: { AgentRow(agent: agent) }
                        .foregroundStyle(.primary)
                }
                .onDelete { store.agents.remove(atOffsets: $0) }
                .onMove { store.agents.move(fromOffsets: $0, toOffset: $1) }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editing = Agent(name: "", emoji: "🤖", summary: "", systemPrompt: "")
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { agent in
                AgentEditorView(agent: agent) { saved in
                    if let i = store.agents.firstIndex(where: { $0.id == saved.id }) {
                        store.agents[i] = saved
                    } else {
                        store.agents.append(saved)
                    }
                }
            }
        }
    }
}

private struct AgentRow: View {
    @Environment(AppStore.self) private var store
    let agent: Agent

    var body: some View {
        HStack(spacing: 12) {
            Text(agent.emoji).font(.largeTitle)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.name).font(.headline)
                if !agent.summary.isEmpty {
                    Text(agent.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Tag(text: modelText, symbol: modelSymbol)
                    if !agent.skillIDs.isEmpty { Tag(text: "\(agent.skillIDs.count) skills", symbol: "wand.and.stars") }
                    if agent.preferLocal { Tag(text: "On-device", symbol: "iphone") }
                }
            }
        }
    }

    private var modelText: String {
        switch (agent.kind, agent.modelPreference) {
        case (.remote(let url, _), _): url.host() ?? "Remote"
        case (_, .auto): "Auto"
        case (_, .pinned(let id)): store.model(id: id)?.displayName ?? id
        }
    }

    private var modelSymbol: String {
        if case .remote = agent.kind { return "antenna.radiowaves.left.and.right" }
        if case .auto = agent.modelPreference { return "wand.and.rays" }
        return "pin"
    }
}

struct Tag: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint.opacity(0.12), in: Capsule())
    }
}
