import Foundation
import Security

/// Edits a docker-compose `.env` file in place, keeping comments and order.
struct EnvFile: Equatable {
    private(set) var lines: [String]

    init(text: String) {
        lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    var text: String { lines.joined(separator: "\n") + "\n" }

    subscript(key: String) -> String? {
        for line in lines {
            if let (k, v) = Self.parse(line), k == key { return v }
        }
        return nil
    }

    /// Sets `key`, replacing an existing (or commented-out `# KEY=`) line, else appending.
    mutating func set(_ key: String, _ value: String) {
        let newLine = "\(key)=\(value)"
        if let i = lines.firstIndex(where: { Self.parse($0)?.0 == key }) {
            lines[i] = newLine
        } else if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("# \(key)=") }) {
            lines[i] = newLine
        } else {
            lines.append(newLine)
        }
    }

    /// Replaces every `change-me` placeholder with a fresh random secret.
    mutating func fillSecrets(generator: () -> String = EnvFile.randomSecret) {
        for (i, line) in lines.enumerated() {
            if let (key, value) = Self.parse(line), value == "change-me" { lines[i] = "\(key)=\(generator())" }
        }
    }

    static func parse(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = String(trimmed[..<eq])
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return (key, String(trimmed[trimmed.index(after: eq)...]))
    }

    static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// The settings onboarding writes into `.env` for the chosen models.
struct OnboardingPlan: Equatable {
    var chat: ModelChoice
    var coding: ModelChoice
    var voice: ModelChoice
    var media: ModelChoice

    /// Ollama references to pull, in order (chat first so Tim can talk ASAP).
    var ollamaRefs: [String] { [chat.ollamaRef, coding.ollamaRef].compactMap { $0 } }

    var downloadBytes: Int64 { [chat, coding, voice].reduce(0) { $0 + $1.sizeBytes } }

    func apply(to env: inout EnvFile) {
        env.set("AGENTIM_DEFAULT_MODELS", ollamaRefs.joined(separator: ","))
        if case .voice(let stt, let tts) = voice.kind {
            env.set("COMPOSE_PROFILES", "voice")
            env.set("VOICE_URL", "http://voice:8000")
            env.set("AGENTIM_STT_MODEL", stt)
            env.set("AGENTIM_TTS_MODEL", tts)
            env.set("AGENTIM_TTS_VOICE", "af_heart")
            env.set("AGENTIM_VOICE_REPLIES", "true")
        } else {
            env.set("COMPOSE_PROFILES", "")
            env.set("VOICE_URL", "")
        }
        env.set("AGENTIM_LTX", media.kind == .ltx ? "true" : "false")
    }
}
