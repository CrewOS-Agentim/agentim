import Foundation
import Observation

/// Downloads Hugging Face repos to the device after checking they fit in memory.
@MainActor
@Observable
final class LocalModelManager {
    enum DownloadState: Equatable {
        case checking
        case downloading(progress: Double)
        case failed(String)
    }

    struct Candidate: Equatable {
        var repo: String
        var files: [HuggingFaceClient.RepoFile]
        var assessment: MemoryAssessment
    }

    private(set) var downloads: [String: DownloadState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    nonisolated static var modelsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    nonisolated static func directory(for repo: String) -> URL {
        modelsDirectory.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    nonisolated static func isInstalled(_ repo: String) -> Bool {
        FileManager.default.fileExists(atPath: directory(for: repo).appendingPathComponent(".complete").path)
    }

    nonisolated static func diskUsage(_ repo: String) -> Int64 {
        let urls = FileManager.default.enumerator(at: directory(for: repo), includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let url = urls?.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Looks up the repo's file sizes and decides whether this device can run it.
    func inspect(repo: String, token: String?) async throws -> Candidate {
        let client = HuggingFaceClient(token: token)
        let files = HuggingFaceClient.runtimeFiles(try await client.files(repo: repo))
        let weights = HuggingFaceClient.weightBytes(files)
        guard weights > 0 else {
            throw ChatClientError.http(0, "\(repo) has no .safetensors weights, so it isn't an MLX model.")
        }
        return Candidate(repo: repo, files: files, assessment: DeviceMemory.assess(weightBytes: weights))
    }

    /// Starts a download. Refuses anything the memory check says won't fit.
    func download(_ candidate: Candidate, token: String?, onComplete: @escaping (String) -> Void) {
        guard candidate.assessment.canDownload else {
            downloads[candidate.repo] = .failed(candidate.assessment.message)
            return
        }
        let repo = candidate.repo
        downloads[repo] = .downloading(progress: 0)
        tasks[repo] = Task {
            do {
                try await fetch(candidate, token: token)
                downloads[repo] = nil
                onComplete(repo)
            } catch is CancellationError {
                downloads[repo] = nil
            } catch {
                downloads[repo] = .failed(error.localizedDescription)
            }
            tasks[repo] = nil
        }
    }

    func cancel(_ repo: String) {
        tasks[repo]?.cancel()
        try? FileManager.default.removeItem(at: Self.directory(for: repo))
    }

    func delete(_ repo: String) {
        cancel(repo)
        downloads[repo] = nil
    }

    private func fetch(_ candidate: Candidate, token: String?) async throws {
        let client = HuggingFaceClient(token: token)
        let destination = Self.directory(for: candidate.repo)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let total = max(1, candidate.files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var done: Int64 = 0
        for file in candidate.files {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: target.path), let size = file.size,
               Self.size(of: target) == size {
                done += size
                continue
            }
            let base = done
            let repo = candidate.repo
            let temp = try await FileDownloader.download(client.downloadRequest(repo: repo, path: file.path)) { written in
                Task { @MainActor in
                    self.downloads[repo] = .downloading(progress: Double(base + written) / Double(total))
                }
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: temp, to: target)
            done += file.size ?? Self.size(of: target)
            downloads[repo] = .downloading(progress: Double(done) / Double(total))
        }
        FileManager.default.createFile(atPath: destination.appendingPathComponent(".complete").path, contents: nil)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = destination
        try? url.setResourceValues(values)
    }

    private nonisolated static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
    }
}

/// URLSession download with byte-level progress, bridged to async/await.
private final class FileDownloader: NSObject, URLSessionDownloadDelegate {
    private let progress: (Int64) -> Void
    private var continuation: CheckedContinuation<URL, Error>?

    private init(progress: @escaping (Int64) -> Void) {
        self.progress = progress
    }

    static func download(_ request: URLRequest, progress: @escaping (Int64) -> Void) async throws -> URL {
        let delegate = FileDownloader(progress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            continuation?.resume(throwing: ChatClientError.http(http.statusCode, "download failed"))
            continuation = nil
            return
        }
        // The system deletes `location` when this returns, so move it first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        continuation = nil
    }
}
