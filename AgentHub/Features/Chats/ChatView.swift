import AVKit
import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let conversationID: UUID
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var attachError: String?
    @State private var dropTargeted = false
    @State private var importing = false
    @State private var composerHeight: CGFloat = 84

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        if let conversation {
            VStack(spacing: 0) {
                if conversation.isMeeting {
                    ParticipantsBar(conversation: conversation)
                }
                if conversation.isMeeting && conversation.messages.isEmpty {
                    PickRoom(conversation: conversation)
                } else if conversation.messages.isEmpty {
                    EmptyChat { draft = $0 }
                } else {
                    messages(conversation)
                }
                composer(conversation)
            }
            .background(Theme.surfaceMuted)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in addFiles([url]) }
                    }
                }
                return !providers.isEmpty
            }
            .overlay { if dropTargeted { DropHint() } }
            .animation(.easeOut(duration: 0.18), value: dropTargeted)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { addFiles(urls) }
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
                LazyVStack(alignment: .leading, spacing: Theme.s4) {
                    let messages = conversation.messages
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let speaker = conversation.isMeeting ? store.speaker(of: message) : nil
                        MessageRow(message: message, model: store.model(id: message.modelID),
                                   agent: message.agentID.flatMap { id in store.agents.first { $0.id == id } }
                                       ?? store.agent(for: conversation),
                                   showsName: conversation.isMeeting,
                                   mentionNames: conversation.isMeeting ? store.members(in: conversation).map(\.mention) : [],
                                   speaker: speaker,
                                   groupedWithPrevious: conversation.isMeeting && index > 0 && message.role == .assistant
                                       && messages[index - 1].role == .assistant
                                       && speaker != nil && store.speaker(of: messages[index - 1])?.id == speaker?.id)
                            .id(message.id)
                    }
                }
                .frame(maxWidth: Theme.readableWidth)
                .padding(.horizontal, Theme.s6)
                .padding(.vertical, Theme.s6)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: conversation.messages.last?.content) {
                if let id = conversation.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear {
                if let id = conversation.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    private func composer(_ conversation: Conversation) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            if !attachments.isEmpty || attachError != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.s2) {
                        ForEach(attachments) { file in
                            AttachmentChip(file: file) { attachments.removeAll { $0.id == file.id } }
                        }
                        if let attachError {
                            Label(attachError, systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(Theme.warning)
                        }
                    }
                }
            }
            VStack(spacing: 0) {
                ComposerTextView(text: $draft,
                                 placeholder: conversation.isMeeting ? "Message the group…  (@Name asks one member · Tab completes)"
                                                                     : "Message Agent Tim…  (@model · /skill · drop files)",
                                 minHeight: 84, maxHeight: 320,
                                 mentions: conversation.isMeeting ? store.members(in: conversation).map(\.mention) : [],
                                 onSubmit: { submit(conversation) },
                                 height: $composerHeight,
                                 onTab: { completeMention(in: conversation) })
                    .frame(height: composerHeight)
                    .padding(.horizontal, Theme.s2)
                    .padding(.top, Theme.s1)
                HStack(spacing: Theme.s3) {
                    Button { importing = true } label: {
                        Image(systemName: "paperclip").font(.system(size: 17, weight: .medium))
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Attach files (or drag them into the chat)")
                    .accessibilityLabel("Attach files")
                    RoutePreview(text: draft, conversation: conversation)
                    Spacer(minLength: Theme.s2)
                    Text("⏎ send · ⇧⏎ new line").font(.caption).foregroundStyle(.tertiary)
                    Button { submit(conversation) } label: {
                        Image(systemName: store.isStreaming(conversation.id) ? "ellipsis" : "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(canSend(conversation) ? Theme.accent : Color.secondary.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend(conversation))
                    .accessibilityLabel("Send")
                    .help("Send (Return)")
                }
                .padding(.horizontal, Theme.s3)
                .padding(.bottom, Theme.s2)
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
                .strokeBorder(Theme.accent.opacity(draft.isEmpty ? 0.25 : 0.6), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 2)
        }
        .frame(maxWidth: Theme.readableWidth + 80)
        .padding(.horizontal, Theme.s6)
        .padding(.top, Theme.s2)
        .padding(.bottom, Theme.bottomInset)
        .frame(maxWidth: .infinity)
    }

    static func firstName(_ agent: Agent) -> String {
        agent.name.split(separator: " ").first.map(String.init) ?? agent.name
    }

    /// Tab after "@Pr" in a meeting → "@Product " (the first agent whose name starts with it).
    private func completeMention(in conversation: Conversation) -> Bool {
        guard conversation.isMeeting, let query = StartupModel.mentionQuery(in: draft) else { return false }
        guard let member = store.members(in: conversation).first(where: {
            $0.mention.lowercased().hasPrefix(query)
        }) else { return false }
        draft = String(draft.dropLast(query.count + 1)) + "@\(member.mention) "
        return true
    }

    private func canSend(_ conversation: Conversation) -> Bool {
        if conversation.isMeeting && store.members(in: conversation).isEmpty { return false }
        return ChatComposer.canSend(draft: draft, attachments: attachments) && !store.isStreaming(conversation.id)
    }

    private func submit(_ conversation: Conversation) {
        guard canSend(conversation) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        draft = ""
        attachments = []
        attachError = nil
        if conversation.isMeeting {
            store.sendToMeeting(text, attachments: files, in: conversation.id)
        } else {
            store.send(text, attachments: files, in: conversation.id)
        }
    }

    private func addFiles(_ urls: [URL]) {
        let result = ChatComposer.add(urls, to: attachments)
        attachments = result.attachments
        attachError = result.error
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

/// A new conversation: Tim says hi and offers a few starting points.
private struct EmptyChat: View {
    let pick: (String) -> Void
    static let starters = [
        ("lightbulb", "Validate my startup idea", "/validate-your-startup "),
        ("chevron.left.forwardslash.chevron.right", "Review some code", "Review this code and suggest improvements:\n"),
        ("film", "Make a short video", "Make a video of "),
        ("photo", "Draw an image", "Make an image of "),
    ]

    var body: some View {
        VStack(spacing: Theme.s4) {
            Spacer()
            TimAvatar(size: 88)
            Text("What are we working on?").headlineStyle(28)
            Text("Ask anything. Agent Tim picks the right model, or pin one with @alias.")
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.s3) {
                ForEach(Self.starters, id: \.1) { symbol, title, prompt in
                    Button { pick(prompt) } label: {
                        Label(title, systemImage: symbol)
                            .frame(maxWidth: .infinity, minHeight: Theme.target, alignment: .leading)
                            .padding(.horizontal, Theme.s4)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 520)
            .padding(.top, Theme.s2)
            Spacer()
        }
        .padding(Theme.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    var agent: Agent?
    /// Meeting rooms show who's talking above each reply.
    var showsName = false
    var mentionNames: [String] = []
    /// In a group chat: who wrote this (an agent or a skill).
    var speaker: AppStore.Member? = nil
    /// The same member's earlier message is right above: no avatar or name again.
    var groupedWithPrevious = false

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s3) {
            if isUser {
                Spacer(minLength: 60)
            } else if groupedWithPrevious {
                Color.clear.frame(width: 32, height: 1)
            } else if let speaker {
                MemberAvatar(member: speaker, size: 32).padding(.top, 2)
            } else {
                AvatarView(agent: agent, size: 32).padding(.top, 2)
            }
            VStack(alignment: isUser ? .trailing : .leading, spacing: Theme.s1 + 2) {
                if showsName, !isUser, !groupedWithPrevious, let name = speaker?.name ?? agent?.name {
                    HStack(spacing: 6) {
                        Text(name).font(.callout.weight(.semibold))
                            .foregroundStyle(MemberAvatar.color(for: speaker?.id ?? agent?.id))
                        if speaker?.skill != nil {
                            Text("Skill").font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.12), in: Capsule())
                        }
                    }
                }
                if !(isUser && message.content.isEmpty) {
                    Group {
                        if message.content.isEmpty && message.role == .assistant {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                if showsName { Text("\(speaker?.name ?? agent?.name ?? "") is typing…").font(.callout).foregroundStyle(.secondary) }
                            }
                            .padding(Theme.s3)
                        } else {
                            Text(LocalizedStringKey(mentionNames.isEmpty ? message.content
                                                    : StartupDetail.boldMentions(message.content, names: mentionNames)))
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(.horizontal, Theme.s4)
                                .padding(.vertical, Theme.s3)
                        }
                    }
                    .background(background, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay {
                        if !isUser {
                            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border)
                        }
                    }
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                }

                if let files = message.attachments, !files.isEmpty {
                    HStack(spacing: Theme.s2) {
                        ForEach(files) { AttachmentChip(file: $0) }
                    }
                }

                ForEach(media, id: \.url) { item in
                    Group {
                        if item.isVideo {
                            VideoPlayer(player: AVPlayer(url: item.url))
                        } else {
                            AsyncImage(url: item.url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: 460)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }

                if message.role == .assistant, let model {
                    Label {
                        Text(model.displayName) + Text(message.routingReason.map { " · \($0)" } ?? "")
                    } icon: {
                        Image(systemName: model.locationSymbol)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if !isUser { Spacer(minLength: 60) }
        }
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
        if message.isError { return AnyShapeStyle(Color.red.opacity(0.12)) }
        return isUser ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.assistantBubble)
    }
}

/// Composer rules shared by the view and tests.
enum ChatComposer {
    static func canSend(draft: String, attachments: [ChatAttachment]) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Adds files (skipping duplicates by name, up to the limit); returns the first problem, if any.
    static func add(_ urls: [URL], to current: [ChatAttachment]) -> (attachments: [ChatAttachment], error: String?) {
        var attachments = current
        var error: String?
        for url in urls {
            guard attachments.count < ChatAttachment.maxFiles else {
                error = "Up to \(ChatAttachment.maxFiles) files per message."
                break
            }
            if attachments.contains(where: { $0.name == url.lastPathComponent }) { continue }
            do {
                attachments.append(try ChatAttachment.load(url))
            } catch let failure {
                error = failure.localizedDescription
            }
        }
        return (attachments, error)
    }
}

private struct AttachmentChip: View {
    let file: ChatAttachment
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: file.symbol)
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Text(file.sizeLabel).foregroundStyle(.secondary)
            if !file.isReadable {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                    .help("The model gets the file name only: it can't read this kind of file.")
            } else if file.truncated {
                Image(systemName: "scissors").foregroundStyle(.secondary)
                    .help("Long file: the model gets the first \(ChatAttachment.maxTextCharacters / 1000)k characters.")
            }
            if let remove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .frame(maxWidth: 260)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.7), in: Capsule())
    }
}

private struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                Label("Drop files to attach", systemImage: "paperclip")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(8)
            .allowsHitTesting(false)
    }
}

/// An agent's or skill's avatar in a group chat.
struct MemberAvatar: View {
    let member: AppStore.Member
    var size: CGFloat = 32

    var body: some View {
        if let agent = member.agent {
            AvatarView(agent: agent, size: size)
        } else {
            Image(systemName: "wand.and.stars")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Self.color(for: member.id).gradient, in: Circle())
        }
    }

    /// A stable color per member, so each name reads like a group chat.
    static func color(for id: UUID?) -> Color {
        guard let id else { return .secondary }
        let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red, .brown, .cyan]
        return palette[Int(id.uuid.0 ^ id.uuid.15) % palette.count]
    }
}

/// Overlapping avatars of the first few members.
struct StackedAvatars: View {
    let members: [AppStore.Member]
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(members.prefix(4)) { member in
                MemberAvatar(member: member, size: size)
                    .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
            }
            if members.count > 4 {
                Text("+\(members.count - 4)").font(.caption2.weight(.bold))
                    .frame(width: size, height: size)
                    .background(Theme.surfaceMuted, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.surface, lineWidth: 2))
            }
        }
    }
}

/// The group chat's header: stacked avatars, member chips (remove with ×) and Add (agents or skills).
private struct ParticipantsBar: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation

    var body: some View {
        let members = store.members(in: conversation)
        HStack(spacing: Theme.s3) {
            StackedAvatars(members: members)
            VStack(alignment: .leading, spacing: 0) {
                Text("Group chat").font(.callout.weight(.semibold))
                Text(members.isEmpty ? "No members yet" : "\(members.count) member\(members.count == 1 ? "" : "s") · you")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(members) { member in
                        HStack(spacing: 5) {
                            MemberAvatar(member: member, size: 20)
                            Text(member.name).font(.callout)
                            Button { store.toggle(member, in: conversation.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                                .help("Remove \(member.name) from the group")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.border))
                    }
                }
            }
            Menu {
                Section("Agents") {
                    ForEach(store.agents.filter { agent in !members.contains { $0.id == agent.id } }) { agent in
                        Button("\(agent.emoji) \(agent.name)") { store.toggle(agent: agent.id, in: conversation.id) }
                    }
                }
                Section("Skills") {
                    ForEach(store.skills.filter { skill in !members.contains { $0.id == skill.id } }) { skill in
                        Button("🪄 \(skill.name)") { store.toggle(skill: skill.id, in: conversation.id) }
                    }
                }
            } label: {
                Label("Add", systemImage: "person.badge.plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s2)
        .background(.bar)
    }
}

/// A new group chat: tap agents and skills to add or remove them, then send the first message below.
private struct PickRoom: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation

    var body: some View {
        let chosen = Set(store.members(in: conversation).map(\.id))
        ScrollView {
            VStack(spacing: Theme.s4) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 40)).foregroundStyle(.tint)
                Text("Who's in the group chat?").headlineStyle(26)
                Text("Pick agents and skills. Everyone answers each message in turn; tag @Name to ask one. Then type below.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                section("Agents", items: store.agents.map {
                    AppStore.Member(id: $0.id, name: $0.name, emoji: $0.emoji, agent: $0)
                }, subtitle: { $0.agent?.summary ?? "" }, chosen: chosen)
                section("Skills", items: store.skills.map {
                    AppStore.Member(id: $0.id, name: $0.name, emoji: "🪄", skill: $0)
                }, subtitle: { $0.skill?.summary ?? "" }, chosen: chosen)
            }
            .padding(Theme.s8)
            .frame(maxWidth: .infinity)
        }
    }

    private func section(_ title: String, items: [AppStore.Member], subtitle: @escaping (AppStore.Member) -> String,
                         chosen: Set<UUID>) -> some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text(title).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.s3)], spacing: Theme.s3) {
                ForEach(items) { member in
                    let isIn = chosen.contains(member.id)
                    Button { store.toggle(member, in: conversation.id) } label: {
                        HStack(spacing: Theme.s2) {
                            MemberAvatar(member: member, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(member.name).font(.callout.weight(.semibold))
                                Text(subtitle(member)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: isIn ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(isIn ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                        .padding(Theme.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(isIn ? Theme.accent : Theme.border, lineWidth: isIn ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isIn ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: 820)
    }
}
