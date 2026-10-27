import Foundation

/// Talks to a LocalServer: the agentim runner's management API, or the
/// `/models` list of a plain OpenAI-compatible server.
struct RunnerClient {
    var server: LocalServer
    var token: String?

    struct System: Decodable, Equatable {
        struct Memory: Decodable, Equatable {
            let total_bytes: Int64
            let available_bytes: Int64
            let ceiling_bytes: Int64
        }
        struct Backend: Decodable, Equatable {
            let url: String
            let healthy: Bool
        }
        struct GPU: Decodable, Equatable {
            let name: String
            let memory_bytes: Int64?
        }
        let hostname: String
        let os: String
        let version: String
        let in_container: Bool
        let memory: Memory
        let gpus: [GPU]
        let backends: [String: Backend]
        let ltx: Bool
    }

    struct Check: Decodable, Equatable {
        let verdict: String
        let can_pull: Bool
        let weight_bytes: Int64
        let required_bytes: Int64
        let available_bytes: Int64
        let ceiling_bytes: Int64
        let free_disk_bytes: Int64
        let fits_gpu: Bool?

        var assessment: MemoryAssessment {
            let verdict: MemoryAssessment.Verdict = switch self.verdict {
            case "fits": .fits
            case "tight": .tight
            case "not_enough_disk": .notEnoughDisk
            default: .tooLarge
            }
            return MemoryAssessment(
                verdict: verdict, requiredBytes: required_bytes, availableBytes: available_bytes,
                deviceBytes: ceiling_bytes, freeDiskBytes: free_disk_bytes, hostLabel: "this computer")
        }
    }

    struct PullProgress: Decodable {
        let status: String?
        let total: Int64?
        let completed: Int64?
        let error: String?
    }

    private struct ModelList: Decodable { let data: [ServerModelInfo] }
    private struct ErrorBody: Decodable {
        struct Inner: Decodable { let message: String }
        let error: Inner
    }

    func system() async throws -> System {
        try await send("v1/system", as: System.self)
    }

    func models() async throws -> [ServerModelInfo] {
        let path = server.kind == .runner ? "v1/models" : "models"
        return try await send(path, as: ModelList.self).data
    }

    func check(_ model: String, hfToken: String?) async throws -> Check {
        try await send("v1/models/check", body: ["model": model, "hf_token": hfToken ?? ""], as: Check.self)
    }

    func delete(_ modelID: String) async throws {
        _ = try await data(request("v1/models/\(modelID)", method: "DELETE"))
    }

    /// Streams Ollama pull progress. The runner refuses (409) models that don't fit.
    func pull(_ model: String, hfToken: String?) -> AsyncThrowingStream<PullProgress, Error> {
        var urlRequest = request("v1/models/pull", method: "POST")
        urlRequest.httpBody = try? JSONEncoder().encode(["model": model, "hf_token": hfToken ?? ""])
        urlRequest.timeoutInterval = 3_600
        return SSE.stream(urlRequest) { try JSONDecoder().decode(PullProgress.self, from: $0) }
    }

    // MARK: - Plumbing

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        let base = server.kind == .runner ? server.baseURL : server.openAIBaseURL
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        return request
    }

    private func send<T: Decodable>(_ path: String, body: [String: String]? = nil, as type: T.Type) async throws -> T {
        var urlRequest = request(path, method: body == nil ? "GET" : "POST")
        if let body { urlRequest.httpBody = try JSONEncoder().encode(body) }
        return try JSONDecoder().decode(T.self, from: try await data(urlRequest))
    }

    private func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error.message
            throw ChatClientError.http(http.statusCode, message ?? String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
