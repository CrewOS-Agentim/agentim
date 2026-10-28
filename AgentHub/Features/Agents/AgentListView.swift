import SwiftUI

/// Agents: the list on the left, the selected agent's editor on the right (no modal).
struct AgentListView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: UUID?
    /// A new agent being created; it joins the list when saved.
    @State private var newAgent: Agent?

    private var current: Agent? {
        newAgent ?? store.agents.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.agents) { agent in
                        AgentRow(agent: agent).tag(agent.id)
                    }
                    .onDelete { store.agents.remove(atOffsets: $0) }
                    .onMove { store.agents.move(fromOffsets: $0, toOffset: $1) }
                }
                .onChange(of: selection) { _, id in if id != nil { newAgent = nil } }
                Divider()
                Button {
                    selection = nil
                    newAgent = Agent(name: "", emoji: "🤖", summary: "", systemPrompt: "")
                } label: {
                    Label("New agent", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 28)
                }
                .bottomActionStyle()
            }
            .frame(minWidth: 280, idealWidth: 330, maxWidth: 440)

            Group {
                if let agent = current {
                    AgentEditorView(agent: agent, isNew: newAgent != nil, onSave: save, onDelete: delete)
                        .id(agent.id)
                } else {
                    ContentUnavailableView("Pick an agent", systemImage: "person.2",
                                           description: Text("Choose an agent on the left to edit it, or create a new one."))
                }
            }
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Agents")
        .onAppear { if selection == nil, newAgent == nil { selection = store.agents.first?.id } }
    }

    private func save(_ saved: Agent) {
        if let i = store.agents.firstIndex(where: { $0.id == saved.id }) {
            store.agents[i] = saved
        } else {
            store.agents.append(saved)
        }
        newAgent = nil
        selection = saved.id
    }

    private func delete(_ agent: Agent) {
        if newAgent?.id == agent.id {
            newAgent = nil
        } else {
            store.agents.removeAll { $0.id == agent.id }
        }
        selection = store.agents.first?.id
    }
}

private struct AgentRow: View {
    @Environment(AppStore.self) private var store
    let agent: Agent

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(agent: agent, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.headline).lineLimit(1)
                if !agent.summary.isEmpty {
                    Text(agent.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Tag(text: modelText, symbol: modelSymbol)
                    if !agent.skillIDs.isEmpty {
                        Tag(text: agent.skillIDs.count == 1 ? "1 skill" : "\(agent.skillIDs.count) skills", symbol: "wand.and.stars")
                    }
                    if agent.preferLocal { Tag(text: "Private", symbol: "lock.fill") }
                }
            }
        }
        .padding(.vertical, 4)
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
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .font(.caption2)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.tint.opacity(0.12), in: Capsule())
    }
}
