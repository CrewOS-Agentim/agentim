import AVKit
import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let conversationID: UUID
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        if let conversation {
            VStack(spacing: 0) {
                messages(conversation)
                Divider()
                composer(conversation)
            }
            .navigationTitle(conversation.title)
            .toolbar { ToolbarItem(placement: .primaryAction) { modelMenu(conversation) } }
        } else {
            ContentUnavailableView("Conversation deleted", systemImage: "trash")
        }
    }

    private func messages(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(conversation.messages) { message in
                        MessageRow(message: message, model: store.model(id: message.modelID))
                            .id(message.id)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: conversation.messages.last?.content) {
                if let id = conversation.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func composer(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            RoutePreview(text: draft, conversation: conversation)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message · @alias to pick a model · /skill", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .padding(10)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                Button {
                    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    draft = ""
                    store.send(text, in: conversation.id)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || store.isStreaming(conversation.id))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Per-conversation override: Auto (router) or a pinned model.
    private func modelMenu(_ conversation: Conversation) -> some View {
        Menu {
            Picker("Model", selection: Binding(
                get: { conversation.pinnedModelID },
                set: { newValue in
                    if let i = store.conversations.firstIndex(where: { $0.id == conversation.id }) {
                        store.conversations[i].pinnedModelID = newValue
                    }
                })
            ) {
                Label("Auto (router)", systemImage: "wand.and.rays").tag(String?.none)
                ForEach(store.availableModels) { model in
                    Label(model.displayName, systemImage: model.locationSymbol).tag(Optional(model.id))
                }
            }
        } label: {
            Label(store.model(id: conversation.pinnedModelID)?.displayName ?? "Auto",
                  systemImage: conversation.pinnedModelID == nil ? "wand.and.rays" : "pin.fill")
                .labelStyle(.titleAndIcon)
                .font(.footnote)
        }
    }
}

/// Live "this message will go to X" hint under the composer.
private struct RoutePreview: View {
    @Environment(AppStore.self) private var store
    let text: String
    let conversation: Conversation

    var body: some View {
        let skills = store.activeSkills(agent: store.agent(for: conversation), message: text)
        HStack(spacing: 6) {
            if case .remote? = store.agent(for: conversation)?.kind {
                Label("Remote agent", systemImage: "antenna.radiowaves.left.and.right")
            } else if !text.isEmpty {
                switch store.previewRoute(text, in: conversation) {
                case .success(let decision):
                    Label(decision.model.displayName, systemImage: decision.model.locationSymbol)
                    Text("· \(decision.reason)").lineLimit(1)
                case .failure(let error):
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle").lineLimit(1)
                }
            }
            if !skills.isEmpty {
                Label(skills.map(\.name).joined(separator: ", "), systemImage: "wand.and.stars").lineLimit(1)
            }
            if !store.isOnline { Label("Offline", systemImage: "wifi.slash") }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .animation(.default, value: text.isEmpty)
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let model: AIModel?

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            Group {
                if message.content.isEmpty && message.role == .assistant {
                    ProgressView().padding(12)
                } else {
                    Text(LocalizedStringKey(message.content))
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
            .background(background, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(message.role == .user ? Color.white : Color.primary)

            ForEach(media, id: \.url) { item in
                Group {
                    if item.isVideo {
                        VideoPlayer(player: AVPlayer(url: item.url))
                    } else {
                        AsyncImage(url: item.url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if message.role == .assistant, let model {
                Label {
                    Text(model.displayName) + Text(message.routingReason.map { " · \($0)" } ?? "")
                } icon: {
                    Image(systemName: model.locationSymbol)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    /// `[video](http://…mp4)` / `[image](http://…png)` links from media models (e.g. LTX via the runner).
    private var media: [(url: URL, isVideo: Bool)] {
        guard message.role == .assistant,
              let regex = try? NSRegularExpression(pattern: #"\[(?:video|image)\]\((https?://[^)\s]+)\)"#)
        else { return [] }
        let text = message.content
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text), let url = URL(string: String(text[range])) else { return nil }
            return (url, ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()))
        }
    }

    private var background: AnyShapeStyle {
        if message.isError { return AnyShapeStyle(Color.red.opacity(0.15)) }
        return message.role == .user ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)
    }
}
