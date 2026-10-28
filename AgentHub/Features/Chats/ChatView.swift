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
    @FocusState private var composerFocused: Bool

    private var conversation: Conversation? { store.conversations.first { $0.id == conversationID } }

    var body: some View {
        if let conversation {
            VStack(spacing: 0) {
                messages(conversation)
                Divider()
                composer(conversation)
            }
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
            if !attachments.isEmpty || attachError != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(attachments) { file in
                            AttachmentChip(file: file) { attachments.removeAll { $0.id == file.id } }
                        }
                        if let attachError {
                            Label(attachError, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button { importing = true } label: {
                    Image(systemName: "paperclip").font(.system(size: 18))
                }
                .buttonStyle(.borderless)
                .padding(.bottom, 8)
                .help("Attach files (or drag them into the chat)")
                TextField("Message · @alias to pick a model · /skill · drop files here", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 18))
                    .onKeyPress(.return, phases: .down) { press in
                        // Shift/Option+Enter: new line. Enter: send.
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                            draft += "\n"
                            return .handled
                        }
                        submit(conversation)
                        return .handled
                    }
                Button { submit(conversation) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSend(conversation))
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func canSend(_ conversation: Conversation) -> Bool {
        ChatComposer.canSend(draft: draft, attachments: attachments) && !store.isStreaming(conversation.id)
    }

    private func submit(_ conversation: Conversation) {
        guard canSend(conversation) else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        draft = ""
        attachments = []
        attachError = nil
        store.send(text, attachments: files, in: conversation.id)
    }

    private func addFiles(_ urls: [URL]) {
        let result = ChatComposer.add(urls, to: attachments)
        attachments = result.attachments
        attachError = result.error
        composerFocused = true
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
            .opacity(message.content.isEmpty && message.role == .user ? 0 : 1)
            .frame(height: message.content.isEmpty && message.role == .user ? 0 : nil)

            if let files = message.attachments, !files.isEmpty {
                HStack(spacing: 6) {
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
