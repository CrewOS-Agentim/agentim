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
    }

    var agents: [Agent] = Agent.defaults { didSet { scheduleSave() } }
    var skills: [Skill] = Skill.defaults { didSet { scheduleSave() } }
    var conversations: [Conversation] = [] { didSet { scheduleSave() } }
    var customModels: [AIModel] = [] { didSet { scheduleSave() } }
    var installedLocalModels: [AIModel] = [] { didSet { scheduleSave() } }
    var customProviders: [Provider] = [] { didSet { scheduleSave() } }
    var router = RouterSettings() { didSet { scheduleSave() } }

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
            .appendingPathComponent("agenthub.json")
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

    var allModels: [AIModel] { AIModel.cloudCatalog + customModels + installedLocalModels }

    /// What the router may choose from: connected providers + installed local weights.
    var availableModels: [AIModel] {
        allModels.filter { model in
            switch model.location {
            case .cloud(let id): provider(id: id).map(isConnected) ?? false
            case .local(let repo): LocalModelManager.isInstalled(repo)
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

    // MARK: - Conversations

    @discardableResult
    func newConversation(agent: Agent) -> Conversation {
        let conversation = Conversation(title: "New chat", agentID: agent.id)
        conversations.insert(conversation, at: 0)
        return conversation
    }

    func agent(for conversation: Conversation) -> Agent? { agents.first { $0.id == conversation.agentID } }

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

    func send(_ text: String, in conversationID: UUID) {
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
            } catch {
                conversations[index].messages.append(ChatMessage(role: .user, content: text))
                conversations[index].messages.append(
                    ChatMessage(role: .assistant, content: error.localizedDescription, isError: true))
                return
            }
        }

        let system = systemPrompt(agent: agent, message: prompt)
        conversations[index].messages.append(ChatMessage(role: .user, content: prompt))
        if conversations[index].messages.filter({ $0.role == .user }).count == 1 {
            conversations[index].title = String(prompt.prefix(48))
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

    private func client(for model: AIModel) -> ChatClient? {
        switch model.location {
        case .local(let repo):
            return MLXChatClient(repo: repo)
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
        isLoading = false
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
            installedLocalModels: installedLocalModels, customProviders: customProviders, router: router)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
