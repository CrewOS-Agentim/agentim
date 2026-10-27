import Foundation

/// A computer on the user's network that serves models: the AgentHub Runner
/// (native or in Docker), or any OpenAI-compatible server such as Ollama,
/// LM Studio, llama.cpp, vLLM or Docker Model Runner.
struct LocalServer: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Memory reporting, model pulls with a memory check, LTX, every backend on the host.
        case runner
        /// Chat only. Models come from `GET /models`.
        case openAICompatible

        var id: String { rawValue }
        var label: String { self == .runner ? "AgentHub Runner" : "OpenAI-compatible" }
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
}

extension AIModel {
    /// Router metadata for a server model, guessed from its name and parameter count.
    static func server(_ info: ServerModelInfo, on server: LocalServer) -> AIModel {
        let lower = info.id.lowercased()
        let shortName = info.id.split(separator: "/").last.map(String.init) ?? info.id
        let alias = "\(shortName)".lowercased().replacingOccurrences(of: ":", with: "-")

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
            displayName: "\(shortName) · \(server.name)", modelName: info.id,
            location: .server(serverID: server.id), capabilities: caps,
            contextWindow: 32_768, costTier: 0, qualityTier: quality, alias: alias)
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
