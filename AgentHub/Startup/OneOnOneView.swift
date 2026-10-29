import SwiftUI

// MARK: - 1:1 chats with one employee

/// A private chat between the founder and one employee (the agents room doesn't see it; the employee brings what
/// you agreed into the next meeting).
struct DirectChat: Decodable, Equatable {
    struct Person: Decodable, Equatable {
        let key: String
        let name: String
        let title: String
        let emoji: String
    }

    struct Message: Decodable, Equatable, Identifiable {
        let role: String
        let content: String
        let ts: Double
        var id: String { "\(role)-\(ts)" }
        var fromFounder: Bool { role == "founder" }
    }

    let person: Person
    let messages: [Message]
    let typing: Bool
}

extension StartupClient {
    func dm(_ id: String, person: String) async throws -> DirectChat {
        try await sendDirectChat("v1/startups/\(id)/dm/\(person)", body: nil)
    }

    func sendDM(_ id: String, person: String, text: String) async throws -> DirectChat {
        try await sendDirectChat("v1/startups/\(id)/dm/\(person)", body: ["text": text])
    }
}

extension StartupModel {
    func openChat(with key: String, stackRoot: URL?) async {
        dmKey = key
        dmChat = nil
        await refreshChat(stackRoot: stackRoot)
    }

    func refreshChat(stackRoot: URL?) async {
        guard let id = detail?.id, let key = dmKey, !isDemo, let client = Self.client(stackRoot: stackRoot) else { return }
        if let chat = try? await client.dm(id, person: key), dmKey == key { dmChat = chat }
    }

    func sendDM(stackRoot: URL?) async {
        let text = dmDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = detail?.id, let key = dmKey, !text.isEmpty else { return }
        dmDraft = ""
        await act(nil, stackRoot) { client in self.dmChat = try await client.sendDM(id, person: key, text: text) }
    }
}

/// The 1:1 tab: pick a person, then chat with them privately.
struct OneOnOnePanel: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?
    @State private var draftHeight: CGFloat = 44

    private var people: [(key: String, name: String, title: String, emoji: String)] {
        detail.team.map { ($0.key, $0.name, $0.title, $0.emoji) } + [("ceo", "Agent Tim", "CEO", "🐙")]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.s3) {
                    ForEach(people, id: \.key) { person in
                        Button { Task { await model.openChat(with: person.key, stackRoot: stackRoot) } } label: {
                            VStack(spacing: 3) {
                                avatar(person.key, emoji: person.emoji, size: 40)
                                    .overlay(Circle().strokeBorder(model.dmKey == person.key ? Theme.accent : .clear, lineWidth: 3))
                                Text(person.name.split(separator: " ").first.map(String.init) ?? person.name)
                                    .font(.caption.weight(model.dmKey == person.key ? .semibold : .regular))
                            }
                            .frame(width: 58)
                        }
                        .buttonStyle(.plain)
                        .help("Chat 1:1 with \(person.name), \(person.title)")
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, Theme.s3)
            }
            Divider()
            if let key = model.dmKey, let person = people.first(where: { $0.key == key }) {
                conversation(person)
            } else {
                ContentUnavailableView("Talk to one person", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Pick someone above for a private 1:1. The rest of the team doesn't see it; they bring what you agree into the next meeting."))
            }
        }
        // Poll while the chat is open: the reply arrives a few seconds later.
        .task(id: model.dmKey) {
            while !Task.isCancelled, model.dmKey != nil {
                try? await Task.sleep(for: .seconds(model.dmChat?.typing == true ? 1.5 : 6))
                await model.refreshChat(stackRoot: stackRoot)
            }
        }
    }

    private func avatar(_ key: String, emoji: String, size: CGFloat) -> some View {
        Group {
            if key == "ceo" { TimAvatar(size: size) } else {
                AvatarView(image: Avatars.teamMember(key, startup: detail.id), emoji: emoji, size: size)
            }
        }
    }

    private func conversation(_ person: (key: String, name: String, title: String, emoji: String)) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.s2) {
                avatar(person.key, emoji: person.emoji, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(person.name).font(.headline)
                    Text("\(person.title) · private").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, Theme.s2)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.s3) {
                        if (model.dmChat?.messages ?? []).isEmpty {
                            Text("Ask \(person.name.split(separator: " ").first ?? "") anything: a draft, a number, a decision. They answer in character and act on it in the next meeting.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, Theme.s4)
                        }
                        ForEach(model.dmChat?.messages ?? []) { message in
                            bubble(message, person: person).id(message.id)
                        }
                        if model.dmChat?.typing == true {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("\(person.name.split(separator: " ").first ?? "") is typing…").font(.callout).foregroundStyle(.secondary)
                            }
                            .id("typing")
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, Theme.s3)
                }
                .onChange(of: model.dmChat?.messages.count) {
                    if let last = model.dmChat?.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: Theme.s2) {
                ComposerTextView(text: $model.dmDraft, placeholder: "Message \(person.name.split(separator: " ").first ?? "")…",
                                 minHeight: 44, maxHeight: 160,
                                 onSubmit: { Task { await model.sendDM(stackRoot: stackRoot) } }, height: $draftHeight)
                    .frame(height: draftHeight)
                    .padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
                Button { Task { await model.sendDM(stackRoot: stackRoot) } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .disabled(model.dmDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.dmChat?.typing == true)
                .accessibilityLabel("Send")
            }
            .padding(.horizontal, 20).padding(.top, Theme.s2).padding(.bottom, Theme.bottomInset)
        }
    }

    private func bubble(_ message: DirectChat.Message, person: (key: String, name: String, title: String, emoji: String)) -> some View {
        HStack(alignment: .top, spacing: Theme.s2) {
            if message.fromFounder { Spacer(minLength: 40) } else { avatar(person.key, emoji: person.emoji, size: 26) }
            Text(LocalizedStringKey(message.content))
                .font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
                .background(message.fromFounder ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface),
                            in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay { if !message.fromFounder {
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border)
                } }
                .foregroundStyle(message.fromFounder ? Color.white : Color.primary)
            if !message.fromFounder { Spacer(minLength: 40) }
        }
    }
}
