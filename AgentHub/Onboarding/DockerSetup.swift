import AppKit
import Foundation
import Observation

/// Gets Docker Desktop onto the Mac and running: detect → download → install → start → ready.
@MainActor
@Observable
final class DockerSetup {
    enum State: Equatable {
        case checking
        case notInstalled
        case downloading(Double)
        case installing
        /// Installed; waiting for the engine (first launch asks the user to accept Docker's terms).
        case starting
        case ready(memoryBytes: Int64)
        case failed(String)
    }

    private(set) var state: State = .checking
    private var startedAt: Date?

    static let appURL = URL(fileURLWithPath: "/Applications/Docker.app")

    static var downloadURL: URL {
        #if arch(arm64)
        URL(string: "https://desktop.docker.com/mac/main/arm64/Docker.dmg")!
        #else
        URL(string: "https://desktop.docker.com/mac/main/amd64/Docker.dmg")!
        #endif
    }

    var isReady: Bool { if case .ready = state { true } else { false } }

    /// Memory Docker can give containers (what models must fit into).
    var memoryBytes: Int64? { if case .ready(let bytes) = state { bytes } else { nil } }

    func markReadyForDemo(memoryBytes: Int64) { state = .ready(memoryBytes: memoryBytes) }

    func check() async {
        if let memory = await Self.engineMemory() {
            state = .ready(memoryBytes: memory)
        } else if FileManager.default.fileExists(atPath: Self.appURL.path) {
            await start()
        } else {
            state = .notInstalled
        }
    }

    /// Downloads Docker Desktop (~550 MB), copies it to /Applications and starts it.
    func install() async {
        state = .downloading(0)
        do {
            var expected: Int64 = 570_000_000
            if let head = try? await URLSession.shared.data(for: { var r = URLRequest(url: Self.downloadURL); r.httpMethod = "HEAD"; return r }()).1,
               head.expectedContentLength > 0 {
                expected = head.expectedContentLength
            }
            let total = expected
            let dmg = try await FileDownloader.download(URLRequest(url: Self.downloadURL)) { written in
                Task { @MainActor in self.state = .downloading(min(1, Double(written) / Double(total))) }
            }
            state = .installing
            try await Self.installApp(fromDMG: dmg)
            try? FileManager.default.removeItem(at: dmg)
            await start()
        } catch {
            state = .failed("Couldn't install Docker: \(error.localizedDescription)")
        }
    }

    /// Opens Docker Desktop and waits (up to 5 minutes) for the engine to answer.
    func start() async {
        state = .starting
        startedAt = Date()
        // If launching fails, the wait below times out with a clear message.
        _ = try? await NSWorkspace.shared.openApplication(at: Self.appURL, configuration: NSWorkspace.OpenConfiguration())
        while Date().timeIntervalSince(startedAt ?? Date()) < 300 {
            if let memory = await Self.engineMemory() {
                state = .ready(memoryBytes: memory)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }
        state = .failed("Docker didn't start. Open Docker Desktop, accept its terms, then press Try again.")
    }

    static func engineMemory() async -> Int64? {
        let result = await Shell.run(["docker", "info", "--format", "{{.MemTotal}}"])
        guard result.ok else { return nil }
        return Int64(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func installApp(fromDMG dmg: URL) async throws {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("agentim-docker-\(UUID().uuidString.prefix(6))")
        let attach = await Shell.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path])
        guard attach.ok else { throw SetupError(attach.output) }
        defer { Task { _ = await Shell.run(["hdiutil", "detach", "-quiet", mount.path]) } }
        let copy = await Shell.run(["ditto", mount.appendingPathComponent("Docker.app").path, appURL.path])
        guard copy.ok else { throw SetupError("Copying Docker.app to Applications failed: \(copy.output)") }
    }
}

struct SetupError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var errorDescription: String? { message }
}

/// The Docker stack (compose file, gateway, runner, deploy scripts) ships inside the app,
/// so a downloaded app works without cloning the repo.
enum StackFiles {
    static var installedRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("agentim/stack", isDirectory: true)
    }

    static var bundled: URL? { Bundle.main.url(forResource: "stack", withExtension: nil) }

    /// The repo checkout when running from source, otherwise the copy in Application Support
    /// (refreshed from the app bundle, keeping the user's .env).
    static func ensureInstalled(repoRoot: URL?) throws -> URL {
        if let repoRoot { return repoRoot }
        guard let bundled else { throw SetupError("This build of agentim doesn't include the Docker stack.") }
        let target = installedRoot
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(atPath: bundled.path) {
            let destination = target.appendingPathComponent(item)
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: bundled.appendingPathComponent(item), to: destination)
        }
        for script in ["install.sh", "uninstall.sh", "watchdog.sh", "power-guard.sh"] {
            try? fm.setAttributes([.posixPermissions: 0o755],
                                  ofItemAtPath: target.appendingPathComponent("deploy/macos/\(script)").path)
        }
        return target
    }
}
