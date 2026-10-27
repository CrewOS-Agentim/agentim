import Foundation

/// `/chat/completions` streaming. Covers OpenAI, Gemini, OpenRouter, Hugging Face
/// Inference Providers, and remote agents that expose an OpenAI-style endpoint.
struct OpenAICompatibleClient: ChatClient {
    var baseURL: URL
    var apiKey: String?
    /// Remote agents are configured with the full URL instead of a base URL.
    var isFullEndpoint = false

    private struct Body: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let messages: [Message]
        let stream = true
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        let url = isFullEndpoint ? baseURL : baseURL.appendingPathComponent("chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }

        var messages: [Body.Message] = []
        if !request.system.isEmpty { messages.append(.init(role: "system", content: request.system)) }
        messages += request.messages
            .filter { $0.role != .system && !$0.isError }
            .map { Body.Message(role: $0.role.rawValue, content: $0.content) }
        urlRequest.httpBody = try? JSONEncoder().encode(Body(model: request.model, messages: messages))

        return SSE.stream(urlRequest) { data in
            try JSONDecoder().decode(Chunk.self, from: data).choices?.first?.delta?.content
        }
    }
}
