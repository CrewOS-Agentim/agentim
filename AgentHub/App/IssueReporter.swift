import AppKit
import Foundation

/// "Report an issue": opens a new GitHub issue for agentim, prefilled with what helps triage
/// (app and macOS version, chip, memory). Nothing is sent until the user submits it on GitHub.
enum IssueReporter {
    static let repository = URL(string: "https://github.com/CrewOS-Agentim/agentim")!

    enum Kind: String {
        case bug, feature

        var label: String { self == .bug ? "bug" : "enhancement" }
    }

    static func url(kind: Kind = .bug, title: String = "", details: String? = nil,
                    environment: [String: String] = currentEnvironment()) -> URL {
        let system = environment.sorted { $0.key < $1.key }.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
        let body: String
        switch kind {
        case .bug:
            body = """
            ### What happened?
            \(details ?? "")

            ### What did you expect?


            ### Steps to reproduce
            1.

            ### Your Mac
            \(system)
            """
        case .feature:
            body = """
            ### What would you like agentim to do?
            \(details ?? "")

            ### Why does it matter to you?


            ### Your Mac
            \(system)
            """
        }
        var components = URLComponents(url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: kind.label),
        ]
        return components.url!
    }

    static func open(kind: Kind = .bug, title: String = "", details: String? = nil) {
        NSWorkspace.shared.open(url(kind: kind, title: title, details: details))
    }

    static func currentEnvironment() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var chip = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &chip, &size, nil, 0)
        return [
            "agentim": version,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "Chip": String(cString: chip).isEmpty ? "unknown" : String(cString: chip),
            "Memory": ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory),
        ]
    }
}
