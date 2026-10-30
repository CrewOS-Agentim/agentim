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
    private(set) var streamingConversationIDs: Set<UUID> = []
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

    /// How Claude is used: "tmux" (your Claude login, claude -p in a background terminal) or "api" (an API key).
    var claudeVia: String = UserDefaults.standard.string(forKey: "claudeVia") ?? "tmux" {
        didSet { UserDefaults.standard.set(claudeVia, forKey: "claudeVia") }
    }

    /// What the router may choose from: connected providers + installed local weights.
    var availableModels: [AIModel] {
        allModels.filter { model in
            switch model.location {
            case .cloud(let id) where id == Provider.anthropic.id && claudeVia == "tmux":
                false  // Claude goes through tmux (claude -p), never the API
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
        let conversation = Conversation(title: "New chat", agentID: agent.id)
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
        conversation.participantIDs = participants.map(\.id)
        conversation.participantSkillIDs = skills.map(\.id)
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

    /// The meeting so far as a transcript, with the person each line is from.
    func transcript(_ conversation: Conversation, limit: Int = 16) -> String {
        conversation.messages.suffix(limit).filter { !$0.isError && !$0.content.isEmpty }.map { message in
            let who = message.role == .user ? "You" : speaker(of: message)?.name ?? "Assistant"
            return "\(who): \(message.modelContent)"
        }.joined(separator: "\n\n")
    }

    /// Posts the message, then the addressed members answer in turn; with more discussion rounds they keep talking to
    /// each other (each seeing everything before it) until the rounds run out or everyone passes.
    func sendToMeeting(_ text: String, attachments: [ChatAttachment] = [], in conversationID: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationID }) else { return }
        conversations[index].messages.append(ChatMessage(role: .user, content: text, attachments: attachments.nilIfEmpty))
        let everyone = members(in: conversations[index])
        let speakers = Self.addressed(text, among: everyone)
        let rounds = max(1, min(conversations[index].discussionRounds ?? 1, Self.maxRounds))
        streamingConversationIDs.insert(conversationID)
        Task {
            defer { streamingConversationIDs.remove(conversationID) }
            for round in 1...rounds {
                var spoke = false
                for member in speakers {
                    let passed = await meetingReply(from: member, others: everyone.filter { $0.id != member.id },
                                                    in: conversationID, round: round)
                    spoke = spoke || !passed
                }
                if round > 1 && !spoke { break }  // everyone agrees: the discussion is over
            }
        }
    }

    static let maxRounds = 5

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

    /// One member's turn. Returns true when they passed (nothing to add): their empty turn is removed.
    @discardableResult
    private func meetingReply(from member: Member, others: [Member], in conversationID: UUID, round: Int = 1) async -> Bool {
        guard let conversation = conversations.first(where: { $0.id == conversationID }) else { return true }
        let names = others.map(\.name).joined(separator: ", ")
        let turn = round == 1
            ? """
              Reply now as \(member.name), from your own expertise. Build on (or push back on) what others said, address them \
              by name when you do, don't repeat their points, and keep it under 180 words. Start with "\(member.name):".
              """
            : """
              The discussion continues (round \(round)). Reply as \(member.name) to what the others just said: build on it, \
              push back, or improve the draft, addressing them by name. Work toward what the user asked for. Under 150 words, \
              start with "\(member.name):". If you have nothing new to add and agree with where it landed, reply with exactly PASS.
              """
        let ask = """
        You're in a group chat with the user\(names.isEmpty ? "" : " and \(names)").\(briefText(conversation).map { "\n\n\($0)" } ?? "")

        Here's the conversation so far:

        \(transcript(conversation))

        \(turn)
        """
        let agent = member.agent
        let reply = ChatMessage(role: .assistant, content: "", agentID: member.agent?.id, skillID: member.skill?.id)
        guard let c = conversations.firstIndex(where: { $0.id == conversationID }) else { return true }
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
                    $0.routingReason = "\(member.name) in the group chat" + (round > 1 ? " · round \(round)" : "")
                }
                do {
                    let request = ChatRequest(model: model.modelName, system: system,
                                              messages: [ChatMessage(role: .user, content: ask)])
                    for try await chunk in client.stream(request) {
                        updateReply(reply.id, in: conversationID) { $0.content += chunk }
                    }
                    // Small models often echo "Name:"; the bubble already shows who's talking.
                    updateReply(reply.id, in: conversationID) {
                        $0.content = Self.withoutSpeakerPrefix($0.content, name: member.name)
                    }
                    if round > 1, Self.isPass(message(reply.id, in: conversationID)?.content ?? "") {
                        removeMessage(reply.id, in: conversationID)  // nothing to add: no empty bubble
                        return true
                    }
                    return false
                } catch {
                    if let content = message(reply.id, in: conversationID)?.content, !content.isEmpty { return false }
                }
            }
            throw RoutingError.noModelsAvailable
        } catch {
            updateReply(reply.id, in: conversationID) {
                $0.isError = true
                $0.content = "\(member.name) couldn't answer: \(error.localizedDescription)"
            }
        }
        return false
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

        let targets: [(client: ChatClient, model: String, modelID: String?, reason: String)]
        let prompt: String

        if let agent, case .remote(let endpoint, let model) = agent.kind {
            let client = OpenAICompatibleClient(
                baseURL: endpoint, apiKey: Keychain.get(agent.keychainAccount), isFullEndpoint: true)
            targets = [(client, model, nil, "Remote agent \(agent.name)")]
            prompt = text
        } else {
            do {
                let decision = try ModelRouter(available: availableModels, settings: router).route(
                    RoutingRequest(text: text, history: conversation.messages, agent: agent,
                                   conversationPin: conversation.pinnedModelID, isOnline: isOnline))
                targets = ([decision.model] + decision.fallbacks.prefix(2)).compactMap { model in
                    client(for: model).map { ($0, model.modelName, model.id, model.id == decision.model.id ? decision.reason : "Fallback after error") }
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
            var lastError: Error?
            for target in targets {
                updateReply(reply.id, in: conversationID) {
                    $0.content = ""
                    $0.modelID = target.modelID
                    $0.routingReason = target.reason
                    $0.isError = false
                }
                do {
                    let request = ChatRequest(model: target.model, system: system, messages: history)
                    for try await chunk in target.client.stream(request) {
                        updateReply(reply.id, in: conversationID) { $0.content += chunk }
                    }
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
        for skill in activeSkills(agent: agent, message: message) {
            parts.append("## Skill: \(skill.name)\n\(skill.instructions)")
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

    func client(for model: AIModel) -> ChatClient? {
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
        conversations = snapshot.conversations
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
