import Foundation

/// A reusable block of instructions (same idea as a SKILL.md). A skill is
/// injected into the system prompt when an agent has it attached and the
/// message matches one of its triggers, or when the user types `/<name>`.
struct Skill: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var summary: String
    var instructions: String
    var triggers: [String] = []
    /// Attached skills with alwaysOn skip trigger matching.
    var alwaysOn = false

    var slug: String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// True when the message invokes this skill by slash command or trigger word.
    func matches(_ message: String) -> Bool {
        let text = message.lowercased()
        if text.contains("/\(slug)") { return true }
        return triggers.contains { !$0.isEmpty && text.contains($0.lowercased()) }
    }
}

extension Skill {
    /// Parses a SKILL.md style document:
    ///
    ///     ---
    ///     name: release-notes
    ///     description: Write release notes
    ///     triggers: changelog, release notes
    ///     ---
    ///     <instructions>
    static func parse(markdown: String) -> Skill? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var fields: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        guard let name = fields["name"], !name.isEmpty else { return nil }

        let body = lines[(end + 1)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let triggers = (fields["triggers"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Skill(
            name: name, summary: fields["description"] ?? "", instructions: body,
            triggers: triggers, alwaysOn: fields["always"] == "true")
    }

    /// Built-in skills: the same SKILL.md files the gateway ships (bundled from gateway/skills),
    /// plus your private ones from <stack>/private/skills (never part of the open-source repo).
    static let builtIn: [Skill] = {
        let bundled = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: "skills") ?? []
        let privateDir = PrivateContent.folder.appendingPathComponent("skills")
        let privateFiles = ((try? FileManager.default.contentsOfDirectory(at: privateDir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
        var seen = Set<String>()
        return (bundled.sorted { $0.lastPathComponent < $1.lastPathComponent }
                + privateFiles.sorted { $0.lastPathComponent < $1.lastPathComponent })
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .compactMap(parse(markdown:))
            .filter { seen.insert($0.slug).inserted }
    }()

    static let defaults: [Skill] = builtIn + extras

    static let extras: [Skill] = [
        Skill(name: "Code Review", summary: "Review diffs for bugs first, style last",
              instructions: "When reviewing code: list correctness bugs first with file/line, then risks, then optional cleanups. Be specific and brief.",
              triggers: ["review", "diff", "pull request"]),
        Skill(name: "Summarize", summary: "Tight bullet summaries",
              instructions: "Summarize in at most 5 bullets. Lead with the conclusion.",
              triggers: ["summarize", "tl;dr", "tldr"]),
        Skill(name: "Email Writer", summary: "Short emails that lead with the ask",
              instructions: "Write emails that lead with the ask, keep to a few short paragraphs, and end with clear next steps.",
              triggers: ["email", "reply to"]),
    ]
}
