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
        /// Adapters: the new model's id, sent with the final "success".
        var model: String? = nil
    }

    /// LoRA adapters Hugging Face lists for a base model.
    struct AdapterSearch: Decodable {
        struct Item: Decodable, Identifiable, Hashable {
            let repo: String
            let downloads: Int
            let likes: Int
            let format: String
            var id: String { repo }
        }
        let base_repo: String?
        let adapters: [Item]
    }

    /// What adding an adapter would do: its files, whether it fits the base, the new model's name.
    struct AdapterPlan: Decodable, Equatable {
        let repo: String
        let format: String
        let size_bytes: Int64
        let architecture: String?
        let base_model: String?
        let base: String
        let base_repo: String?
        let base_architecture: String?
        let base_size_bytes: Int64?
        /// true: made for this model · false: made for another one · nil: can't tell.
        let matches: Bool?
        let name: String
        let exists: Bool
        let enough_disk: Bool
        let llama_cpp: Bool?
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

    // MARK: - Codebases (the Mac's own runner: folders, GitHub clones, Claude Code, pull requests)

    struct ProjectContext: Decodable { let context: String }

    struct TaskResult: Decodable {
        let folder: String
        let mode: String
        let output: String
        let files: [FileChange]?
        let repo: String?
        let branch: String?
    }

    struct PullRequest: Decodable {
        let url: String
        let number: Int?
        let repo: String
        let branch: String
        let base: String
        let files: [FileChange]
    }

    /// What agents should know about a codebase: its README, manifests and file tree.
    func projectContext(_ source: [String: String], maxCharacters: Int = 4_000) async throws -> String {
        try await post("v1/projects/context", ["sources": [source], "max_chars": maxCharacters], timeout: 120,
                       as: ProjectContext.self).context
    }

    /// A coding agent works in the codebase: read-only, or editing files when you confirmed "Build it".
    func projectTask(_ source: [String: String], prompt: String, agent: String = "claude-code", edit: Bool) async throws -> TaskResult {
        try await post("v1/projects/task", ["source": source, "prompt": prompt, "agent": agent,
                                            "mode": edit ? "edit" : "read", "confirmed": edit, "timeout": 1_800],
                       timeout: 1_900, as: TaskResult.self)
    }

    /// Branch, commit, push (never forced) and `gh pr create`: confirmed by you in the app.
    func pullRequest(_ source: [String: String], title: String, body: String) async throws -> PullRequest {
        try await post("v1/projects/pr", ["source": source, "title": title, "body": body, "confirmed": true],
                       timeout: 300, as: PullRequest.self)
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], timeout: TimeInterval, as type: T.Type) async throws -> T {
        var urlRequest = request(path, method: "POST")
        urlRequest.timeoutInterval = timeout
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try JSONDecoder().decode(T.self, from: try await data(urlRequest))
    }

    // MARK: - LoRA adapters (the Mac's own runner: llama-server on the GPU)

    func adapterSearch(base: String, hfToken: String?) async throws -> AdapterSearch {
        try await send("v1/adapters/search", body: ["base": base, "hf_token": hfToken ?? ""], as: AdapterSearch.self)
    }

    func adapterCheck(base: String, adapter: String, hfToken: String?) async throws -> AdapterPlan {
        var request = request("v1/adapters/check", method: "POST")
        request.timeoutInterval = 60  // reads the adapter's header on Hugging Face
        request.httpBody = try JSONEncoder().encode(["base": base, "adapter": adapter, "hf_token": hfToken ?? ""])
        return try JSONDecoder().decode(AdapterPlan.self, from: try await data(request))
    }

    /// Streams progress: download, convert if needed, load with the base (the first time downloads it), test.
    func adapterCreate(base: String, adapter: String, hfToken: String?, force: Bool) -> AsyncThrowingStream<PullProgress, Error> {
        var urlRequest = request("v1/adapters/create", method: "POST")
        var body = ["base": base, "adapter": adapter, "hf_token": hfToken ?? ""]
        if force { body["force"] = "1" }
        urlRequest.httpBody = try? JSONEncoder().encode(body)
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
