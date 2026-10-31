import Foundation
import Network
import Observation

/// Single source of truth for agents, skills, conversations and models.
/// Persists to one JSON file; secrets go to the Keychain.
@MainActor
@Observable
final class AppStore {
    private struct Snapshot: Codable {
        var agents: [Agent]
        var skills: [Skill]
        var conversations: [Conversation]
        var customModels: [AIModel]
        var installedLocalModels: [AIModel]
        var customProviders: [Provider]
        var router: RouterSettings
        // Optional so files saved before servers existed still load.
        var servers: [LocalServer]?
        var serverModels: [AIModel]?
    }

    enum ServerStatus: Equatable {
        case checking
        case online(RunnerClient.System?)
        case offline(String)
    }

    var agents: [Agent] = Agent.starters(skills: Skill.defaults) { didSet { scheduleSave() } }
    var skills: [Skill] = Skill.defaults { didSet { scheduleSave() } }
    var conversations: [Conversation] = [] { didSet { scheduleSave() } }
    var customModels: [AIModel] = [] { didSet { scheduleSave() } }
    var installedLocalModels: [AIModel] = [] { didSet { scheduleSave() } }
    var customProviders: [Provider] = [] { didSet { scheduleSave() } }
    var router = RouterSettings() { didSet { scheduleSave() } }
    var servers: [LocalServer] = [] { didSet { scheduleSave() } }
    /// Last known model list per server; only routed to while the server is online.
    var serverModels: [AIModel] = [] { didSet { scheduleSave() } }
    private(set) var serverStatus: [UUID: ServerStatus] = [:]

    /// Bumped when a Keychain value changes so views re-read connection state.
    private(set) var credentialsVersion = 0
    private(set) var isOnline = true
    private(set) var streamingConversationIDs: Set<UUID> = [] {
        didSet {
            // A reply finished: the next queued message in that chat goes out.
            for id in oldValue.subtracting(streamingConversationIDs) where !(queuedMessages[id] ?? []).isEmpty {
                Task { @MainActor in self.sendNextQueued(id) }
            }
        }
    }
    /// Messages typed while a chat was still answering, sent in order as each reply finishes.
    private(set) var queuedMessages: [UUID: [QueuedMessage]] = [:]
    /// Group chats working "until it's ready": round, disagreements so far, when it started (the progress bar).
    private(set) var discussions: [UUID: DiscussionProgress] = [:]
    @ObservationIgnored private var stopRequests: Set<UUID> = []
    /// Each chat's codebase summary (README, manifests, tree) and when it was read.
    @ObservationIgnored private var codebaseContexts: [UUID: (at: Date, text: String)] = [:]
    var huggingFaceAccount: HuggingFaceClient.Account?

    let localModels = LocalModelManager()

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var isLoading = false

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agentim/agentim.json")
        load()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        pathMonitor.start(queue: DispatchQueue(label: "agenthub.network"))
    }

    // MARK: - Providers & models

    var providers: [Provider] { Provider.builtIn + customProviders }

    func provider(id: String) -> Provider? { providers.first { $0.id == id } }

    func apiKey(for provider: Provider) -> String? {
        _ = credentialsVersion
        return Keychain.get(provider.keychainAccount)
    }

    func setAPIKey(_ key: String?, for provider: Provider) {
        Keychain.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: provider.keychainAccount)
        credentialsVersion += 1
    }

    func isConnected(_ provider: Provider) -> Bool { !(apiKey(for: provider) ?? "").isEmpty }

    /// The HF token doubles as the key for Hugging Face Inference Providers.
    var huggingFaceToken: String? { apiKey(for: .huggingFace) }

    var allModels: [AIModel] { AIModel.cloudCatalog + customModels + installedLocalModels + serverModels }

    /// The chat on screen (notifications skip it while agentim is in front), and one a notification asked to open.
    var visibleConversationID: UUID?
    var requestedConversationID: UUID?

    /// How Claude is used: "tmux" (your Claude login, claude -p in a background terminal) or "api" (an API key).
    var claudeVia: String = UserDefaults.standard.string(forKey: "claudeVia") ?? "tmux" {
        didSet { UserDefaults.standard.set(claudeVia, forKey: "claudeVia") }
    }

    /// How ChatGPT is used: "tmux" (your ChatGPT login, codex exec in a background terminal) or "api" (an API key).
    var chatgptVia: String = UserDefaults.standard.string(forKey: "chatgptVia") ?? "tmux" {
        didSet { UserDefaults.standard.set(chatgptVia, forKey: "chatgptVia") }
    }

    /// What the router may choose from: connected providers + installed local weights.
    var availableModels: [AIModel] {
        allModels.filter { model in
            switch model.location {
            case .cloud(let id) where id == Provider.anthropic.id && claudeVia == "tmux":
                false  // Claude goes through tmux (claude -p), never the API
            case .cloud(let id) where id == Provider.openAI.id && chatgptVia == "tmux":
                false  // ChatGPT goes through tmux (codex exec), never the API
            case .cloud(let id): provider(id: id).map(isConnected) ?? false
            case .local(let repo): LocalModelManager.isInstalled(repo)
            case .server(let id): if case .online? = serverStatus[id] { true } else { false }
            }
        }
    }

    func model(id: String?) -> AIModel? { allModels.first { $0.id == id } }

    func connectHuggingFace(token: String) async throws {
        let account = try await HuggingFaceClient(token: token).whoami()
        setAPIKey(token, for: .huggingFace)
        huggingFaceAccount = account
    }

    func disconnectHuggingFace() {
        setAPIKey(nil, for: .huggingFace)
        huggingFaceAccount = nil
    }

    func refreshHuggingFaceAccount() async {
        guard let token = huggingFaceToken, !token.isEmpty else { return }
        huggingFaceAccount = try? await HuggingFaceClient(token: token).whoami()
    }

    func registerInstalled(repo: String) {
        guard !installedLocalModels.contains(where: { $0.modelName == repo }) else { return }
        let model = AIModel.suggestedLocal.first { $0.modelName == repo }
            ?? .local(repo: repo, display: repo.split(separator: "/").last.map(String.init) ?? repo,
                      caps: [.general, .fast], context: 32_768, quality: 2)
        installedLocalModels.append(model)
    }

    func deleteLocal(_ model: AIModel) {
        localModels.delete(model.modelName)
        installedLocalModels.removeAll { $0.id == model.id }
        Task { await LocalModelCache.shared.unload() }
    }

    // MARK: - Local servers

    func serverToken(_ server: LocalServer) -> String? {
        _ = credentialsVersion
        return Keychain.get(server.keychainAccount)
    }

    func saveServer(_ server: LocalServer, token: String) {
        Keychain.set(token.trimmingCharacters(in: .whitespacesAndNewlines), for: server.keychainAccount)
        credentialsVersion += 1
        if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i] = server } else { servers.append(server) }
        Task { await refresh(server) }
    }

    func removeServer(_ server: LocalServer) {
        Keychain.set(nil, for: server.keychainAccount)
        servers.removeAll { $0.id == server.id }
        serverModels.removeAll { $0.serverID == server.id }
        serverStatus[server.id] = nil
    }

    func runnerClient(_ server: LocalServer) -> RunnerClient {
        RunnerClient(server: server, token: serverToken(server))
    }

    func refreshServers() async {
        await withTaskGroup(of: Void.self) { group in
            for server in servers { group.addTask { await self.refresh(server) } }
        }
    }

    /// Re-reads a server's health, memory and models.
    func refresh(_ server: LocalServer) async {
        serverStatus[server.id] = .checking
        let client = runnerClient(server)
        do {
            let system = server.kind == .runner ? try await client.system() : nil
            let models = try await client.models().map { AIModel.server($0, on: server) }
            serverModels = serverModels.filter { $0.serverID != server.id } + models
            serverStatus[server.id] = .online(system)
        } catch {
            serverStatus[server.id] = .offline(error.localizedDescription)
        }
    }

    func models(on server: LocalServer) -> [AIModel] { serverModels.filter { $0.serverID == server.id } }

    func markOnline(_ id: UUID, system: RunnerClient.System?) { serverStatus[id] = .online(system) }

    func deleteServerModel(_ model: AIModel) async throws {
        guard let server = servers.first(where: { $0.id == model.serverID }) else { return }
        try await runnerClient(server).delete(model.modelName)
        await refresh(server)
    }

    // MARK: - Conversations

    @discardableResult
    func newConversation(agent: Agent) -> Conversation {
        var conversation = Conversation(title: "New chat", agentID: agent.id)
        conversation.lastReadAt = Date()
        conversations.insert(conversation, at: 0)
        return conversation
    }

    func agent(for conversation: Conversation) -> Agent? { agents.first { $0.id == conversation.agentID } }

    // MARK: - Meeting rooms

    /// Someone in a group chat: an agent, or a skill taking part as its own member.
    struct Member: Identifiable, Hashable {
        let id: UUID
        let name: String
        let emoji: String
        var agent: Agent?
        var skill: Skill?

        /// What @mentions match: the first word of the name, the hyphenated name, and a skill's slug.
        var mentionKeys: Set<String> {
            let words = name.lowercased().split(separator: " ").map(String.init)
            var keys: Set<String> = [words.first ?? "", words.joined(separator: "-")]
            if let skill { keys.insert(skill.slug) }
            return keys
        }

        /// The name to type after @ (and to Tab-complete).
        var mention: String { skill?.slug ?? (name.split(separator: " ").first.map(String.init) ?? name) }
    }

    /// A group chat with agents and/or skills; each answers in turn (or only the ones you @mention).
    @discardableResult
    func newMeeting(with participants: [Agent], skills: [Skill] = []) -> Conversation {
        var conversation = Conversation(title: "Group chat", agentID: participants.first?.id ?? agents.first?.id ?? UUID())
        conversation.lastReadAt = Date()
        conversation.participantIDs = participants.map(\.id)
        conversation.participantSkillIDs = skills.map(\.id)
        // Give them a task and they keep working until it's ready and they all agree (within the limits in Settings).
        conversation.discussionRounds = Self.maxRounds
        let names = participants.map(\.name) + skills.map(\.name)
        if !names.isEmpty {
            conversation.title = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
        }
        conversations.insert(conversation, at: 0)
        return conversation
    }

    /// Everyone in the group chat: its agents, then its skills.
    func members(in conversation: Conversation) -> [Member] {
        participants(in: conversation).map { Member(id: $0.id, name: $0.name, emoji: $0.emoji, agent: $0) }
            + (conversation.participantSkillIDs ?? []).compactMap { id in
                skills.first { $0.id == id }.map { Member(id: $0.id, name: $0.name, emoji: "🪄", skill: $0) }
            }
    }

    /// Adds the member to the group chat, or removes them if they're in it.
    func toggle(_ member: Member, in conversationID: UUID) {
        if member.skill != nil { toggle(skill: member.id, in: conversationID) } else { toggle(agent: member.id, in: conversationID) }
    }

    func toggle(agent id: UUID, in conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let ids = conversation.participantIDs ?? []
        setParticipants(ids.contains(id) ? ids.filter { $0 != id } : ids + [id], in: conversationID)
        retitle(conversationID)
    }

    func toggle(skill id: UUID, in conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let ids = conversation.participantSkillIDs ?? []
        setSkillParticipants(ids.contains(id) ? ids.filter { $0 != id } : ids + [id], in: conversationID)
        retitle(conversationID)
    }

    /// Before the first message, the group's title follows who's in it.
    private func retitle(_ conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }), conversations[i].messages.isEmpty else { return }
        let names = members(in: conversations[i]).map(\.name)
        conversations[i].title = names.isEmpty ? "Group chat"
            : names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")
    }

    func rename(_ conversationID: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].title = String(title.prefix(120))
    }

    func clearMessages(_ conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }), !isStreaming(conversationID) else { return }
        removeImages(of: conversations[i].messages)
        conversations[i].messages = []
    }

    func deleteConversation(_ conversationID: UUID) {
        removeImages(of: conversations.first { $0.id == conversationID }?.messages ?? [])
        queuedMessages[conversationID] = nil
        conversations.removeAll { $0.id == conversationID }
    }

    /// The saved copies of a chat's images go with the chat.
    private func removeImages(of messages: [ChatMessage]) {
        for url in messages.flatMap(\.images).compactMap(\.imageURL) { try? FileManager.default.removeItem(at: url) }
    }

    /// Talk to another agent in the same chat (the history stays).
    func switchAgent(_ conversationID: UUID, to agentID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].agentID = agentID
    }

    /// The chat as Markdown (for Copy and Export).
    func markdown(_ conversation: Conversation) -> String {
        let lines = conversation.messages.filter { !$0.content.isEmpty }.map { message -> String in
            let who = message.role == .user ? "You" : speaker(of: message)?.name ?? agent(for: conversation)?.name ?? "Assistant"
            return "**\(who)** · \(message.createdAt.formatted(date: .abbreviated, time: .shortened))\n\n\(message.content)"
        }
        return "# \(conversation.title)\n\n" + lines.joined(separator: "\n\n---\n\n") + "\n"
    }

    /// You've seen this chat (clears the unread dot).
    func markRead(_ conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }), conversations[i].isUnread else { return }
        conversations[i].lastReadAt = max(Date(), conversations[i].messages.last?.createdAt ?? .distantPast)
    }

    /// Asks again: drops the last exchange and resends your last message (direct chats).
    func retryLast(in conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }), !isStreaming(conversationID),
              let lastUser = conversations[i].messages.lastIndex(where: { $0.role == .user }) else { return }
        let message = conversations[i].messages[lastUser]
        conversations[i].messages.removeSubrange(lastUser...)
        if conversations[i].isMeeting {
            sendToMeeting(message.content, attachments: message.attachments ?? [], in: conversationID)
        } else {
            send(message.content, attachments: message.attachments ?? [], in: conversationID)
        }
    }

    func setSkillParticipants(_ ids: [UUID], in conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].participantSkillIDs = ids
    }

    /// The members a message is for: the ones @mentioned, else everyone.
    nonisolated static func addressed(_ text: String, among members: [Member]) -> [Member] {
        let mentions = Set(text.matches(of: /@([\w-]+)/).map { $0.1.lowercased() })
        guard !mentions.isEmpty else { return members }
        let picked = members.filter { !$0.mentionKeys.isDisjoint(with: mentions) }
        return picked.isEmpty ? members : picked
    }

    /// Who wrote a message in a group chat (an agent or a skill).
    func speaker(of message: ChatMessage) -> Member? {
        if let id = message.skillID, let skill = skills.first(where: { $0.id == id }) {
            return Member(id: skill.id, name: skill.name, emoji: "🪄", skill: skill)
        }
        if let id = message.agentID, let agent = agents.first(where: { $0.id == id }) {
            return Member(id: agent.id, name: agent.name, emoji: agent.emoji, agent: agent)
        }
        return nil
    }

    func participants(in conversation: Conversation) -> [Agent] {
        (conversation.participantIDs ?? []).compactMap { id in agents.first { $0.id == id } }
    }

    func setParticipants(_ ids: [UUID], in conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].participantIDs = ids
    }

    /// The agents a message is for: the ones @mentioned by name (first word, case-insensitive), else everyone.
    nonisolated static func addressed(_ text: String, among agents: [Agent]) -> [Agent] {
        let mentions = Set(text.matches(of: /@([\w-]+)/).map { $0.1.lowercased() })
        guard !mentions.isEmpty else { return agents }
        let picked = agents.filter { agent in
            let words = agent.name.lowercased().split(separator: " ").map(String.init)
            return mentions.contains(words.first ?? "") || mentions.contains(words.joined(separator: "-"))
        }
        return picked.isEmpty ? agents : picked
    }

    /// Images from your last few messages in a chat (what a group member that can see should look at).
    func recentImages(_ conversationID: UUID) -> [ChatAttachment] {
        let messages = conversations.first { $0.id == conversationID }?.messages ?? []
        return Array(messages.filter { $0.role == .user && !$0.images.isEmpty }.suffix(ChatRequest.imageMessages).flatMap(\.images))
    }

    /// The meeting so far as a transcript, with the person each line is from.
    func transcript(_ conversation: Conversation, limit: Int = 16) -> String {
        conversation.messages.suffix(limit).filter { !$0.isError && !$0.content.isEmpty }.map { message in
            let who = message.role == .user ? "You" : speaker(of: message)?.name ?? "Assistant"
            return "\(who): \(message.modelContent)"
        }.joined(separator: "\n\n")
    }

    /// Posts the message, then the addressed members answer in turn; with more discussion rounds they keep talking to
    /// each other (each seeing everything before it). "Until it's ready" keeps going until everyone agrees, up to the
    /// disagreement and time limits from Settings, then the lead member writes the finished result.
    func sendToMeeting(_ text: String, attachments: [ChatAttachment] = [], in conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].messages.append(ChatMessage(role: .user, content: text, attachments: attachments.nilIfEmpty))
        let everyone = members(in: conversations[index])
        let speakers = Self.addressed(text, among: everyone)
        let rounds = max(1, min(conversations[index].discussionRounds ?? 1, Self.maxRounds))
        let untilReady = rounds >= Self.maxRounds
        let limits = (disagreements: Self.maxDisagreements, minutes: Self.maxDiscussionMinutes)
        let started = Date()
        let deadline = started.addingTimeInterval(TimeInterval(limits.minutes * 60))
        streamingConversationIDs.insert(conversationID)
        stopRequests.remove(conversationID)
        if untilReady {
            discussions[conversationID] = DiscussionProgress(round: 1, disagreements: 0, started: started,
                                                             maxDisagreements: limits.disagreements, maxMinutes: limits.minutes)
        }
        Task {
            defer {
                streamingConversationIDs.remove(conversationID)
                discussions[conversationID] = nil
                stopRequests.remove(conversationID)
            }
            var outcome = DiscussionOutcome.roundsDone
            var round = 0, disagreements = 0
            discussion: while true {
                round += 1
                discussions[conversationID]?.round = round
                var spoke = false, answered = false
                for member in speakers {
                    if stopRequests.contains(conversationID) { outcome = .stopped; break discussion }
                    if untilReady, round > 1, Date() >= deadline { outcome = .timeLimit; break discussion }
                    let turn = await meetingReply(from: member, others: everyone.filter { $0.id != member.id },
                                                  in: conversationID, round: round, untilReady: untilReady)
                    spoke = spoke || turn == .spoke
                    answered = answered || turn != .failed
                }
                if !answered { outcome = .failed; break }               // nobody could answer: don't spin for hours
                if round > 1 && !spoke { outcome = .agreed; break }     // everyone agrees: it's ready
                if !untilReady {
                    if round >= rounds { break }
                    continue
                }
                if round > 1 {
                    disagreements += 1
                    discussions[conversationID]?.disagreements = disagreements
                }
                if disagreements >= limits.disagreements { outcome = .disagreementLimit; break }
                if Date() >= deadline { outcome = .timeLimit; break }
            }
            if untilReady {
                await finishDiscussion(conversationID, outcome: outcome, lead: speakers.first, everyone: everyone,
                                       rounds: round, disagreements: disagreements, limits: limits)
            }
            await discussionEnded(conversationID)  // a notification with the summary (or the question for you)
        }
    }

    static let maxRounds = 5

    // MARK: - Until it's ready: limits, progress, stop

    nonisolated static let defaultMaxDisagreements = 20
    nonisolated static let defaultMaxDiscussionMinutes = 240

    /// Settings → Group chats: how many disagreements (rounds where someone still pushes back) before they stop.
    nonisolated static var maxDisagreements: Int {
        let value = UserDefaults.standard.integer(forKey: "discussionMaxDisagreements")
        return value > 0 ? min(value, 500) : defaultMaxDisagreements
    }

    /// Settings → Group chats: how long a discussion may run, in minutes.
    nonisolated static var maxDiscussionMinutes: Int {
        let value = UserDefaults.standard.integer(forKey: "discussionMaxMinutes")
        return value > 0 ? min(value, 24 * 60) : defaultMaxDiscussionMinutes
    }

    struct DiscussionProgress: Equatable {
        var round: Int
        var disagreements: Int
        var started: Date
        var maxDisagreements: Int
        var maxMinutes: Int
    }

    enum DiscussionOutcome: Equatable { case roundsDone, agreed, disagreementLimit, timeLimit, stopped, failed }
    enum Turn: Equatable { case spoke, passed, failed }

    /// Stops a running discussion after the current member's turn.
    func stopDiscussion(_ conversationID: UUID) {
        stopRequests.insert(conversationID)
    }

    /// The end of an "until it's ready" discussion: a note on why it stopped, then the lead member writes the
    /// finished result (agreed), or the best version so far with what's still open (a limit, or you stopped it).
    private func finishDiscussion(_ conversationID: UUID, outcome: DiscussionOutcome, lead: Member?, everyone: [Member],
                                  rounds: Int, disagreements: Int, limits: (disagreements: Int, minutes: Int)) async {
        let note: String
        switch outcome {
        case .agreed: note = "Everyone agreed after \(rounds) round\(rounds == 1 ? "" : "s") and \(disagreements) disagreement\(disagreements == 1 ? "" : "s")."
        case .disagreementLimit: note = "Stopped at the limit of \(limits.disagreements) disagreements without full agreement."
        case .timeLimit: note = "Stopped at the time limit (\(Self.duration(minutes: limits.minutes))) without full agreement."
        case .stopped: note = "You stopped the discussion after \(rounds) round\(rounds == 1 ? "" : "s")."
        case .failed: note = "The discussion stopped: no member could answer (are the models running?)."
        case .roundsDone: return
        }
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[c].messages.append(ChatMessage(role: .assistant, content: note, routingReason: "Discussion"))
        guard outcome != .failed, let lead else { return }
        _ = await meetingReply(from: lead, others: everyone.filter { $0.id != lead.id }, in: conversationID,
                               round: rounds + 1, untilReady: true, final: outcome == .agreed ? .agreed : .unresolved)
    }

    nonisolated static func duration(minutes: Int) -> String {
        minutes % 60 == 0 ? "\(minutes / 60) h" : minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// The model a member thinks with in this group: the one set for them, else (auto-divide) a different available
    /// model per member, else nil (the router picks).
    func model(for member: Member, in conversation: Conversation) -> AIModel? {
        if let id = conversation.memberModels?[member.id], let model = availableModels.first(where: { $0.id == id }) {
            return model
        }
        guard conversation.autoDivideModels == true else { return nil }
        let chat = availableModels.filter { !$0.isExplicitOnly }
            .sorted { ($0.qualityTier, $1.displayName) > ($1.qualityTier, $0.displayName) }
        guard !chat.isEmpty, let index = members(in: conversation).firstIndex(where: { $0.id == member.id }) else { return nil }
        return chat[index % chat.count]
    }

    func setMemberModel(_ modelID: String?, for memberID: UUID, in conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        var models = conversations[i].memberModels ?? [:]
        models[memberID] = modelID
        conversations[i].memberModels = models
    }

    func setAutoDivide(_ on: Bool, in conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].autoDivideModels = on
    }

    func setDiscussionRounds(_ rounds: Int, in conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].discussionRounds = max(1, min(rounds, Self.maxRounds))
    }

    /// A quick persona for group chats: a name and who they are, saved as an agent.
    @discardableResult
    func newPersona(name: String, description: String, in conversationID: UUID? = nil) -> Agent? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !description.isEmpty else { return nil }
        let agent = Agent(name: name, emoji: "🎭", summary: String(description.prefix(120)),
                          systemPrompt: "You are \(name). \(description)\nStay in character: your views, your voice, your way of writing.")
        agents.append(agent)
        if let conversationID { toggle(agent: agent.id, in: conversationID) }
        return agent
    }

    nonisolated static func isPass(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "*_.!"))
        return t.uppercased() == "PASS" || t.uppercased().hasPrefix("PASS ") || t.uppercased().hasPrefix("PASS:")
    }

    enum FinalTurn { case agreed, unresolved }

    /// One member's turn: they spoke, passed (agree, nothing to add: their empty turn is removed) or couldn't answer.
    @discardableResult
    private func meetingReply(from member: Member, others: [Member], in conversationID: UUID, round: Int = 1,
                              untilReady: Bool = false, final: FinalTurn? = nil) async -> Turn {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return .failed }
        let names = others.map(\.name).joined(separator: ", ")
        let turn: String
        switch final {
        case .agreed?:
            turn = """
            Everyone agreed. As \(member.name), write the FINISHED result the user asked for: the complete deliverable \
            itself (not a summary of the discussion), with every point the group agreed on. Start with "\(member.name):".
            """
        case .unresolved?:
            turn = """
            The discussion has to stop now. As \(member.name), write the best complete version of what the user asked for \
            so far, then list what's still disputed and who disagrees, in one short section. Start with "\(member.name):".
            """
        case nil where round == 1:
            turn = """
            Reply now as \(member.name), from your own expertise. Build on (or push back on) what others said, address them \
            by name when you do, don't repeat their points, and keep it under 180 words. Start with "\(member.name):".
            """
        case nil where untilReady:
            turn = """
            The work continues (round \(round)). Reply as \(member.name): improve the draft, fix what's missing or wrong, and \
            push back where you disagree, addressing the others by name. Keep going until the result is finished and ready \
            for the user. Under 150 words, start with "\(member.name):". Reply with exactly PASS only when the result is \
            ready and you fully agree with it.
            """
        case nil:
            turn = """
            The discussion continues (round \(round)). Reply as \(member.name) to what the others just said: build on it, \
            push back, or improve the draft, addressing them by name. Work toward what the user asked for. Under 150 words, \
            start with "\(member.name):". If you have nothing new to add and agree with where it landed, reply with exactly PASS.
            """
        }
        let ask = """
        You're in a group chat with the user\(names.isEmpty ? "" : " and \(names)").\(briefText(conversation).map { "\n\n\($0)" } ?? "")

        Here's the conversation so far:

        \(transcript(conversation))

        \(turn)
        """
        let agent = member.agent
        let reply = ChatMessage(role: .assistant, content: "", agentID: member.agent?.id, skillID: member.skill?.id)
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }) else { return .failed }
        conversations[c].messages.append(reply)
        do {
            let decision = try ModelRouter(available: availableModels, settings: router).route(
                RoutingRequest(text: ask, history: [], agent: agent, conversationPin: conversation.pinnedModelID, isOnline: isOnline))
            // The member's own model first (set for them, or divided automatically), then the router's picks.
            let own = model(for: member, in: conversation)
            let ranked = (own.map { [$0] } ?? []) + [decision.model] + decision.fallbacks
            var seen = Set<String>()
            let ordered = ranked.filter { seen.insert($0.id).inserted }
            let targets = ordered.prefix(2).compactMap { model in client(for: model).map { (model, $0) } }
            guard !targets.isEmpty else { throw RoutingError.noModelsAvailable }
            let system = member.skill.map { "You are the \($0.name) specialist in this group chat.\n\n## Skill: \($0.name)\n\($0.instructions)" }
                ?? systemPrompt(agent: agent, message: ask)
            for (model, client) in targets {
                updateReply(reply.id, in: conversationID) {
                    $0.content = ""
                    $0.modelID = model.id
                    $0.routingReason = "\(member.name) in the group chat"
                        + (final != nil ? " · final result" : round > 1 ? " · round \(round)" : "")
                }
                do {
                    // Members whose model can see get the images you shared lately along with the transcript.
                    let images = model.canSeeImages ? recentImages(conversationID) : []
                    let request = ChatRequest(model: model.modelName, system: system,
                                              messages: [ChatMessage(role: .user, content: ask, attachments: images.nilIfEmpty)],
                                              sendImages: !images.isEmpty)
                    for try await chunk in client.stream(request) {
                        updateReply(reply.id, in: conversationID) { $0.content += chunk }
                    }
                    // Small models often echo "Name:"; the bubble already shows who's talking.
                    updateReply(reply.id, in: conversationID) {
                        $0.content = Self.withoutSpeakerPrefix($0.content, name: member.name)
                    }
                    if round > 1, final == nil, Self.isPass(message(reply.id, in: conversationID)?.content ?? "") {
                        removeMessage(reply.id, in: conversationID)  // nothing to add: no empty bubble
                        return .passed
                    }
                    return .spoke
                } catch {
                    if let content = message(reply.id, in: conversationID)?.content, !content.isEmpty { return .spoke }
                }
            }
            throw RoutingError.noModelsAvailable
        } catch {
            updateReply(reply.id, in: conversationID) {
                $0.isError = true
                $0.content = "\(member.name) couldn't answer: \(error.localizedDescription)"
            }
        }
        return .failed
    }

    private func removeMessage(_ id: UUID, in conversationID: UUID) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[c].messages.removeAll { $0.id == id }
    }

    nonisolated static func withoutSpeakerPrefix(_ text: String, name: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["**\(name):**", "**\(name)**:", "\(name):"] where trimmed.hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    func isStreaming(_ id: UUID) -> Bool { streamingConversationIDs.contains(id) }

    // MARK: - Codebase: a folder or GitHub repo per chat; Claude Code builds in it, results and pull requests show as cards

    func setCodebase(_ codebase: Codebase?, in conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[i].codebase = codebase
        codebaseContexts[conversationID] = nil
    }

    /// The system prompt plus what agents should know about the chat's codebase (cached for 10 minutes).
    func withCodebase(_ system: String, conversationID: UUID) async -> String {
        guard let codebase = conversations.first(where: { $0.id == conversationID })?.codebase, let runner = macRunner else { return system }
        var context = codebaseContexts[conversationID].flatMap { Date().timeIntervalSince($0.at) < 600 ? $0.text : nil }
        if context == nil {
            context = try? await runnerClient(runner).projectContext(codebase.source)
            if let context { codebaseContexts[conversationID] = (Date(), context) }
        }
        guard let context, !context.isEmpty else { return system }
        let note = """
        ## Codebase: \(codebase.name)
        This chat works on this codebase. Refer to its real files and structure. To change code, describe the plan; \
        the user can press "Build it" to have Claude Code make the changes.

        \(context)
        """
        return system.isEmpty ? note : system + "\n\n" + note
    }

    /// What Claude Code is asked to build: your last request, and the agent's plan if it answered one.
    func buildRequest(in conversationID: UUID) -> String? {
        guard let messages = conversations.first(where: { $0.id == conversationID })?.messages,
              let ask = messages.last(where: { $0.role == .user && !$0.content.isEmpty }) else { return nil }
        let plan = messages.last { $0.role == .assistant && !$0.isError && $0.work == nil && !$0.content.isEmpty && $0.createdAt >= ask.createdAt }
        return ask.content + (plan.map { "\n\nThe plan agreed in the chat:\n\($0.content)" } ?? "")
    }

    /// Claude Code edits the chat's codebase (you confirmed "Build it"); the result shows as a card.
    func buildIt(in conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }), let codebase = conversation.codebase,
              let request = buildRequest(in: conversationID), !isStreaming(conversationID),
              let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        guard let runner = macRunner else {
            conversations[index].messages.append(ChatMessage(role: .assistant, content: "Building needs this Mac's runner. Open This Mac and connect it.", isError: true))
            return
        }
        let ask = conversation.messages.last { $0.role == .user }?.content ?? request
        var work = WorkResult(state: .running, agentName: "Claude Code", request: String(ask.prefix(300)))
        let message = ChatMessage(role: .assistant, content: work.summary, routingReason: "Claude Code in \(codebase.name)", work: work)
        conversations[index].messages.append(message)
        streamingConversationIDs.insert(conversationID)
        Task {
            defer { streamingConversationIDs.remove(conversationID) }
            do {
                let result = try await runnerClient(runner).projectTask(codebase.source, prompt: request, edit: true)
                work.state = .done
                work.folder = result.folder
                work.repo = result.repo
                work.branch = result.branch
                work.files = result.files ?? []
                work.output = result.output
            } catch {
                work.state = .failed
                work.error = error.localizedDescription
            }
            updateWork(message.id, in: conversationID, work)
            replyFinished(conversationID, replyID: message.id)
        }
    }

    /// Opens a pull request with what Claude Code changed (you confirmed it): branch, commit, push, gh pr create.
    func openPullRequest(messageID: UUID, in conversationID: UUID) {
        guard let conversation = conversations.first(where: { $0.id == conversationID }), let codebase = conversation.codebase,
              var work = conversation.messages.first(where: { $0.id == messageID })?.work, let runner = macRunner else { return }
        work.state = .openingPullRequest
        work.error = nil
        updateWork(messageID, in: conversationID, work)
        let title = Self.pullRequestTitle(work.request)
        let body = "\(work.request)\n\n" + work.files.prefix(30).map { "- `\($0.path)` (+\($0.added ?? 0) −\($0.removed ?? 0))" }.joined(separator: "\n")
        Task {
            do {
                let pr = try await runnerClient(runner).pullRequest(codebase.source, title: title, body: body)
                work.pullRequestURL = pr.url
                work.pullRequestNumber = pr.number
                work.repo = pr.repo
                work.branch = pr.branch
                work.base = pr.base
                if !pr.files.isEmpty { work.files = pr.files }
            } catch {
                work.error = error.localizedDescription
            }
            work.state = .done
            updateWork(messageID, in: conversationID, work)
        }
    }

    /// The first line of the request, short enough for a pull request title.
    nonisolated static func pullRequestTitle(_ request: String) -> String {
        let line = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Changes from agentim"
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 72 ? String(trimmed.prefix(71)).trimmingCharacters(in: .whitespaces) + "…" : trimmed
    }

    private func updateWork(_ messageID: UUID, in conversationID: UUID, _ work: WorkResult) {
        updateReply(messageID, in: conversationID) {
            $0.work = work
            $0.content = work.summary
            $0.isError = false
        }
    }

    // MARK: - Queue

    /// Sends now, or queues the message when the chat is still answering (or has others waiting).
    func submit(_ text: String, attachments: [ChatAttachment] = [], in conversationID: UUID) {
        if isStreaming(conversationID) || !(queuedMessages[conversationID] ?? []).isEmpty {
            queuedMessages[conversationID, default: []].append(QueuedMessage(text: text, attachments: attachments))
        } else {
            dispatch(text, attachments: attachments, in: conversationID)
        }
    }

    func removeQueued(_ id: UUID, in conversationID: UUID) {
        queuedMessages[conversationID]?.removeAll { $0.id == id }
    }

    /// Takes a queued message back into the composer to change it.
    func takeQueued(_ id: UUID, in conversationID: UUID) -> QueuedMessage? {
        guard let message = queuedMessages[conversationID]?.first(where: { $0.id == id }) else { return nil }
        removeQueued(id, in: conversationID)
        return message
    }

    func sendNextQueued(_ conversationID: UUID) {
        guard !isStreaming(conversationID), var queue = queuedMessages[conversationID], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        queuedMessages[conversationID] = queue.isEmpty ? nil : queue
        guard conversations.contains(where: { $0.id == conversationID }) else { return }
        dispatch(next.text, attachments: next.attachments, in: conversationID)
    }

    private func dispatch(_ text: String, attachments: [ChatAttachment], in conversationID: UUID) {
        if conversations.first(where: { $0.id == conversationID })?.isMeeting == true {
            sendToMeeting(text, attachments: attachments, in: conversationID)
        } else {
            send(text, attachments: attachments, in: conversationID)
        }
    }

    /// Router preview for the composer ("will go to …").
    func previewRoute(_ text: String, in conversation: Conversation) -> Result<RoutingDecision, Error> {
        if case .remote = agent(for: conversation)?.kind { return .failure(RoutingError.noModelsAvailable) }
        return Result {
            try ModelRouter(available: availableModels, settings: router).route(
                RoutingRequest(text: text, history: conversation.messages, agent: agent(for: conversation),
                               conversationPin: conversation.pinnedModelID, isOnline: isOnline))
        }
    }

    /// True when at least one chat model (or a local coding agent) can answer.
    var hasChatModel: Bool { availableModels.contains { !$0.isExplicitOnly || $0.capabilities.contains(.agent) } }

    func send(_ text: String, attachments: [ChatAttachment] = [], in conversationID: UUID, rechecked: Bool = false) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        let conversation = conversations[index]
        let agent = agent(for: conversation)

        let targets: [(client: ChatClient, model: String, modelID: String?, reason: String, images: Bool)]
        let prompt: String

        if let agent, case .remote(let endpoint, let model) = agent.kind {
            let client = OpenAICompatibleClient(
                baseURL: endpoint, apiKey: Keychain.get(agent.keychainAccount), isFullEndpoint: true)
            targets = [(client, model, nil, "Remote agent \(agent.name)", false)]
            prompt = text
        } else {
            do {
                let decision = try ModelRouter(available: availableModels, settings: router).route(
                    RoutingRequest(text: text, history: conversation.messages, agent: agent,
                                   conversationPin: conversation.pinnedModelID, isOnline: isOnline))
                var ranked = [decision.model] + decision.fallbacks
                var reasons = [decision.model.id: decision.reason]
                // Images attached: a model that can see them goes first, unless you picked the model yourself.
                let picked = ModelRouter.extractOverride(text).alias != nil || conversation.pinnedModelID != nil
                    || agent.map { $0.modelPreference != .auto } ?? false
                if attachments.contains(where: { $0.imageFile != nil }), !picked, !decision.model.canSeeImages,
                   let seer = imageModel(among: ranked + availableModels.sorted { $0.qualityTier > $1.qualityTier }) {
                    ranked.removeAll { $0.id == seer.id }
                    ranked.insert(seer, at: 0)
                    reasons[seer.id] = "Can see your images"
                }
                targets = ranked.prefix(3).compactMap { model in
                    client(for: model).map {
                        ($0, model.modelName, model.id, reasons[model.id] ?? "Fallback after error", model.canSeeImages)
                    }
                }
                prompt = decision.cleanedText
            } catch RoutingError.noModelsAvailable where !rechecked {
                // The models may still be starting: check the servers again, then try once more.
                Task {
                    await refreshServers()
                    send(text, attachments: attachments, in: conversationID, rechecked: true)
                }
                return
            } catch {
                conversations[index].messages.append(ChatMessage(role: .user, content: text, attachments: attachments.nilIfEmpty))
                conversations[index].messages.append(
                    ChatMessage(role: .assistant, content: error.localizedDescription, isError: true))
                return
            }
        }

        let system = systemPrompt(agent: agent, message: prompt)
        conversations[index].messages.append(ChatMessage(role: .user, content: prompt, attachments: attachments.nilIfEmpty))
        if conversations[index].messages.filter({ $0.role == .user }).count == 1 {
            conversations[index].title = String((prompt.isEmpty ? attachments.first?.name ?? "Files" : prompt).prefix(48))
        }
        let history = conversations[index].messages
        let reply = ChatMessage(role: .assistant, content: "", modelID: targets.first?.modelID,
                                routingReason: targets.first?.reason)
        conversations[index].messages.append(reply)
        streamingConversationIDs.insert(conversationID)

        Task {
            defer { streamingConversationIDs.remove(conversationID) }
            // A chat with a codebase: agents know its README, manifests and file tree.
            let fullSystem = await withCodebase(system, conversationID: conversationID)
            var lastError: Error?
            for target in targets {
                updateReply(reply.id, in: conversationID) {
                    $0.content = ""
                    $0.modelID = target.modelID
                    $0.routingReason = target.reason
                    $0.isError = false
                }
                do {
                    let request = ChatRequest(model: target.model, system: fullSystem, messages: history, sendImages: target.images)
                    for try await chunk in target.client.stream(request) {
                        updateReply(reply.id, in: conversationID) { $0.content += chunk }
                    }
                    replyFinished(conversationID, replyID: reply.id)  // notify if you're elsewhere
                    return
                } catch {
                    lastError = error
                    // Keep partial output instead of retrying a half-finished answer.
                    if let content = message(reply.id, in: conversationID)?.content, !content.isEmpty { break }
                }
            }
            updateReply(reply.id, in: conversationID) {
                $0.isError = true
                $0.content += ($0.content.isEmpty ? "" : "\n\n") + (lastError?.localizedDescription ?? "No model answered.")
            }
        }
    }

    /// Agent instructions + every attached skill that is always-on or matched by the message.
    func systemPrompt(agent: Agent?, message: String) -> String {
        var parts: [String] = []
        if let agent, !agent.systemPrompt.isEmpty { parts.append(agent.systemPrompt) }
        let active = activeSkills(agent: agent, message: message)
        for skill in active {
            parts.append("## Skill: \(skill.name)\n\(skill.instructions)")
        }
        // Designers show their work: an HTML mockup in the reply renders as a live preview in the chat.
        let attached = skills.filter { agent?.skillIDs.contains($0.id) ?? false }
        if (attached + active).contains(where: { $0.name.lowercased().contains("design") }) {
            parts.append(DesignPreview.instruction)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Slash commands work for any skill; trigger words only for skills attached to the agent.
    func activeSkills(agent: Agent?, message: String) -> [Skill] {
        let attached = skills.filter { agent?.skillIDs.contains($0.id) ?? false }
        return skills.filter { skill in
            message.lowercased().contains("/\(skill.slug)")
                || (attached.contains(skill) && (skill.alwaysOn || skill.matches(message)))
        }
    }

    /// The first model that can see images and that agentim can reach (for messages with images).
    func imageModel(among models: [AIModel]) -> AIModel? {
        models.first { $0.canSeeImages && client(for: $0) != nil }
    }

    /// Tests: answer with a stand-in instead of a real model.
    @ObservationIgnored var clientOverride: ((AIModel) -> ChatClient?)?

    func client(for model: AIModel) -> ChatClient? {
        if let clientOverride { return clientOverride(model) }
        switch model.location {
        case .local(let repo):
            return MLXChatClient(repo: repo)
        case .server(let id):
            guard let server = servers.first(where: { $0.id == id }) else { return nil }
            return OpenAICompatibleClient(baseURL: server.openAIBaseURL, apiKey: serverToken(server))
        case .cloud(let providerID):
            guard let provider = provider(id: providerID), let key = apiKey(for: provider) else { return nil }
            switch provider.wire {
            case .anthropic: return AnthropicClient(baseURL: provider.baseURL, apiKey: key)
            case .openAICompatible: return OpenAICompatibleClient(baseURL: provider.baseURL, apiKey: key)
            }
        }
    }

    private func message(_ id: UUID, in conversationID: UUID) -> ChatMessage? {
        conversations.first { $0.id == conversationID }?.messages.first { $0.id == id }
    }

    private func updateReply(_ id: UUID, in conversationID: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == id })
        else { return }
        change(&conversations[c].messages[m])
        conversations[c].updatedAt = Date()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        isLoading = true
        agents = snapshot.agents
        skills = snapshot.skills
        // Chats saved before unread tracking start out read (no wall of dots after an update).
        conversations = snapshot.conversations.map { conversation in
            var conversation = conversation
            if conversation.lastReadAt == nil { conversation.lastReadAt = Date() }
            return conversation
        }
        customModels = snapshot.customModels
        // Drop entries whose weights were removed (e.g. storage cleanup).
        installedLocalModels = snapshot.installedLocalModels.filter { LocalModelManager.isInstalled($0.modelName) }
        customProviders = snapshot.customProviders
        router = snapshot.router
        servers = snapshot.servers ?? []
        serverModels = snapshot.serverModels ?? []
        let before = (agents.map(\.name), skills.map(\.slug))
        addNewBuiltIns()
        isLoading = false
        // New or retired built-ins changed the lists while loading (when saves are off): save them now.
        // Saved right away: the "seen" list is already updated, so these changes must not be lost on a quick quit.
        if before.0 != agents.map(\.name) || before.1 != skills.map(\.slug) { saveNow() }
    }

    /// Adds built-in skills and agents shipped after this Mac first ran agentim (e.g. QA Engineer),
    /// once: ones the user deleted aren't brought back.
    func addNewBuiltIns(defaults: UserDefaults = .standard) {
        let seenKey = "seenBuiltIns"
        var seen = Set(defaults.stringArray(forKey: seenKey) ?? (agents.map { "agent:\($0.name)" } + skills.map { "skill:\($0.slug)" }))
        for skill in Skill.builtIn where !seen.contains("skill:\(skill.slug)") && !skills.contains(where: { $0.slug == skill.slug }) {
            skills.append(skill)
        }
        for agent in Agent.starters(skills: skills) where !seen.contains("agent:\(agent.name)") && !agents.contains(where: { $0.name == agent.name }) {
            agents.append(agent)
        }
        seen.formUnion(Skill.builtIn.map { "skill:\($0.slug)" })
        seen.formUnion(Agent.starters(skills: skills).map { "agent:\($0.name)" })
        // Built-ins whose source is gone (removed from the app or from your private folder) are dropped too.
        // Only ones agentim added: agents and skills you created were never "seen" as built-ins.
        let current = Set(Skill.builtIn.map { "skill:\($0.slug)" } + Agent.starters(skills: skills).map { "agent:\($0.name)" })
        let retired = seen.subtracting(current)
        if !retired.isEmpty {
            agents.removeAll { retired.contains("agent:\($0.name)") }
            let retiredSkills = Set(skills.filter { retired.contains("skill:\($0.slug)") }.map(\.id))
            skills.removeAll { retiredSkills.contains($0.id) }
            for i in agents.indices { agents[i].skillIDs.removeAll { retiredSkills.contains($0) } }
            seen.subtract(retired)
        }
        defaults.set(Array(seen).sorted(), forKey: seenKey)
    }

    private func scheduleSave() {
        guard !isLoading else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        let snapshot = Snapshot(
            agents: agents, skills: skills, conversations: conversations, customModels: customModels,
            installedLocalModels: installedLocalModels, customProviders: customProviders, router: router,
            servers: servers, serverModels: serverModels)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
