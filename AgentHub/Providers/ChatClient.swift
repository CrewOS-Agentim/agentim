import Foundation

/// One turn sent to a model.
struct ChatRequest {
    var model: String
    var system: String
    var messages: [ChatMessage]
    var maxTokens = 4_096
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
        case .unsupportedOnSimulator: "On-device models need a real iPhone or iPad (Metal GPU). Use a cloud model in the simulator."
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
