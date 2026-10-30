import Foundation

/// `/chat/completions` streaming. Covers OpenAI, Gemini, OpenRouter, Hugging Face
/// Inference Providers, and remote agents that expose an OpenAI-style endpoint.
struct OpenAICompatibleClient: ChatClient {
    var baseURL: URL
    var apiKey: String?
    /// Remote agents are configured with the full URL instead of a base URL.
    var isFullEndpoint = false

    private struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let text: String
            var images: [String] = []

            enum CodingKeys: String, CodingKey { case role, content }
            struct Part: Encodable {
                struct ImageURL: Encodable { let url: String }
                let type: String
                var text: String?
                var image_url: ImageURL?
            }

            /// Plain text, or text + images as content parts (what vision models read).
            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(role, forKey: .role)
                if images.isEmpty {
                    try container.encode(text, forKey: .content)
                } else {
                    let parts = [Part(type: "text", text: text)]
                        + images.map { Part(type: "image_url", image_url: .init(url: "data:image/jpeg;base64,\($0)")) }
                    try container.encode(parts, forKey: .content)
                }
            }
        }
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
        if !request.system.isEmpty { messages.append(.init(role: "system", text: request.system)) }
        messages += request.wireMessages().map { Body.Message(role: $0.role.rawValue, text: $0.text, images: $0.images) }
        urlRequest.httpBody = try? JSONEncoder().encode(Body(model: request.model, messages: messages))

        return SSE.stream(urlRequest) { data in
            try JSONDecoder().decode(Chunk.self, from: data).choices?.first?.delta?.content
        }
    }
}
