import Foundation

/// What the user picks a model for during onboarding.
enum ModelCategory: String, CaseIterable, Identifiable {
    case chat, coding, voice, media
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .coding: "Coding"
        case .voice: "Voice"
        case .media: "Video & images"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right.fill"
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .voice: "waveform"
        case .media: "film.stack.fill"
        }
    }

    var blurb: String {
        switch self {
        case .chat: "Everyday questions, writing, planning. Agent Tim's main brain."
        case .coding: "Debugging, reviews and code. Used whenever a message looks like code."
        case .voice: "Understand voice notes and answer out loud. Whisper + Kokoro, in Docker."
        case .media: "Make videos and pictures from chat with LTX Desktop, on this Mac."
        }
    }
}

/// One option in the onboarding picker.
struct ModelChoice: Identifiable, Hashable {
    enum Kind: Hashable {
        /// An Ollama reference (Hugging Face GGUF) served by the Docker stack.
        case ollama(String)
        /// Speech-to-text + text-to-speech models served by the voice container.
        case voice(stt: String, tts: String)
        /// LTX Desktop through the native runner.
        case ltx
        /// Same as another category (e.g. coding falls back to the chat model).
        case none
    }

    var id: String
    var category: ModelCategory
    var name: String
    var detail: String
    /// Download size in bytes (verified Q4_K_M sizes for GGUF models).
    var sizeBytes: Int64
    var kind: Kind

    var ollamaRef: String? {
        if case .ollama(let ref) = kind { return ref }
        return nil
    }

    var runsInMemory: Bool {
        switch kind {
        case .ollama, .voice: true
        case .ltx, .none: false
        }
    }
}

enum ModelCatalog {
    private static let gb: Int64 = 1_073_741_824
    private static func gigabytes(_ value: Double) -> Int64 { Int64(value * Double(gb)) }

    static let all: [ModelChoice] = [
        // Chat
        .init(id: "chat-qwen3-1.7b", category: .chat, name: "Qwen3 1.7B", detail: "Tiny and quick. Great on 8 GB Macs.",
              sizeBytes: gigabytes(1.03), kind: .ollama("hf.co/unsloth/Qwen3-1.7B-GGUF:Q4_K_M")),
        .init(id: "chat-llama3.2-3b", category: .chat, name: "Llama 3.2 3B", detail: "Fast, friendly, good at everyday chat.",
              sizeBytes: gigabytes(1.88), kind: .ollama("hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M")),
        .init(id: "chat-qwen3-4b", category: .chat, name: "Qwen3 4B Instruct", detail: "Best small all-rounder. The default.",
              sizeBytes: gigabytes(2.33), kind: .ollama("hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M")),
        .init(id: "chat-gemma3-12b", category: .chat, name: "Gemma 3 12B", detail: "Warmer writing, broader knowledge.",
              sizeBytes: gigabytes(6.80), kind: .ollama("hf.co/unsloth/gemma-3-12b-it-GGUF:Q4_K_M")),
        .init(id: "chat-qwen3-14b", category: .chat, name: "Qwen3 14B", detail: "Strong reasoning for planning and analysis.",
              sizeBytes: gigabytes(8.38), kind: .ollama("hf.co/unsloth/Qwen3-14B-GGUF:Q4_K_M")),
        .init(id: "chat-qwen3-30b", category: .chat, name: "Qwen3 30B (MoE)", detail: "Near-frontier answers. Needs 32 GB+.",
              sizeBytes: gigabytes(17.28), kind: .ollama("hf.co/unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_M")),
        // Coding
        .init(id: "code-same", category: .coding, name: "Use my chat model", detail: "No extra download.",
              sizeBytes: 0, kind: .none),
        .init(id: "code-qwen2.5-1.5b", category: .coding, name: "Qwen2.5 Coder 1.5B", detail: "Autocomplete-sized, very fast.",
              sizeBytes: gigabytes(0.92), kind: .ollama("hf.co/bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M")),
        .init(id: "code-qwen2.5-7b", category: .coding, name: "Qwen2.5 Coder 7B", detail: "Solid everyday pair programmer.",
              sizeBytes: gigabytes(4.36), kind: .ollama("hf.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF:Q4_K_M")),
        .init(id: "code-qwen2.5-14b", category: .coding, name: "Qwen2.5 Coder 14B", detail: "Better at bigger refactors and reviews.",
              sizeBytes: gigabytes(8.37), kind: .ollama("hf.co/bartowski/Qwen2.5-Coder-14B-Instruct-GGUF:Q4_K_M")),
        .init(id: "code-qwen3-coder-30b", category: .coding, name: "Qwen3 Coder 30B (MoE)", detail: "Agent-grade coding. Needs 32 GB+.",
              sizeBytes: gigabytes(17.28), kind: .ollama("hf.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF:Q4_K_M")),
        // Voice (sizes are approximate: Whisper weights + Kokoro 82M)
        .init(id: "voice-off", category: .voice, name: "No voice", detail: "Text only.", sizeBytes: 0, kind: .none),
        .init(id: "voice-base", category: .voice, name: "Whisper Base + Kokoro", detail: "Light and quick. Good for short voice notes.",
              sizeBytes: gigabytes(0.5), kind: .voice(stt: "Systran/faster-whisper-base", tts: "speaches-ai/Kokoro-82M-v1.0-ONNX")),
        .init(id: "voice-small", category: .voice, name: "Whisper Small + Kokoro", detail: "Accurate in most languages. The default.",
              sizeBytes: gigabytes(0.8), kind: .voice(stt: "Systran/faster-whisper-small", tts: "speaches-ai/Kokoro-82M-v1.0-ONNX")),
        .init(id: "voice-turbo", category: .voice, name: "Whisper Large v3 Turbo + Kokoro", detail: "Best accuracy, accents and noisy rooms.",
              sizeBytes: gigabytes(1.9), kind: .voice(stt: "deepdml/faster-whisper-large-v3-turbo-ct2", tts: "speaches-ai/Kokoro-82M-v1.0-ONNX")),
        // Video & images
        .init(id: "media-off", category: .media, name: "Skip for now", detail: "You can add it later.", sizeBytes: 0, kind: .none),
        .init(id: "media-ltx", category: .media, name: "LTX Desktop", detail: "Free, local video and images. Runs natively on Apple silicon.",
              sizeBytes: 0, kind: .ltx),
    ]

    /// Share of Docker's memory one recommended chat/coding model may take.
    static let modelBudgetShare = 0.7

    static func options(for category: ModelCategory) -> [ModelChoice] { all.filter { $0.category == category } }

    static func choice(id: String) -> ModelChoice? { all.first { $0.id == id } }

    /// Memory needed to run a choice (weights + KV cache + runtime), same rule as the runner.
    static func requiredBytes(_ choice: ModelChoice) -> Int64 {
        choice.runsInMemory ? DeviceMemory.requiredBytes(weightBytes: choice.sizeBytes) : 0
    }

    static func fits(_ choice: ModelChoice, memory: Int64) -> Bool { requiredBytes(choice) <= memory }

    /// The best option that comfortably fits, leaving room for the chat model to share memory.
    static func recommended(for category: ModelCategory, memory: Int64, ltxInstalled: Bool) -> ModelChoice {
        let options = options(for: category)
        switch category {
        case .media:
            return options.first { ltxInstalled ? $0.kind == .ltx : $0.kind == .none }!
        case .voice:
            return memory >= 6 * gb ? choice(id: "voice-small")! : choice(id: "voice-base")!
        case .chat, .coding:
            // Ollama keeps one big model loaded at a time (it swaps chat ↔ coding), so a model may use
            // most of Docker's memory; leave ~30% for the voice service, the gateway and headroom.
            let budget = Int64(Double(memory) * modelBudgetShare)
            let preferred = category == .chat ? "chat-qwen3-4b" : "code-qwen2.5-7b"
            if let pick = choice(id: preferred), requiredBytes(pick) <= budget { return upgrade(from: pick, budget: budget) }
            return options.filter { $0.kind != .none && requiredBytes($0) <= budget }.max { $0.sizeBytes < $1.sizeBytes }
                ?? options.first { $0.kind == .none } ?? options.min { $0.sizeBytes < $1.sizeBytes }!
        }
    }

    /// On big Macs, step up from the default to a stronger model that still fits the budget.
    private static func upgrade(from pick: ModelChoice, budget: Int64) -> ModelChoice {
        guard budget >= 24 * gb else { return pick }
        let stronger = options(for: pick.category).filter { $0.kind != .none && $0.sizeBytes > pick.sizeBytes && requiredBytes($0) <= budget }
        // Prefer the 14B tier on 24 GB+ budgets rather than jumping straight to 30B.
        return stronger.filter { $0.sizeBytes < 10 * gb }.max { $0.sizeBytes < $1.sizeBytes } ?? pick
    }
}
