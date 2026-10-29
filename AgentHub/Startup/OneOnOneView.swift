import SwiftUI

// MARK: - Messages: the team room, groups and 1:1s, like iMessage

/// One conversation: a private 1:1 with an employee, or a group chat ("group-<id>").
struct DirectChat: Decodable, Equatable {
    struct Person: Decodable, Equatable {
        let key: String
        let name: String
        let title: String
        let emoji: String
    }

    struct Group: Decodable, Equatable {
        let id: String
        let name: String
        let members: [String]
    }

    struct Message: Decodable, Equatable, Identifiable {
        let role: String
        let content: String
        let ts: Double
        var id: String { "\(role)-\(ts)" }
        var fromFounder: Bool { role == "founder" }
    }

    let person: Person
    var group: Group? = nil
    let messages: [Message]
    let typing: Bool
    /// In a group: who's writing right now.
    var speaking: String? = nil
}

/// A row in the conversation list.
struct StartupThread: Decodable, Equatable, Identifiable {
    struct Last: Decodable, Equatable {
        let role: String
        let content: String
        let ts: Double
    }

    let key: String
    let kind: String          // room | group | person
    let name: String
    var title: String? = nil
    var emoji: String? = nil
    let members: [String]
    var last: Last? = nil
    var typing: Bool? = nil
    var id: String { key }
}

extension StartupClient {
    func dm(_ id: String, person: String) async throws -> DirectChat {
        try await sendDirectChat("v1/startups/\(id)/dm/\(person)", body: nil)
    }

    func sendDM(_ id: String, person: String, text: String) async throws -> DirectChat {
        try await sendDirectChat("v1/startups/\(id)/dm/\(person)", body: ["text": text])
    }

    func threads(_ id: String) async throws -> [StartupThread] {
        struct Reply: Decodable { let threads: [StartupThread] }
        let reply: Reply = try await getJSON("v1/startups/\(id)/threads")
        return reply.threads
    }

    func createGroup(_ id: String, members: [String], name: String) async throws -> DirectChat.Group {
        try await sendGroup("v1/startups/\(id)/groups", body: ["members": members, "name": name])
    }

    func deleteGroup(_ id: String, group: String) async throws {
        try await post("v1/startups/\(id)/groups", body: ["delete": group])
    }
}

extension StartupModel {
    /// Opens a conversation: "room", a person's key, or "group-<id>".
    func openThread(_ key: String, stackRoot: URL?) async {
        selectedThread = key
        dmKey = key == "room" ? nil : key
        dmChat = nil
        if key != "room" { await refreshChat(stackRoot: stackRoot) }
    }

    func openChat(with key: String, stackRoot: URL?) async { await openThread(key, stackRoot: stackRoot) }

    func refreshChat(stackRoot: URL?) async {
        guard let id = detail?.id, let key = dmKey, !isDemo, let client = Self.client(stackRoot: stackRoot) else { return }
        if let chat = try? await client.dm(id, person: key), dmKey == key { dmChat = chat }
    }

    func loadThreads(stackRoot: URL?) async {
        guard let id = detail?.id, !isDemo, let client = Self.client(stackRoot: stackRoot) else { return }
        if let list = try? await client.threads(id) { threads = list }
    }

    func sendDM(stackRoot: URL?) async {
        let text = dmDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = detail?.id, let key = dmKey, !text.isEmpty else { return }
        dmDraft = ""
        await act(nil, stackRoot) { client in self.dmChat = try await client.sendDM(id, person: key, text: text) }
        await loadThreads(stackRoot: stackRoot)
    }

    func createGroup(stackRoot: URL?) async {
        guard let id = detail?.id, groupDraft.count >= 2 else { return }
        let members = Array(groupDraft)
        let name = groupDraftName
        await act("Creating the group…", stackRoot) { client in
            let group = try await client.createGroup(id, members: members, name: name)
            self.composingGroup = false
            self.groupDraft = []
            self.groupDraftName = ""
            await self.loadThreads(stackRoot: stackRoot)
            await self.openThread("group-\(group.id)", stackRoot: stackRoot)
        }
    }

    func deleteGroup(_ key: String, stackRoot: URL?) async {
        guard let id = detail?.id, key.hasPrefix("group-") else { return }
        await act(nil, stackRoot) { client in try await client.deleteGroup(id, group: String(key.dropFirst(6))) }
        await openThread("room", stackRoot: stackRoot)
        await loadThreads(stackRoot: stackRoot)
    }
}

/// The Messages tab: conversations on the left (team room, groups, people), the open one on the right.
struct MessagesPanel: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?

    private var people: [String: (name: String, title: String, emoji: String)] {
        var all = Dictionary(uniqueKeysWithValues: detail.team.map { ($0.key, ($0.name, $0.title, $0.emoji)) })
        all["ceo"] = ("Agent Tim", "CEO", "🐙")
        return all
    }

    /// Room first, then the most recent conversations, then everyone you haven't talked to yet.
    private var threads: [StartupThread] {
        let list = model.threads.isEmpty
            ? [StartupThread(key: "room", kind: "room", name: "Team room", members: detail.team.map(\.key) + ["ceo"])]
                + detail.team.map { StartupThread(key: $0.key, kind: "person", name: $0.name, title: $0.title, emoji: $0.emoji, members: [$0.key]) }
            : model.threads
        let room = list.filter { $0.kind == "room" }
        let rest = list.filter { $0.kind != "room" }.sorted { ($0.last?.ts ?? 0, $0.kind == "group" ? 1 : 0) > ($1.last?.ts ?? 0, $1.kind == "group" ? 1 : 0) }
        return room + rest
    }

    var body: some View {
        HStack(spacing: 0) {
            threadList.frame(width: 236)
            Divider()
            Group {
                if model.selectedThread == "room" {
                    RoomOrNotesRoom(model: model, detail: detail, stackRoot: stackRoot)
                } else if let thread = threads.first(where: { $0.key == model.selectedThread }) {
                    ThreadView(model: model, detail: detail, thread: thread, people: people, stackRoot: stackRoot)
                } else {
                    ContentUnavailableView("Pick a conversation", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: detail.id) {
            await model.loadThreads(stackRoot: stackRoot)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.dmChat?.typing == true ? 1.5 : 5))
                await model.loadThreads(stackRoot: stackRoot)
                if model.dmKey != nil { await model.refreshChat(stackRoot: stackRoot) }
            }
        }
    }

    // MARK: Conversation list

    private var threadList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Messages").font(.headline)
                Spacer()
                Button { model.composingGroup.toggle() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New group")
                    .accessibilityLabel("New group")
            }
            .padding(.horizontal, Theme.s3).padding(.vertical, Theme.s2)
            if model.composingGroup { groupComposer }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(threads) { thread in
                        Button { Task { await model.openThread(thread.key, stackRoot: stackRoot) } } label: { row(thread) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if thread.kind == "group" {
                                    Button("Delete group", role: .destructive) {
                                        Task { await model.deleteGroup(thread.key, stackRoot: stackRoot) }
                                    }
                                }
                            }
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .background(Theme.surfaceMuted)
    }

    private func row(_ thread: StartupThread) -> some View {
        let selected = model.selectedThread == thread.key
        return HStack(spacing: Theme.s2) {
            ThreadAvatar(thread: thread, startup: detail.id, people: people, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let ts = thread.last?.ts {
                        Text(Self.when(ts)).font(.caption2).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    }
                }
                Text(preview(thread)).font(.caption).lineLimit(2)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, Theme.s2).padding(.vertical, 7)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private func preview(_ thread: StartupThread) -> String {
        if thread.typing == true { return "typing…" }
        guard let last = thread.last else {
            return thread.kind == "person" ? (thread.title ?? "") : "\(thread.members.count) people"
        }
        let who = last.role == "founder" ? "You: " : (thread.kind == "person" ? "" : "\(people[last.role]?.name.split(separator: " ").first.map(String.init) ?? last.role): ")
        return who + last.content.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "**", with: "")
    }

    static func when(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        return Calendar.current.isDateInToday(date) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }

    private var groupComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Group name (optional)", text: $model.groupDraftName).textFieldStyle(.roundedBorder)
            Text("Who's in it?").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(people.sorted { $0.key == "ceo" ? false : $1.key == "ceo" ? true : $0.value.name < $1.value.name },
                            id: \.key) { key, person in
                        Toggle(isOn: Binding(get: { model.groupDraft.contains(key) },
                                             set: { on in if on { model.groupDraft.insert(key) } else { model.groupDraft.remove(key) } })) {
                            Text("\(person.name) · \(person.title)").font(.callout).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxHeight: 180)
            HStack {
                Spacer()
                Button("Cancel") { model.composingGroup = false; model.groupDraft = [] }
                Button("Create") { Task { await model.createGroup(stackRoot: stackRoot) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.groupDraft.count < 2 || model.busy != nil)
            }
        }
        .padding(Theme.s2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .padding(.horizontal, 6).padding(.bottom, 6)
    }
}

/// A conversation's avatar: Agent Tim, a person, or overlapping faces for a group or the room.
struct ThreadAvatar: View {
    let thread: StartupThread
    let startup: String
    let people: [String: (name: String, title: String, emoji: String)]
    var size: CGFloat = 40

    var body: some View {
        if thread.kind == "person" {
            face(thread.key, size: size)
        } else {
            ZStack(alignment: .topLeading) {
                ForEach(Array(thread.members.prefix(thread.kind == "room" ? 3 : 2).enumerated()), id: \.offset) { index, key in
                    face(key, size: size * 0.62)
                        .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 1.5))
                        .offset(x: CGFloat(index) * size * 0.19, y: CGFloat(index) * size * 0.19)
                }
            }
            .frame(width: size, height: size, alignment: .topLeading)
        }
    }

    @ViewBuilder private func face(_ key: String, size: CGFloat) -> some View {
        if key == "ceo" { TimAvatar(size: size) } else {
            AvatarView(image: Avatars.teamMember(key, startup: startup), emoji: people[key]?.emoji ?? "🙂", size: size)
        }
    }
}

/// One conversation (1:1 or group): bubbles, typing, and a composer.
struct ThreadView: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let thread: StartupThread
    let people: [String: (name: String, title: String, emoji: String)]
    let stackRoot: URL?
    @State private var draftHeight: CGFloat = 44

    private var isGroup: Bool { thread.kind == "group" }
    private var firstName: String { thread.name.split(separator: " ").first.map(String.init) ?? thread.name }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.s2) {
                ThreadAvatar(thread: thread, startup: detail.id, people: people, size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.name).font(.headline)
                    Text(isGroup ? thread.members.compactMap { people[$0]?.name.split(separator: " ").first.map(String.init) }.joined(separator: ", ")
                                 : "\(thread.title ?? "") · private")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, Theme.s2)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        let messages = model.dmChat?.messages ?? []
                        if messages.isEmpty {
                            Text(isGroup ? "Everyone in the group answers in turn; @Name asks one person. The rest of the team doesn't see it."
                                         : "Ask \(firstName) anything: a draft, a number, a decision. They answer in character and act on it in the next meeting.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, Theme.s4)
                        }
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            let grouped = index > 0 && messages[index - 1].role == message.role
                            bubble(message, grouped: grouped).id(message.id)
                        }
                        if model.dmChat?.typing == true {
                            let who = model.dmChat?.speaking.flatMap { people[$0]?.name.split(separator: " ").first.map(String.init) } ?? firstName
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("\(who) is typing…").font(.callout).foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, Theme.s3)
                }
                .onChange(of: model.dmChat?.messages.count) {
                    if let last = model.dmChat?.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }

            Divider()
            HStack(alignment: .bottom, spacing: Theme.s2) {
                ComposerTextView(text: $model.dmDraft, placeholder: isGroup ? "Message \(thread.name)…  (@Name asks one person)" : "Message \(firstName)…",
                                 minHeight: 44, maxHeight: 160,
                                 mentions: isGroup ? thread.members.compactMap { people[$0]?.name.split(separator: " ").first.map(String.init) } : [],
                                 onSubmit: { Task { await model.sendDM(stackRoot: stackRoot) } }, height: $draftHeight)
                    .frame(height: draftHeight)
                    .padding(6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
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

    private func bubble(_ message: DirectChat.Message, grouped: Bool) -> some View {
        let sender = people[message.role]
        return HStack(alignment: .bottom, spacing: Theme.s2) {
            if message.fromFounder {
                Spacer(minLength: 60)
            } else if grouped {
                Color.clear.frame(width: 26, height: 1)
            } else {
                ThreadAvatar(thread: StartupThread(key: message.role, kind: "person", name: sender?.name ?? "", members: [message.role]),
                             startup: detail.id, people: people, size: 26)
            }
            VStack(alignment: message.fromFounder ? .trailing : .leading, spacing: 2) {
                if isGroup && !message.fromFounder && !grouped {
                    Text(sender?.name.split(separator: " ").first.map(String.init) ?? message.role)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Self.color(message.role))
                        .padding(.leading, 10)
                }
                Text(LocalizedStringKey(message.content))
                    .font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(message.fromFounder ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surfaceMuted),
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(message.fromFounder ? Color.white : Color.primary)
            }
            if !message.fromFounder { Spacer(minLength: 60) }
        }
        .padding(.top, grouped ? 0 : 4)
    }

    /// A stable color per person's name in group chats.
    static func color(_ key: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .brown, .cyan]
        return palette[abs(key.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % palette.count]
    }
}
