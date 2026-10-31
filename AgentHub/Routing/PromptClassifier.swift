import Foundation

/// What the router learned about a message before choosing a model.
struct TaskProfile: Equatable {
    var primary: Capability
    var estimatedTokens: Int
    /// Personal or secret-looking content; the router keeps it on-device when it can.
    var isSensitive: Bool
}

/// Cheap, on-device heuristics. Fast enough to run on every keystroke and
/// predictable enough that the user can understand why a model was picked.
enum PromptClassifier {
    static func classify(_ text: String, history: [ChatMessage] = []) -> TaskProfile {
        let lower = text.lowercased()
        let historyChars = history.reduce(0) { $0 + $1.content.count }
        let tokens = estimateTokens(characters: text.count + historyChars)

        return TaskProfile(
            primary: primaryCapability(lower, rawLength: text.count, tokens: tokens),
            estimatedTokens: tokens,
            isSensitive: isSensitive(lower))
    }

    /// ~4 characters per token is close enough for routing decisions.
    static func estimateTokens(characters: Int) -> Int {
        max(1, characters / 4)
    }

    private static func primaryCapability(_ text: String, rawLength: Int, tokens: Int) -> Capability {
        if contains(text, videoSignals) { return .video }
        if contains(text, imageSignals) { return .image }
        if tokens > 24_000 { return .longContext }
        if contains(text, codeSignals) { return .coding }
        if contains(text, reasoningSignals) { return .reasoning }
        if contains(text, creativeSignals) { return .creative }
        if rawLength < 160 { return .fast }
        return .general
    }

    private static func isSensitive(_ text: String) -> Bool {
        if contains(text, sensitiveSignals) { return true }
        // Card numbers, SSNs and similar long digit runs.
        return text.range(of: #"\b(?:\d[ -]?){9,19}\b"#, options: .regularExpression) != nil
    }

    private static func contains(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    static let codeSignals = [
        "```", "func ", "def ", "const ", "=>", "();", "stack trace", "exception", "compile",
        "bug", "refactor", "regex", "sql", "swift", "python", "javascript", "typescript",
        "kotlin", "unit test", "error:",
    ]
    static let reasoningSignals = [
        "prove", "step by step", "why does", "analyze", "analyse", "trade-off", "tradeoff",
        "compare", "calculate", "solve", "plan", "strategy", "estimate", "math",
    ]
    static let creativeSignals = [
        "story", "poem", "write a", "draft", "rewrite", "slogan", "lyrics", "blog post", "tone",
    ]
    static let videoSignals = [
        "make a video", "generate a video", "create a video", "render a video", "video of", "video clip",
        "animate a ", "animate an ", "animate my", "animation of", "short film", "film of",
    ]
    static let imageSignals = [
        "make an image", "generate an image", "create an image", "image of", "picture of", "photo of",
        "draw a ", "draw an ", "draw me", "sketch of", "illustration of", "render an image", "poster of",
    ]
    static let sensitiveSignals = [
        "password", "passcode", "ssn", "social security", "diagnosis", "medical", "my salary",
        "bank account", "private key", "api key", "secret", "confidential", "therapy",
    ]
}
