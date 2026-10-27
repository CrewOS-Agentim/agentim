import SwiftUI

/// Messages-style two panes: conversations on the left, the open chat on the right.
/// Selection-driven (no navigation path), so switching sidebar sections is always safe.
struct ConversationListView: View {
    @Environment(AppStore.self) private var store
    // `-openChat YES` opens the most recent chat (used for screenshots).
    @State private var selection: UUID? = nil
    @State private var search = ""

    private var filtered: [Conversation] {
        let sorted = store.conversations.sorted { $0.updatedAt > $1.updatedAt }
        guard !search.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.messages.contains { $0.content.localizedCaseInsensitiveContains(search) }
        }
    }

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(filtered) { conversation in
                    ConversationRow(conversation: conversation, agent: store.agent(for: conversation))
                        .tag(conversation.id)
                        .contextMenu {
                            Button("Delete", role: .destructive) { delete([conversation.id]) }
                        }
                }
                .onDelete { offsets in delete(offsets.map { filtered[$0].id }) }
            }
            .searchable(text: $search, placement: .sidebar)
            .overlay {
                if store.conversations.isEmpty {
                    ContentUnavailableView(
                        "No conversations", systemImage: "bubble.left",
                        description: Text("Start one with any agent. The router picks the best model for each message."))
                }
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)

            Group {
                if let selection {
                    ChatView(conversationID: selection).id(selection)
                } else {
                    ContentUnavailableView("Pick a chat", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Or start a new one with ⌘N."))
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Chats")
        .onAppear {
            if selection == nil, UserDefaults.standard.bool(forKey: "openChat") { selection = filtered.first?.id }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(store.agents) { agent in
                        Button("\(agent.emoji) \(agent.name)") { selection = store.newConversation(agent: agent).id }
                    }
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                } primaryAction: {
                    if let agent = store.agents.first { selection = store.newConversation(agent: agent).id }
                }
                .keyboardShortcut("n")
            }
        }
    }

    private func delete(_ ids: [UUID]) {
        if let selection, ids.contains(selection) { self.selection = nil }
        store.conversations.removeAll { ids.contains($0.id) }
    }
}

private struct ConversationRow: View {
    let conversation: Conversation
    let agent: Agent?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(agent?.emoji ?? "💬")
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(.quaternary, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(conversation.title).font(.headline).lineLimit(1)
                    Spacer()
                    Text(conversation.updatedAt, style: .relative)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(agent?.name ?? "Unknown agent").font(.caption).foregroundStyle(.tint)
                Text(conversation.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
