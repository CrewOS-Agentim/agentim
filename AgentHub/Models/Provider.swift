import Foundation

/// The wire protocol a provider speaks. Almost every cloud vendor offers an
/// OpenAI-compatible endpoint, so two clients cover the whole catalog.
enum WireProtocol: String, Codable {
    case anthropic
    case openAICompatible
}

/// A cloud (or self-hosted) endpoint the user can connect an API key to.
struct Provider: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var baseURL: URL
    var wire: WireProtocol
    var symbol: String
    /// Where the user gets a key; shown on the connect screen.
    var keyHelpURL: URL?
    var isBuiltIn: Bool = true

    var keychainAccount: String { "provider.\(id)" }
}

extension Provider {
    static let anthropic = Provider(
        id: "anthropic", name: "Anthropic", baseURL: URL(string: "https://api.anthropic.com/v1")!,
        wire: .anthropic, symbol: "a.circle.fill",
        keyHelpURL: URL(string: "https://console.anthropic.com/settings/keys"))
    static let openAI = Provider(
        id: "openai", name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!,
        wire: .openAICompatible, symbol: "o.circle.fill",
        keyHelpURL: URL(string: "https://platform.openai.com/api-keys"))
    static let gemini = Provider(
        id: "gemini", name: "Google Gemini",
        baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!,
        wire: .openAICompatible, symbol: "g.circle.fill",
        keyHelpURL: URL(string: "https://aistudio.google.com/apikey"))
    static let openRouter = Provider(
        id: "openrouter", name: "OpenRouter", baseURL: URL(string: "https://openrouter.ai/api/v1")!,
        wire: .openAICompatible, symbol: "arrow.triangle.branch",
        keyHelpURL: URL(string: "https://openrouter.ai/keys"))
    /// Hugging Face Inference Providers. Uses the same token as the HF account.
    static let huggingFace = Provider(
        id: "huggingface", name: "Hugging Face", baseURL: URL(string: "https://router.huggingface.co/v1")!,
        wire: .openAICompatible, symbol: "face.smiling",
        keyHelpURL: URL(string: "https://huggingface.co/settings/tokens"))

    static let builtIn: [Provider] = [.anthropic, .openAI, .gemini, .openRouter, .huggingFace]
}
