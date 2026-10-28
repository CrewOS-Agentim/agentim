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

extension Agent {
    private struct Bundled: Decodable {
        let name: String
        let emoji: String
        let summary: String
        let system_prompt: String
        let skills: [String]
        let prefer_local: Bool
    }

    /// The gateway's agents (gateway/config/agents.json), wired to the built-in skills.
    static func starters(skills: [Skill]) -> [Agent] {
        guard let url = Bundle.main.url(forResource: "agents", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var bundled = try? JSONDecoder().decode([Bundled].self, from: data)
        else { return defaults }
        // Your private agents (<stack>/private/agents.json), e.g. company-specific ones.
        if let privateData = try? Data(contentsOf: PrivateContent.folder.appendingPathComponent("agents.json")),
           let privateAgents = try? JSONDecoder().decode([Bundled].self, from: privateData) {
            let names = Set(bundled.map(\.name))
            bundled += privateAgents.filter { !names.contains($0.name) }
        }
        return bundled.map { entry in
            Agent(name: entry.name, emoji: entry.emoji, summary: entry.summary, systemPrompt: entry.system_prompt,
                  skillIDs: skills.filter { entry.skills.contains($0.slug) }.map(\.id),
                  preferLocal: entry.prefer_local)
        }
    }
}
