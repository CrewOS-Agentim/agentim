import Foundation

/// The code a chat works on: a folder on this Mac, or a GitHub repo (the runner clones it).
struct Codebase: Codable, Hashable {
    enum Kind: String, Codable { case folder, github }

    var kind: Kind
    /// A folder path, or "owner/name".
    var location: String

    var name: String { kind == .github ? location : URL(fileURLWithPath: location).lastPathComponent }
    var symbol: String { kind == .github ? "arrow.triangle.branch" : "folder" }

    /// How the runner names it.
    var source: [String: String] {
        kind == .github ? ["type": "github", "repo": location] : ["type": "dir", "path": location]
    }

    /// "owner/name", a github.com link, or "git@github.com:owner/name.git" → a GitHub codebase.
    static func github(_ text: String) -> Codebase? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:https?://github\.com/|git@github\.com:)?([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$"#
        guard let match = trimmed.range(of: pattern, options: .regularExpression), match == trimmed.startIndex..<trimmed.endIndex,
              let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let owner = Range(found.range(at: 1), in: trimmed), let repo = Range(found.range(at: 2), in: trimmed)
        else { return nil }
        return Codebase(kind: .github, location: "\(trimmed[owner])/\(trimmed[repo])")
    }
}

/// One file a coding agent changed.
struct FileChange: Codable, Hashable, Identifiable {
    var path: String
    /// "modified" or "added".
    var status: String
    var added: Int?
    var removed: Int?

    var id: String { path }
}

/// A coding agent's work in a chat: what it was asked, what it changed, and the pull request once opened.
struct WorkResult: Codable, Hashable {
    enum State: String, Codable { case running, done, failed, openingPullRequest }

    var state: State
    var agentName: String
    var request: String
    var folder: String?
    var repo: String?
    var branch: String?
    var files: [FileChange] = []
    var output: String?
    var error: String?
    var pullRequestURL: String?
    var pullRequestNumber: Int?
    var base: String?

    var linesAdded: Int { files.compactMap(\.added).reduce(0, +) }
    var linesRemoved: Int { files.compactMap(\.removed).reduce(0, +) }

    /// Where a file opens: on GitHub once the branch is pushed, else the file on this Mac.
    func link(for file: FileChange) -> URL? {
        if pullRequestURL != nil, let repo, let branch {
            let path = file.path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            return URL(string: "https://github.com/\(repo)/blob/\(branch)/\(path.joined(separator: "/"))")
        }
        return folder.map { URL(fileURLWithPath: $0).appendingPathComponent(file.path) }
    }

    /// The pull request's "Files changed" tab.
    var pullRequestFilesURL: URL? { pullRequestURL.flatMap { URL(string: $0 + "/files") } }

    /// What the chat (and the next model turn) reads about it.
    var summary: String {
        switch state {
        case .running: return "\(agentName) is working on: \(request)"
        case .failed: return "\(agentName) couldn't finish: \(error ?? "unknown error")"
        case .done, .openingPullRequest:
            let list = files.prefix(12).map { "\($0.path) (+\($0.added ?? 0) −\($0.removed ?? 0))" }.joined(separator: ", ")
            let pr = pullRequestURL.map { "\nPull request #\(pullRequestNumber ?? 0): \($0)" } ?? ""
            return files.isEmpty ? "\(agentName) finished without changing files." + pr
                : "\(agentName) changed \(files.count) file\(files.count == 1 ? "" : "s"): \(list)" + pr
        }
    }
}
