import Foundation

/// The slice of the Hugging Face Hub API the app needs: account check,
/// model search, and file listings with sizes (for the memory check).
struct HuggingFaceClient {
    var token: String?
    var hubURL = URL(string: "https://huggingface.co")!

    struct Account: Decodable, Equatable {
        let name: String
        let fullname: String?
        let avatarUrl: String?
    }

    struct ModelSummary: Decodable, Identifiable, Hashable {
        let id: String
        let downloads: Int?
        let likes: Int?
        let pipeline_tag: String?
    }

    struct RepoFile: Decodable, Hashable {
        let type: String
        let path: String
        let size: Int64?
    }

    func whoami() async throws -> Account {
        try await get("api/whoami-v2", as: Account.self)
    }

    /// Text-generation models published in MLX format, most downloaded first.
    func searchMLXModels(_ query: String) async throws -> [ModelSummary] {
        var components = URLComponents(url: hubURL.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "search", value: query),
            // `library=mlx` is ignored by the Hub; the tag filter is what works.
            .init(name: "filter", value: "mlx"),
            .init(name: "pipeline_tag", value: "text-generation"),
            .init(name: "sort", value: "downloads"),
            .init(name: "direction", value: "-1"),
            .init(name: "limit", value: "30"),
        ]
        return try await fetch(components.url!, as: [ModelSummary].self)
    }

    func files(repo: String, revision: String = "main") async throws -> [RepoFile] {
        try await get("api/models/\(repo)/tree/\(revision)?recursive=true", as: [RepoFile].self)
            .filter { $0.type == "file" }
    }

    /// Only what MLX needs to load and tokenize: weights, configs, tokenizer, chat template.
    static func runtimeFiles(_ files: [RepoFile]) -> [RepoFile] {
        files.filter { file in
            let name = file.path.lowercased()
            return name.hasSuffix(".safetensors") || name.hasSuffix(".json") || name.hasSuffix(".jinja")
                || name.hasSuffix("tokenizer.model") || name.hasSuffix(".tiktoken") || name.hasSuffix(".txt")
        }
    }

    static func weightBytes(_ files: [RepoFile]) -> Int64 {
        files.filter { $0.path.hasSuffix(".safetensors") }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    func downloadRequest(repo: String, path: String, revision: String = "main") -> URLRequest {
        authorized(URLRequest(url: hubURL.appendingPathComponent("\(repo)/resolve/\(revision)/\(path)")))
    }

    // MARK: - Plumbing

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        // appendingPathComponent would escape the "?" in tree queries.
        try await fetch(URL(string: path, relativeTo: hubURL)!, as: type)
    }

    private func fetch<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: authorized(URLRequest(url: url)))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ChatClientError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        return request
    }
}
