import Foundation

/// Runs command-line tools (docker, pmset, launchctl) the way a Terminal would find them.
enum Shell {
    struct Result {
        var status: Int32
        var output: String
        var ok: Bool { status == 0 }
    }

    static let searchPath = [
        "/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ].joined(separator: ":")

    static func run(_ arguments: [String], in directory: URL? = nil) async -> Result {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = searchPath
            process.environment = environment
            // Output goes to a temp file, not a pipe: a pipe holds ~64 KB, and a chatty command
            // (docker pulling gigabytes) would block writing to it while we wait for it to exit.
            let log = FileManager.default.temporaryDirectory.appendingPathComponent("agentim-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            guard let handle = try? FileHandle(forWritingTo: log) else {
                return continuation.resume(returning: Result(status: -1, output: "couldn't create a log file"))
            }
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { finished in
                try? handle.close()
                let data = (try? Data(contentsOf: log)) ?? Data()
                try? FileManager.default.removeItem(at: log)
                continuation.resume(returning: Result(status: finished.terminationStatus,
                                                      output: String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                try? handle.close()
                try? FileManager.default.removeItem(at: log)
                continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
            }
        }
    }

    /// Opens Terminal and runs `command` there (for steps that need your password, like sudo).
    static func runInTerminal(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\" to activate\ntell application \"Terminal\" to do script \"\(escaped)\""
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }
}
