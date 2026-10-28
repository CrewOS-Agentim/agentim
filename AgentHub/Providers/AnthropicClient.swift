import Foundation

/// Claude Messages API with streaming.
struct AnthropicClient: ChatClient {
    var baseURL: URL
    var apiKey: String

    private struct Body: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        let model: String
        let system: String?
        let messages: [Message]
        let max_tokens: Int
        let stream = true
    }

    private struct Event: Decodable {
        struct Delta: Decodable { let type: String?; let text: String? }
        struct ErrorBody: Decodable { let message: String }
        let type: String
        let delta: Delta?
        let error: ErrorBody?
    }

    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error> {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")

        let messages = request.messages
            .filter { $0.role != .system && !$0.isError }
            .map { Body.Message(role: $0.role.rawValue, content: $0.modelContent) }
        urlRequest.httpBody = try? JSONEncoder().encode(
            Body(model: request.model, system: request.system.isEmpty ? nil : request.system,
                 messages: messages, max_tokens: request.maxTokens))

        return SSE.stream(urlRequest) { data in
            let event = try JSONDecoder().decode(Event.self, from: data)
            if event.type == "error" { throw ChatClientError.http(0, event.error?.message ?? "stream error") }
            return event.type == "content_block_delta" && event.delta?.type == "text_delta" ? event.delta?.text : nil
        }
    }
}
