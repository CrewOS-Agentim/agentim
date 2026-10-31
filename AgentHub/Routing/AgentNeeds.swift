import Foundation

/// What an agent's work needs from a model, read from its name and description: the kind of model
/// (coding, reasoning, writing) and whether it makes pictures or video at all.
struct AgentNeeds: Equatable {
    /// The kind of model its work needs; nil for generalists (Agent Tim).
    var primary: Capability?
    /// Makes images or video (YouTube, video, illustration…). Specialists who don't never get a media model.
    var makesMedia: Bool

    static let anything = AgentNeeds(primary: nil, makesMedia: true)

    static let mediaWords = ["video", "youtube", "film", "animation", "animator", "illustrator", "illustration",
                             "photo", "photographer", "thumbnail", "image", "images", "ltx", "motion graphics"]
    static let codingWords = ["engineer", "developer", "programmer", "code", "coding", "qa", "devops", "cto",
                              "debugging", "software", "frontend", "backend", "api testing", "sre"]
    static let reasoningWords = ["analyst", "analytics", "data", "metrics", "cfo", "finance", "financial", "strategy",
                                 "validator", "validate", "product manager", "cpo", "ciso", "security", "research",
                                 "researcher", "recruiter", "project manager", "coo", "legal", "economist", "scientist"]
    static let creativeWords = ["writer", "copywriter", "copy", "marketing", "cmo", "content", "brand", "social media",
                                "storyteller", "story", "creator", "editor", "designer"]

    /// Agents without a description fit anything; specialists get what their job needs.
    static func of(_ agent: Agent?) -> AgentNeeds {
        guard let agent else { return .anything }
        return of(name: agent.name, summary: agent.summary)
    }

    static func of(name: String, summary: String) -> AgentNeeds {
        let text = "\(name) \(summary)".lowercased()
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ list: [String]) -> Bool { list.contains { $0.contains(" ") ? text.contains($0) : words.contains($0) } }
        let primary: Capability? = has(codingWords) ? .coding : has(reasoningWords) ? .reasoning : has(creativeWords) ? .creative : nil
        // Generalists may make media when asked; specialists only when it's their job.
        return AgentNeeds(primary: primary, makesMedia: primary == nil || has(mediaWords))
    }
}
