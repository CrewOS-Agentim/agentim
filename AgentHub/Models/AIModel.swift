import Foundation

/// What a model is good at. The router matches these against the task.
enum Capability: String, Codable, CaseIterable, Identifiable {
    case coding, reasoning, creative, fast, longContext, general, video, image, agent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coding: "Coding"
        case .reasoning: "Reasoning"
        case .creative: "Writing"
        case .fast: "Fast"
        case .longContext: "Long context"
        case .general: "General"
        case .video: "Video"
        case .image: "Image"
        case .agent: "Local agent"
        }
    }

    /// Generates media instead of text; only chosen when the message asks for it.
    var isMedia: Bool { self == .video || self == .image }

    /// Only used when the message names the model (@ltx-video, @claude-code): media and local coding agents.
    var isExplicitOnly: Bool { isMedia || self == .agent }
}

enum ModelLocation: Codable, Hashable {
    case cloud(providerID: String)
    /// A Hugging Face repo downloaded to the device and run with MLX.
    case local(repoID: String)
    /// Served by a computer the user owns (agentim runner, Ollama, LM Studio, Docker...).
    case server(serverID: UUID)
}

struct AIModel: Identifiable, Codable, Hashable {
    /// Stable id: "<provider>/<modelName>" or "local/<repo>".
    var id: String
    var displayName: String
    /// The id sent on the wire (cloud) or the HF repo id (local).
    var modelName: String
    var location: ModelLocation
    var capabilities: Set<Capability>
    var contextWindow: Int
    /// 1 = cheapest, 4 = most expensive. Local models are 0 (free).
    var costTier: Int
    /// 1 = weakest, 5 = strongest. Breaks ties between similar models.
    var qualityTier: Int
    /// Short handle for "@alias" overrides in the composer.
    var alias: String
    var isBuiltIn: Bool = true

    /// Private and free: runs on this device or on the user's own server.
    var isLocal: Bool { isOnDevice || serverID != nil }

    var isOnDevice: Bool {
        if case .local = location { return true }
        return false
    }

    var serverID: UUID? {
        if case .server(let id) = location { return id }
        return nil
    }

    var isMedia: Bool { !capabilities.isEmpty && capabilities.allSatisfy(\.isMedia) }
    var isExplicitOnly: Bool { !capabilities.isEmpty && capabilities.allSatisfy(\.isExplicitOnly) }

    var locationSymbol: String {
        switch location {
        case .cloud: "cloud"
        case .local: "laptopcomputer"
        case .server: "desktopcomputer"
        }
    }

    var providerID: String? {
        if case .cloud(let id) = location { return id }
        return nil
    }

    /// Reads images sent with a message (vision). Known from the provider, else guessed from the model's name.
    var canSeeImages: Bool {
        if isMedia || capabilities.contains(.agent) { return false }
        let name = modelName.lowercased()
        switch location {
        case .local:
            return false  // the on-device MLX models are text-only
        case .cloud(let provider) where provider == Provider.anthropic.id || provider == Provider.gemini.id:
            return true
        case .cloud(let provider) where provider == Provider.openAI.id:
            return ["gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4"].contains { name.hasPrefix($0) }
        default:
            // Claude and ChatGPT through your login run as text prompts in a terminal.
            if name.hasPrefix("claude/") || name.hasPrefix("chatgpt/") { return false }
            if name.contains("gemma-3-1b") || name.contains("gemma3:1b") { return false }
            return Self.visionNames.contains { name.contains($0) }
        }
    }

    /// Open models that see images (Ollama, LM Studio, Hugging Face names).
    static let visionNames = [
        "-vl", "vl-", "_vl", "vision", "qwen3.5", "qwen3_5", "gemma-3", "gemma3", "llava", "pixtral", "minicpm-v",
        "moondream", "frontend-design-expert", "llama-4", "llama4", "mistral-small-3", "internvl", "glm-4.5v", "kimi-vl",
    ]
}

extension AIModel {
    static func cloud(
        _ provider: Provider, _ name: String, display: String, alias: String,
        caps: Set<Capability>, context: Int, cost: Int, quality: Int
    ) -> AIModel {
        AIModel(
            id: "\(provider.id)/\(name)", displayName: display, modelName: name,
            location: .cloud(providerID: provider.id), capabilities: caps,
            contextWindow: context, costTier: cost, qualityTier: quality, alias: alias)
    }

    static func local(repo: String, display: String, caps: Set<Capability>, context: Int, quality: Int) -> AIModel {
        AIModel(
            id: "local/\(repo)", displayName: display, modelName: repo,
            location: .local(repoID: repo), capabilities: caps, contextWindow: context,
            costTier: 0, qualityTier: quality,
            alias: repo.split(separator: "/").last.map { String($0).lowercased() } ?? repo)
    }

    /// Default cloud catalog. Users can add any other model id from the Models tab.
    static let cloudCatalog: [AIModel] = [
        .cloud(.anthropic, "claude-opus-5-5", display: "Claude Opus 5.5", alias: "opus",
               caps: [.coding, .reasoning, .creative, .longContext, .general], context: 200_000, cost: 4, quality: 5),
        .cloud(.anthropic, "claude-sonnet-5-5", display: "Claude Sonnet 5.5", alias: "sonnet",
               caps: [.coding, .reasoning, .creative, .longContext, .general], context: 200_000, cost: 3, quality: 4),
        .cloud(.anthropic, "claude-haiku-5-5", display: "Claude Haiku 5.5", alias: "haiku",
               caps: [.fast, .general, .coding], context: 200_000, cost: 1, quality: 3),
        .cloud(.openAI, "gpt-5", display: "GPT-5", alias: "gpt5",
               caps: [.coding, .reasoning, .creative, .longContext, .general], context: 400_000, cost: 3, quality: 5),
        .cloud(.openAI, "gpt-5-mini", display: "GPT-5 mini", alias: "gpt5mini",
               caps: [.fast, .general, .coding], context: 400_000, cost: 1, quality: 3),
        .cloud(.gemini, "gemini-2.5-pro", display: "Gemini 2.5 Pro", alias: "gemini",
               caps: [.reasoning, .coding, .longContext, .general], context: 1_000_000, cost: 3, quality: 4),
        .cloud(.gemini, "gemini-2.5-flash", display: "Gemini 2.5 Flash", alias: "flash",
               caps: [.fast, .longContext, .general], context: 1_000_000, cost: 1, quality: 3),
        .cloud(.huggingFace, "Qwen/Qwen3-Coder-480B-A35B-Instruct", display: "Qwen3 Coder (HF)", alias: "qwencoder",
               caps: [.coding], context: 256_000, cost: 2, quality: 4),
        .cloud(.huggingFace, "meta-llama/Llama-3.3-70B-Instruct", display: "Llama 3.3 70B (HF)", alias: "llama70",
               caps: [.general, .creative], context: 128_000, cost: 1, quality: 3),
        .cloud(.huggingFace, "deepseek-ai/DeepSeek-V4-Flash", display: "DeepSeek V4 Flash (HF)", alias: "deepseek",
               caps: [.coding, .reasoning, .general], context: 128_000, cost: 1, quality: 4),
        .cloud(.huggingFace, "deepseek-ai/DeepSeek-V4-Pro", display: "DeepSeek V4 Pro (HF)", alias: "deepseekpro",
               caps: [.coding, .reasoning, .longContext], context: 128_000, cost: 2, quality: 5),
        .cloud(.huggingFace, "Qwen/Qwen3.5-27B", display: "Qwen3.5 27B (HF)", alias: "qwen35",
               caps: [.general, .coding], context: 128_000, cost: 1, quality: 4),
    ]

    /// Small MLX builds that fit on recent iPhones. Sizes are fetched live from HF before download.
    static let suggestedLocal: [AIModel] = [
        .local(repo: "mlx-community/Qwen3-1.7B-4bit", display: "Qwen3 1.7B",
               caps: [.fast, .general, .coding], context: 32_768, quality: 2),
        .local(repo: "mlx-community/Llama-3.2-1B-Instruct-4bit", display: "Llama 3.2 1B",
               caps: [.fast, .general], context: 131_072, quality: 1),
        .local(repo: "mlx-community/Llama-3.2-3B-Instruct-4bit", display: "Llama 3.2 3B",
               caps: [.fast, .general, .creative], context: 131_072, quality: 2),
        .local(repo: "mlx-community/Qwen3-4B-4bit", display: "Qwen3 4B",
               caps: [.general, .coding, .reasoning], context: 32_768, quality: 3),
        .local(repo: "mlx-community/gemma-3-1b-it-qat-4bit", display: "Gemma 3 1B",
               caps: [.fast, .general], context: 32_768, quality: 1),
    ]
}
