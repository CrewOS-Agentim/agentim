import SwiftUI

struct ConversationListView: View {
    @Environment(AppStore.self) private var store
    @State private var path: [UUID] = []
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
        NavigationStack(path: $path) {
            List {
                ForEach(filtered) { conversation in
                    NavigationLink(value: conversation.id) {
                        ConversationRow(conversation: conversation, agent: store.agent(for: conversation))
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { filtered[$0].id }
                    store.conversations.removeAll { ids.contains($0.id) }
                }
            }
            .overlay {
                if store.conversations.isEmpty {
                    ContentUnavailableView(
                        "No conversations", systemImage: "bubble.left",
                        description: Text("Start one with any agent. The router picks the best model for each message."))
                }
            }
            .searchable(text: $search)
            .navigationTitle("Chats")
            .navigationDestination(for: UUID.self) { ChatView(conversationID: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(store.agents) { agent in
                            Button("\(agent.emoji) \(agent.name)") {
                                path.append(store.newConversation(agent: agent).id)
                            }
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
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
