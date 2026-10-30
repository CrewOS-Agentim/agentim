import Foundation

/// One turn sent to a model.
struct ChatRequest {
    var model: String
    var system: String
    var messages: [ChatMessage]
    var maxTokens = 4_096
    /// The model can see images: attached images go as images, not just their names.
    var sendImages = false

    /// How many recent messages with images send them (older ones are named only, to keep requests small).
    static let imageMessages = 3

    /// The messages whose images are sent with this request.
    var imageMessageIDs: Set<UUID> {
        guard sendImages else { return [] }
        return Set(messages.filter { !$0.images.isEmpty }.suffix(Self.imageMessages).map(\.id))
    }

    /// Wire messages for an API: the text, plus base64 JPEG images where they're sent.
    func wireMessages() -> [(role: Role, text: String, images: [String])] {
        let withImages = imageMessageIDs
        return messages.filter { $0.role != .system && !$0.isError }.map { message in
            let images = withImages.contains(message.id) ? message.images.compactMap { $0.imageBase64() } : []
            // If a saved image went missing, the text names it instead of claiming it's attached.
            return (message.role, message.modelContent(withImages: !images.isEmpty), images)
        }
    }
}

/// Anything that can stream a reply: cloud APIs, remote agents, on-device MLX.
protocol ChatClient {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<String, Error>
}

enum ChatClientError: LocalizedError {
    case missingKey(String)
    case http(Int, String)
    case unsupportedOnSimulator
    case modelNotInstalled(String)

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider): "No API key for \(provider). Add one in Settings."
        case .http(let code, let body): "HTTP \(code): \(body.prefix(300))"
        case .unsupportedOnSimulator: "On-device models need Apple silicon (Metal GPU)."
        case .modelNotInstalled(let repo): "\(repo) isn't downloaded yet."
        }
    }
}

/// Minimal Server-Sent Events decoder: yields the payload of each `data:` line.
enum SSE {
    static func payload(fromLine line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return payload.isEmpty || payload == "[DONE]" ? nil : payload
    }

    /// Sends `request` and yields whatever `decode` extracts from each event (nil skips it).
    static func stream<Event>(
        _ request: URLRequest,
        decode: @escaping (Data) throws -> Event?
    ) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw ChatClientError.http(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        guard let payload = payload(fromLine: line),
                              let event = try decode(Data(payload.utf8))
                        else { continue }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
