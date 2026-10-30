import Foundation

/// A computer on the user's network that serves models: the agentim runner
/// (native or in Docker), or any OpenAI-compatible server such as Ollama,
/// LM Studio, llama.cpp, vLLM or Docker Model Runner.
struct LocalServer: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Memory reporting, model pulls with a memory check, LTX, every backend on the host.
        case runner
        /// Chat only. Models come from `GET /models`.
        case openAICompatible

        var id: String { rawValue }
        var label: String { self == .runner ? "agentim runner" : "OpenAI-compatible" }
    }

    var id = UUID()
    var name: String
    /// Runner: http://host:8765. OpenAI-compatible: the base that has /chat/completions, e.g. http://host:11434/v1.
    var baseURL: URL
    var kind: Kind = .runner

    var keychainAccount: String { "server.\(id.uuidString)" }

    /// Where `/chat/completions` and `/models` live.
    var openAIBaseURL: URL { kind == .runner ? baseURL.appendingPathComponent("v1") : baseURL }
}

/// Model entry from `GET /v1/models` (runner extras are optional).
struct ServerModelInfo: Decodable, Hashable {
    let id: String
    let kind: String?
    let size_bytes: Int64?
    let parameter_size: String?
    let loaded: Bool?
    var name: String? = nil
}

extension AIModel {
    /// Router metadata for a server model, guessed from its name and parameter count.
    static func server(_ info: ServerModelInfo, on server: LocalServer) -> AIModel {
        let lower = info.id.lowercased()
        let (name, tag) = readableName(info.id)
        // Same rule as the gateway: repo name without "-GGUF" or the tag, lowercased.
        let alias = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let pretty = name.replacingOccurrences(of: "-", with: " ")
        let shortName = tag.map { "\(pretty) \($0)" } ?? pretty

        if info.kind == "agent" {
            // A coding agent on the Mac (Claude Code, Codex): only when called by name, e.g. @claude-code.
            let alias = String(info.id.split(separator: "/").last ?? Substring(info.id))
            return AIModel(
                id: "server-\(server.id.uuidString.prefix(8))/\(info.id)",
                displayName: "\(info.name ?? alias) · \(server.name)", modelName: info.id,
                location: .server(serverID: server.id), capabilities: [.agent],
                contextWindow: 10_000_000, costTier: 0, qualityTier: 5, alias: alias)
        }
        if info.kind == "chatgpt" {
            // ChatGPT through the ChatGPT login on the Mac (codex exec in tmux): a real chat model, no API key.
            let model = String(info.id.split(separator: "/").last ?? Substring(info.id))
            return AIModel(
                id: "server-\(server.id.uuidString.prefix(8))/\(info.id)",
                displayName: info.name ?? "ChatGPT (your ChatGPT login)", modelName: info.id,
                location: .server(serverID: server.id), capabilities: [.general, .coding, .reasoning, .creative, .longContext],
                contextWindow: 200_000, costTier: 3, qualityTier: 5, alias: model == "default" ? "chatgpt" : model)
        }
        if info.kind == "claude" {
            // Claude through the Claude login on the Mac (claude -p in tmux): a real chat model, no API key.
            let alias = String(info.id.split(separator: "/").last ?? Substring(info.id))
            let tier: (quality: Int, cost: Int) = ["opus": (5, 4), "sonnet": (4, 3), "haiku": (3, 1)][alias] ?? (4, 3)
            var caps: Set<Capability> = [.general, .coding, .reasoning, .creative, .longContext]
            if alias == "haiku" { caps.insert(.fast) }
            return AIModel(
                id: "server-\(server.id.uuidString.prefix(8))/\(info.id)",
                displayName: info.name ?? "Claude \(alias.capitalized) (your Claude login)", modelName: info.id,
                location: .server(serverID: server.id), capabilities: caps,
                contextWindow: 200_000, costTier: tier.cost, qualityTier: tier.quality, alias: alias)
        }
        if info.kind == "video" || info.kind == "image" {
            let cap: Capability = info.kind == "video" ? .video : .image
            return AIModel(
                id: "server-\(server.id.uuidString.prefix(8))/\(info.id)",
                displayName: "LTX \(cap.label) · \(server.name)", modelName: info.id,
                location: .server(serverID: server.id), capabilities: [cap],
                // Media models see only the latest prompt, so history never overflows them.
                contextWindow: 10_000_000, costTier: 0, qualityTier: 4, alias: "ltx-\(info.kind!)")
        }

        let billions = parameterBillions(info.parameter_size ?? info.id)
        var caps: Set<Capability> = [.general]
        if lower.contains("coder") || lower.contains("code") || lower.contains("devstral") { caps.insert(.coding) }
        if ["r1", "qwq", "think", "reason", "magistral"].contains(where: lower.contains) { caps.insert(.reasoning) }
        if let billions, billions <= 4 { caps.insert(.fast) }
        if let billions, billions >= 14 { caps.formUnion([.reasoning, .creative]) }

        let quality: Int
        switch billions ?? 7 {
        case ..<2: quality = 1
        case ..<6: quality = 2
        case ..<15: quality = 3
        case ..<40: quality = 4
        default: quality = 5
        }
        return AIModel(
            id: "server-\(server.id.uuidString.prefix(8))/\(info.id)",
            displayName: shortName, modelName: info.id,
            location: .server(serverID: server.id), capabilities: caps,
            contextWindow: 32_768, costTier: 0, qualityTier: quality, alias: alias)
    }

    /// "ollama/hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M" → ("Qwen3-4B-Instruct-2507", nil),
    /// "ollama/qwen2.5-coder:14b" → ("qwen2.5-coder", "14b"). Quantization tags are dropped.
    static func readableName(_ id: String) -> (name: String, tag: String?) {
        let last = id.split(separator: "/").last.map(String.init) ?? id
        let parts = last.split(separator: ":", maxSplits: 1).map(String.init)
        var name = parts[0]
        if name.lowercased().hasSuffix("-gguf") { name = String(name.dropLast(5)) }
        let tag = parts.count > 1 ? parts[1] : nil
        let isQuant = tag.map { $0.range(of: #"^(q\d|iq\d|f16|bf16|fp16|latest)"#, options: [.regularExpression, .caseInsensitive]) != nil } ?? true
        return (name, isQuant ? nil : tag)
    }

    /// "8.0B" → 8, "751.63M" → 0.75, "qwen2.5-coder:14b" → 14.
    static func parameterBillions(_ text: String) -> Double? {
        let pattern = #"(\d+(?:\.\d+)?)\s*([bBmM])\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              let numberRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[numberRange])
        else { return nil }
        return text[unitRange].lowercased() == "m" ? value / 1_000 : value
    }
}
