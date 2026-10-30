import AVKit
import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    let conversationID: UUID
    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var attachError: String?
    @State private var dropTargeted = false
    @State private var composerHeight: CGFloat = 38

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        if let conversation {
            VStack(spacing: 0) {
                if conversation.isMeeting, let brief = conversation.brief, brief.stage != "done" {
                    IdeaInterview(conversation: conversation)
                } else if conversation.isMeeting && conversation.messages.isEmpty {
                    PickRoom(conversation: conversation)
                } else if conversation.messages.isEmpty {
                    EmptyChat { draft = $0 }
                } else {
                    messages(conversation)
                }
                if !(conversation.brief.map { $0.stage != "done" } ?? false) {
                    composer(conversation)
                }
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
            .navigationTitle(conversation.title)
            .navigationSubtitle(subtitle(conversation))
            .onAppear { store.markRead(conversation.id); store.visibleConversationID = conversation.id }
            .onDisappear { if store.visibleConversationID == conversation.id { store.visibleConversationID = nil } }
            .onChange(of: conversation.messages.count) { store.markRead(conversation.id) }
            .onChange(of: store.isStreaming(conversation.id)) { store.markRead(conversation.id) }
            .toolbar {
                // Every option for this chat lives up here (like Messages and Slack).
                ToolbarItemGroup(placement: .primaryAction) {
                    if conversation.isMeeting {
                        MembersButton(conversation: conversation)
                        DiscussionMenu(conversation: conversation)
                    } else {
                        AgentMenu(conversation: conversation)
                    }
                    modelMenu(conversation)
                    MoreMenu(conversation: conversation)
                }
            }
        } else {
            ContentUnavailableView("Conversation deleted", systemImage: "trash")
        }
    }

    private func messages(_ conversation: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let messages = conversation.messages
                    let lastAssistant = messages.lastIndex { $0.role == .assistant }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        let speaker = conversation.isMeeting ? store.speaker(of: message) : nil
                        let previous = index > 0 ? messages[index - 1] : nil
                        let divider = ChatTimeline.showsDivider(message, after: previous)
                        let grouped = !divider && ChatTimeline.groups(message, with: previous,
                            sameSpeaker: !conversation.isMeeting || (speaker != nil && store.speaker(of: previous!)?.id == speaker?.id))
                        VStack(spacing: 0) {
                            if divider {
                                Text(ChatTimeline.label(message.createdAt))
                                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, index == 0 ? 0 : Theme.s4).padding(.bottom, Theme.s2)
                            }
                            MessageRow(message: message, model: store.model(id: message.modelID),
                                       agent: message.agentID.flatMap { id in store.agents.first { $0.id == id } }
                                           ?? store.agent(for: conversation),
                                       showsName: conversation.isMeeting,
                                       mentionNames: conversation.isMeeting ? store.members(in: conversation).map(\.mention) : [],
                                       speaker: speaker,
                                       groupedWithPrevious: grouped,
                                       onRetry: index == lastAssistant && !store.isStreaming(conversation.id)
                                           ? { store.retryLast(in: conversation.id) } : nil)
                                .padding(.top, divider ? 0 : grouped ? 3 : Theme.s3)
                        }
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
            queue(conversation)
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
            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                RoutePreview(text: draft, conversation: conversation).padding(.leading, 48)
            }
            HStack(alignment: .bottom, spacing: Theme.s2) {
                Menu {
                    Button("Files or images…", systemImage: "doc.badge.plus") { pick(folders: false) }
                    Button("Folder or codebase…", systemImage: "folder.badge.plus") { pick(folders: true) }
                    Divider()
                    Button("Paste image", systemImage: "doc.on.clipboard") { _ = paste(.general) }
                        .disabled(!ChatComposer.hasImage(.general))
                } label: {
                    Image(systemName: "plus").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(Theme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.border))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Attach files, images or a folder (or drag them in, or paste a screenshot)")
                .accessibilityLabel("Attach files, images or a folder")
                HStack(alignment: .bottom, spacing: 4) {
                    ComposerTextView(text: $draft,
                                     placeholder: conversation.isMeeting ? "Message the group" : "Message \(store.agent(for: conversation)?.name ?? "Agent Tim")",
                                     minHeight: 38, maxHeight: 220,
                                     mentions: conversation.isMeeting ? store.members(in: conversation).map(\.mention) : [],
                                     onSubmit: { submit(conversation) },
                                     height: $composerHeight,
                                     onTab: { completeMention(in: conversation) },
                                     onPaste: paste)
                        .frame(height: composerHeight)
                        .padding(.leading, Theme.s2)
                    Button { submit(conversation) } label: {
                        Image(systemName: store.isStreaming(conversation.id) ? "text.badge.plus" : "arrow.up")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(canSend(conversation) ? Theme.accent : Color.secondary.opacity(0.3), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend(conversation))
                    .padding(.trailing, 5).padding(.bottom, 5)
                    .accessibilityLabel(store.isStreaming(conversation.id) ? "Queue" : "Send")
                    .help(store.isStreaming(conversation.id) ? "Queue it (Return): it sends when the reply finishes"
                          : conversation.isMeeting ? "Send (Return) · Shift-Return for a new line · @Name asks one member, Tab completes"
                                                 : "Send (Return) · Shift-Return for a new line · @model picks a model · /skill uses a skill")
                }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .strokeBorder(draft.isEmpty ? Theme.border : Theme.accent.opacity(0.55), lineWidth: 1))
            }
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
        return ChatComposer.canSend(draft: draft, attachments: attachments)
    }

    private func submit(_ conversation: Conversation) {
        guard canSend(conversation) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        draft = ""
        attachments = []
        attachError = nil
        // Still answering? It queues and goes out when the reply finishes.
        store.submit(text, attachments: files, in: conversation.id)
    }

    /// Messages waiting for the current reply, with Edit (back into the box) and Remove.
    @ViewBuilder
    private func queue(_ conversation: Conversation) -> some View {
        let queued = store.queuedMessages[conversation.id] ?? []
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(queued.count == 1 ? "Queued: sends when the reply finishes" : "\(queued.count) queued: sent one by one as each reply finishes")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(queued.enumerated()), id: \.element.id) { index, message in
                    HStack(spacing: Theme.s2) {
                        Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 14)
                        Image(systemName: "clock").font(.caption).foregroundStyle(.secondary)
                        Text(message.text.isEmpty ? message.attachments.map { "📎 \($0.name)" }.joined(separator: " ") : message.text)
                            .lineLimit(1).truncationMode(.tail)
                        if !message.text.isEmpty && !message.attachments.isEmpty {
                            Text("📎 \(message.attachments.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Edit") {
                            guard let taken = store.takeQueued(message.id, in: conversation.id) else { return }
                            draft = draft.isEmpty ? taken.text : draft + "\n" + taken.text  // never overwrite what you're typing
                            attachments += taken.attachments
                        }
                        .buttonStyle(.borderless)
                        .help("Take it back into the message box")
                        Button { store.removeQueued(message.id, in: conversation.id) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from the queue")
                        .accessibilityLabel("Remove queued message")
                    }
                    .font(.callout)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                }
            }
            .padding(.leading, 42)
        }
    }

    private func addFiles(_ urls: [URL]) {
        let result = ChatComposer.add(urls, to: attachments)
        attachments = result.attachments
        attachError = result.error
    }

    /// The + menu: pick files and images, or a folder (a codebase is read as its tree plus its code).
    private func pick(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !folders
        panel.canChooseDirectories = folders
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = folders ? "Choose a folder or codebase. Code and text files are read; dependencies, build output and secrets are skipped."
                                : "Choose files or images to attach."
        panel.begin { response in
            if response == .OK { addFiles(panel.urls) }
        }
    }

    /// ⌘V: copied files or a screenshot become attachments; text pastes as usual.
    private func paste(_ board: NSPasteboard) -> Bool {
        let result = ChatComposer.paste(board, to: attachments)
        guard let result else { return false }
        attachments = result.attachments
        attachError = result.error
        return true
    }

    /// Per-conversation override: Auto (router) or a pinned model.
    /// Under the title: what the agent does, or the group's members and how they talk.
    private func subtitle(_ conversation: Conversation) -> String {
        guard conversation.isMeeting else { return store.agent(for: conversation)?.summary ?? "" }
        let members = store.members(in: conversation)
        guard !members.isEmpty else { return "No members yet" }
        let rounds = conversation.discussionRounds ?? 1
        let mode = rounds == 1 ? "one answer each" : rounds >= AppStore.maxRounds ? "talk until they agree" : "\(rounds) rounds"
        return members.map(\.name).joined(separator: ", ") + " · " + mode
    }

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
        .help(conversation.isMeeting ? "One model for the whole group (members' own models come first)"
                                     : "The model for this chat: Auto lets the router pick each time")
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
    /// The same sender's earlier message is right above: no avatar or name again.
    var groupedWithPrevious = false
    /// Shown on the last reply: ask again.
    var onRetry: (() -> Void)? = nil
    @State private var hovering = false
    @State private var copied = false

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
                            TypingDots()
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .accessibilityLabel("\(speaker?.name ?? agent?.name ?? "The agent") is typing")
                        } else {
                            Text(LocalizedStringKey(mentionNames.isEmpty ? message.content
                                                    : StartupDetail.boldMentions(message.content, names: mentionNames)))
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                        }
                    }
                    .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .overlay(alignment: isUser ? .topLeading : .topTrailing) {
                        if hovering && !message.content.isEmpty { actions.offset(x: isUser ? -8 : 8, y: -14) }
                    }
                }

                if let files = message.attachments, !files.isEmpty {
                    let pictures = files.compactMap { file in file.imageURL.flatMap { url in NSImage(contentsOf: url).map { (file, url, $0) } } }
                    if !pictures.isEmpty {
                        HStack(spacing: Theme.s2) {
                            ForEach(pictures, id: \.0.id) { file, url, image in
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(maxWidth: pictures.count == 1 ? 280 : 140, maxHeight: pictures.count == 1 ? 220 : 120)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .onTapGesture { NSWorkspace.shared.open(url) }
                                    .help("\(file.name): click to open")
                            }
                        }
                    }
                    let others = files.filter { $0.imageURL == nil }
                    if !others.isEmpty {
                        HStack(spacing: Theme.s2) {
                            ForEach(others) { AttachmentChip(file: $0) }
                        }
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

                if message.role == .assistant, let model, !message.content.isEmpty {
                    Label(model.displayName, systemImage: model.locationSymbol)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 6)
                        .help(message.routingReason.map { "\(model.displayName): \($0)" } ?? model.displayName)
                }
            }
            if !isUser { Spacer(minLength: 60) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// Slack-style actions on hover: copy, and ask again on the last reply.
    private var actions: some View {
        HStack(spacing: 2) {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.content, forType: .string)
                copied = true
            } label: { Image(systemName: copied ? "checkmark" : "doc.on.doc").frame(width: 26, height: 24) }
                .help("Copy")
            if let onRetry, !isUser {
                Button(action: onRetry) { Image(systemName: "arrow.clockwise").frame(width: 26, height: 24) }
                    .help("Ask again")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
        .onDisappear { copied = false }
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
            if attachments.contains(where: { $0.name == url.lastPathComponent || $0.name == url.lastPathComponent + "/" }) { continue }
            do {
                attachments.append(try ChatAttachment.load(url))
            } catch let failure {
                error = failure.localizedDescription
            }
        }
        return (attachments, error)
    }

    /// Copied files, or an image on the clipboard (a screenshot); nil when it's just text to paste.
    static func paste(_ board: NSPasteboard, to current: [ChatAttachment]) -> (attachments: [ChatAttachment], error: String?)? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return add(urls, to: current)
        }
        guard hasImage(board), let data = board.data(forType: .png) ?? board.data(forType: .tiff) else { return nil }
        guard current.count < ChatAttachment.maxFiles else { return (current, "Up to \(ChatAttachment.maxFiles) files per message.") }
        let number = current.filter { $0.name.hasPrefix("Pasted image") }.count + 1
        guard let image = ChatAttachment.image(data, name: "Pasted image \(number).jpg") else { return (current, "Couldn't read the pasted image.") }
        return (current + [image], nil)
    }

    /// An image, and not text that happens to carry one (copying from a document puts both on the clipboard).
    static func hasImage(_ board: NSPasteboard) -> Bool {
        board.string(forType: .string) == nil && board.availableType(from: [.png, .tiff]) != nil
    }
}

private struct AttachmentChip: View {
    let file: ChatAttachment
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            if let url = file.imageURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: file.symbol)
            }
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Text(file.sizeLabel).foregroundStyle(.secondary)
            if !file.isReadable {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                    .help("The model gets the file name only: it can't read this kind of file.")
            } else if file.kind == .folder, file.truncated {
                Image(systemName: "scissors").foregroundStyle(.secondary)
                    .help("Big folder: the model gets \(file.filesRead ?? 0) of \(file.filesTotal ?? 0) files (key files first) and the full file list.")
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
/// Toolbar: the group's members (their models, remove, add, new persona) in a panel.
private struct MembersButton: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation
    @State private var open = false

    var body: some View {
        let members = store.members(in: conversation)
        Button { open.toggle() } label: {
            // A symbol and the count: toolbars draw images at their full size.
            Label("\(members.count)", systemImage: "person.2.fill")
                .labelStyle(.titleAndIcon).font(.footnote.monospacedDigit())
        }
        .help("Members: who's in this group, and the model each one uses")
        .accessibilityLabel("Members, \(members.count)")
        .popover(isPresented: $open, arrowEdge: .bottom) { MembersPanel(conversation: conversation) }
    }
}

private struct MembersPanel: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation
    @State private var newPersona = false
    @State private var personaName = ""
    @State private var personaDescription = ""

    private var chatModels: [AIModel] { store.availableModels.filter { !$0.isExplicitOnly } }

    var body: some View {
        let members = store.members(in: conversation)
        VStack(alignment: .leading, spacing: Theme.s2) {
            Text("Members").font(.headline)
            if members.isEmpty {
                Text("Nobody yet: add agents or skills below.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(members) { member in row(member) }
            Divider()
            HStack {
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
                } label: { Label("Add", systemImage: "person.badge.plus") }
                    .fixedSize()
                Button("New persona…", systemImage: "theatermasks") { newPersona.toggle() }
                Spacer()
                Toggle("A model each", isOn: Binding(get: { conversation.autoDivideModels == true },
                                                     set: { store.setAutoDivide($0, in: conversation.id) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .help("Give each member a different available model")
            }
            if newPersona { personaForm }
        }
        .padding(Theme.s4)
        .frame(width: 420)
    }

    private func row(_ member: AppStore.Member) -> some View {
        let model = store.model(for: member, in: conversation)
        return HStack(spacing: Theme.s2) {
            MemberAvatar(member: member, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(member.name).font(.callout.weight(.semibold))
                Text(member.skill != nil ? "Skill" : (member.agent?.summary ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button(conversation.autoDivideModels == true ? "Divided automatically" : "Auto (the router picks)") {
                    store.setMemberModel(nil, for: member.id, in: conversation.id)
                }
                Divider()
                ForEach(chatModels) { option in
                    Button(option.displayName) { store.setMemberModel(option.id, for: member.id, in: conversation.id) }
                }
            } label: { Text(model?.displayName ?? "Auto").font(.caption) }
                .fixedSize()
                .help("The model \(member.name) thinks with")
            Button { store.toggle(member, in: conversation.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Remove \(member.name)")
        }
    }

    private var personaForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Name, e.g. Skeptical Editor", text: $personaName).textFieldStyle(.roundedBorder)
            TextField("Who they are and how they write", text: $personaDescription, axis: .vertical)
                .lineLimit(2...5).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Add to the group") {
                    store.newPersona(name: personaName, description: personaDescription, in: conversation.id)
                    personaName = ""
                    personaDescription = ""
                    newPersona = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(personaName.trimmingCharacters(in: .whitespaces).isEmpty
                          || personaDescription.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

/// Toolbar: how the group talks after your message.
private struct DiscussionMenu: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation

    var body: some View {
        let rounds = conversation.discussionRounds ?? 1
        Menu {
            Picker("After your message", selection: Binding(get: { rounds },
                                                          set: { store.setDiscussionRounds($0, in: conversation.id) })) {
                Text("Each answers once").tag(1)
                Text("2 rounds: they reply to each other").tag(2)
                Text("3 rounds").tag(3)
                Text("Until they agree (max \(AppStore.maxRounds))").tag(AppStore.maxRounds)
            }
            .pickerStyle(.inline)
        } label: {
            Label(rounds == 1 ? "Once" : rounds >= AppStore.maxRounds ? "Until agreed" : "\(rounds) rounds",
                  systemImage: "bubble.left.and.bubble.right")
                .labelStyle(.titleAndIcon).font(.footnote)
        }
        .help("Discussion: let the members talk to each other after your message")
    }
}

/// Toolbar (direct chats): switch who you're talking to.
private struct AgentMenu: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation

    var body: some View {
        let current = store.agent(for: conversation)
        Menu {
            ForEach(store.agents) { agent in
                Button { store.switchAgent(conversation.id, to: agent.id) } label: {
                    Label("\(agent.emoji) \(agent.name)", systemImage: agent.id == current?.id ? "checkmark" : "")
                }
            }
        } label: {
            // Text only: toolbars draw images at their full size.
            Text("\(current?.emoji ?? "🤖") \(current?.name ?? "Agent")").font(.footnote)
        }
        .help("The agent you're talking to (the history stays)")
    }
}

/// Toolbar: rename, copy or export, clear, delete.
private struct MoreMenu: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmClear = false
    @State private var confirmDelete = false

    var body: some View {
        Menu {
            Button("Rename…", systemImage: "pencil") { newTitle = conversation.title; renaming = true }
            Button("Copy as Markdown", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.markdown(conversation), forType: .string)
            }
            Button("Export…", systemImage: "square.and.arrow.up") { export() }
            Divider()
            Button("Clear messages…", systemImage: "eraser") { confirmClear = true }
                .disabled(conversation.messages.isEmpty)
            Button("Delete chat…", systemImage: "trash", role: .destructive) { confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .help("More: rename, copy, export, clear or delete this chat")
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            HStack {
                TextField("Name", text: $newTitle).textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit { store.rename(conversation.id, to: newTitle); renaming = false }
                Button("Save") { store.rename(conversation.id, to: newTitle); renaming = false }
                    .buttonStyle(.borderedProminent)
            }
            .padding(Theme.s3)
        }
        .confirmationDialog("Clear all messages in “\(conversation.title)”?", isPresented: $confirmClear) {
            Button("Clear messages", role: .destructive) { store.clearMessages(conversation.id) }
        } message: { Text("The chat, its members and settings stay.") }
        .confirmationDialog("Delete “\(conversation.title)”?", isPresented: $confirmDelete) {
            Button("Delete chat", role: .destructive) { store.deleteConversation(conversation.id) }
        } message: { Text("This can't be undone.") }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = conversation.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.markdown(conversation).write(to: url, atomically: true, encoding: .utf8)
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

/// When to show a time divider and when to group bubbles (iMessage-style).
enum ChatTimeline {
    /// A divider before the first message and after a 15-minute gap.
    static func showsDivider(_ message: ChatMessage, after previous: ChatMessage?) -> Bool {
        guard let previous else { return true }
        return message.createdAt.timeIntervalSince(previous.createdAt) > 15 * 60
    }

    /// Same sender, within two minutes: one group (no repeated avatar, tighter spacing).
    static func groups(_ message: ChatMessage, with previous: ChatMessage?, sameSpeaker: Bool) -> Bool {
        guard let previous, previous.role == message.role, sameSpeaker else { return false }
        return message.createdAt.timeIntervalSince(previous.createdAt) < 2 * 60
    }

    /// "Today 10:42", "Yesterday 18:05", "Tuesday 09:12", "Oct 3, 14:20".
    static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.wide))) \(time)"
        }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }
}

/// iMessage's typing bubble: three dots that pulse in turn.
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.15)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.3) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.secondary.opacity(i == phase ? 0.9 : 0.35)).frame(width: 7, height: 7)
                }
            }
        }
    }
}

