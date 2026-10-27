import Foundation

/// How an agent picks its model.
enum ModelPreference: Codable, Hashable {
    /// Let the router decide per message.
    case auto
    /// Always use this model id (still overridable per message with @alias).
    case pinned(String)
}

enum AgentKind: Codable, Hashable {
    /// System prompt + skills, answered by whichever model the router picks.
    case assistant
    /// A hosted agent behind an OpenAI-compatible chat endpoint (your own server,
    /// a LangGraph/CrewAI deployment, an agent platform...). The router is bypassed.
    case remote(endpoint: URL, model: String)
}

struct Agent: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
    var summary: String
    var systemPrompt: String
    var kind: AgentKind = .assistant
    var modelPreference: ModelPreference = .auto
    var skillIDs: [UUID] = []
    /// Keep this agent's traffic on-device whenever a local model is installed.
    var preferLocal = false

    var keychainAccount: String { "agent.\(id.uuidString)" }
}

extension Agent {
    static let defaults: [Agent] = [
        Agent(name: "General", emoji: "✨", summary: "Everyday assistant, routed automatically",
              systemPrompt: "You are a helpful, concise assistant."),
        Agent(name: "Code Pilot", emoji: "🧑‍💻", summary: "Pair programmer for reviews and debugging",
              systemPrompt: "You are a senior software engineer. Prefer small, correct, well-explained changes. Show code in fenced blocks."),
        Agent(name: "Private Notes", emoji: "🔒", summary: "Stays on-device with a local model",
              systemPrompt: "You help the user think through personal notes. Be brief.", preferLocal: true),
    ]
}
