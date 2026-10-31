import Foundation

/// Cuts off a model that stops responding, so the agent can switch to another one: nothing at all within the
/// first-reply timeout, or silence mid-reply longer than the stall timeout.
enum ModelWatchdog {
    struct Limits: Equatable {
        /// Time to the first words (a local model may be loading).
        var firstReply: TimeInterval
        /// Silence allowed once it has started answering.
        var stall: TimeInterval
    }

    enum Timeout: LocalizedError, Equatable {
        case noReply(TimeInterval), stalled(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .noReply(let seconds): "didn't respond in \(Int(seconds)) s"
            case .stalled(let seconds): "stopped responding for \(Int(seconds)) s"
            }
        }
    }

    nonisolated static let defaultFirstReplySeconds = 90
    nonisolated static let defaultStallSeconds = 45

    /// Settings → Models: the timeouts for ordinary chat models.
    nonisolated static var standard: Limits {
        let first = UserDefaults.standard.integer(forKey: "modelFirstReplyTimeout")
        let stall = UserDefaults.standard.integer(forKey: "modelStallTimeout")
        return Limits(firstReply: TimeInterval(first > 0 ? first : defaultFirstReplySeconds),
                      stall: TimeInterval(stall > 0 ? stall : defaultStallSeconds))
    }

    /// The limits for a model: none for renders and coding agents (they work for minutes), more time to start for
    /// answers that arrive all at once (Claude/ChatGPT through your login) or after a load (LoRA on llama-server).
    nonisolated static func limits(for model: AIModel) -> Limits? {
        if model.isMedia || model.capabilities.contains(.agent) { return nil }
        let name = model.modelName.lowercased()
        let base = standard
        if name.hasPrefix("claude/") || name.hasPrefix("chatgpt/") || name.hasPrefix("lora/") {
            return Limits(firstReply: max(base.firstReply, 240), stall: max(base.stall, 240))
        }
        return base
    }

    /// Streams `stream` into `onChunk`, throwing `Timeout` when the model goes quiet for too long (which cancels it).
    static func watch(_ stream: AsyncThrowingStream<String, Error>, limits: Limits?,
                      onChunk: @escaping @MainActor (String) -> Void) async throws {
        guard let limits else {
            for try await chunk in stream { await onChunk(chunk) }
            return
        }
        let clock = Activity()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await chunk in stream {
                    await clock.tick()
                    await onChunk(chunk)
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    if let timeout = await clock.expired(limits) { throw timeout }
                }
            }
            try await group.next()  // the reply finished, or the watchdog fired
            group.cancelAll()
        }
    }

    private actor Activity {
        private let started = Date()
        private var last: Date?

        func tick() { last = Date() }

        func expired(_ limits: Limits) -> Timeout? {
            if let last {
                return Date().timeIntervalSince(last) > limits.stall ? .stalled(limits.stall) : nil
            }
            return Date().timeIntervalSince(started) > limits.firstReply ? .noReply(limits.firstReply) : nil
        }
    }
}
