import Foundation
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Runs a downloaded Hugging Face repo on-device with MLX.
struct MLXChatClient: ChatClient {
    var repo: String

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    #if targetEnvironment(simulator)
                    throw ChatClientError.unsupportedOnSimulator
                    #else
                    let container = try await LocalModelCache.shared.container(for: repo)
                    let turns = request.messages.filter { $0.role != .system && !$0.isError }
                    guard let prompt = turns.last, prompt.role == .user else { return continuation.finish() }

                    let history: [Chat.Message] = turns.dropLast().map {
                        $0.role == .user ? .user($0.modelContent) : .assistant($0.modelContent)
                    }
                    let session = ChatSession(
                        container, instructions: request.system.isEmpty ? nil : request.system,
                        history: history, generateParameters: GenerateParameters(maxTokens: request.maxTokens))
                    for try await chunk in session.streamResponse(to: prompt.modelContent) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                    #endif
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Keeps only one model resident: phones can't hold two.
actor LocalModelCache {
    static let shared = LocalModelCache()

    private var loaded: (repo: String, container: ModelContainer)?

    func container(for repo: String) async throws -> ModelContainer {
        if let loaded, loaded.repo == repo { return loaded.container }
        guard LocalModelManager.isInstalled(repo) else { throw ChatClientError.modelNotInstalled(repo) }

        loaded = nil
        let container = try await loadModelContainer(
            from: LocalModelManager.directory(for: repo), using: TransformersTokenizerLoader())
        loaded = (repo, container)
        return container
    }

    func unload() { loaded = nil }
}

/// Bridges swift-transformers' tokenizer to MLXLMCommon (what the
/// `#huggingFaceTokenizerLoader` macro generates, without the macro dependency).
private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(upstream: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
