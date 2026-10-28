import AppKit
import SwiftUI

/// Cartoon avatars bundled from gateway/config/avatars (made locally with LTX).
enum Avatars {
    static func slug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// An agent's avatar by name ("QA Engineer" → avatars/qa-engineer.png); Agent Tim is the app mascot.
    static func agent(named name: String) -> NSImage? {
        let key = slug(name)
        if key == "agent-tim" { return NSApp.applicationIconImage }
        return image("avatars/\(key)") ?? privateImage(key)
    }

    /// A startup team member's avatar by role key (product, design, pentest, …).
    static func teamMember(_ key: String) -> NSImage? {
        key == "ceo" ? NSApp.applicationIconImage : image("avatars/team/\(key)")
    }

    private static var cache: [String: NSImage] = [:]

    /// Avatars for private agents: <stack>/private/avatars/<slug>.png.
    private static func privateImage(_ key: String) -> NSImage? {
        let url = PrivateContent.folder.appendingPathComponent("avatars/\(key).png")
        if let hit = cache[url.path] { return hit }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache[url.path] = image
        return image
    }

    private static func image(_ path: String) -> NSImage? {
        if let hit = cache[path] { return hit }
        guard let url = Bundle.main.url(forResource: path, withExtension: "png"), let image = NSImage(contentsOf: url)
        else { return nil }
        cache[path] = image
        return image
    }
}

/// A round avatar: the bundled picture when there is one, otherwise the emoji on a soft circle.
struct AvatarView: View {
    let image: NSImage?
    let emoji: String
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(emoji).font(.system(size: size * 0.55))
                    .frame(width: size, height: size)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

extension AvatarView {
    init(agent: Agent?, size: CGFloat = 36) {
        self.init(image: agent.flatMap { Avatars.agent(named: $0.name) }, emoji: agent?.emoji ?? "💬", size: size)
    }
}

/// Your private skills, agents and avatars: <stack>/private (git-ignored, mounted read-only into the gateway).
enum PrivateContent {
    static var folder: URL {
        let stack = UserDefaults.standard.string(forKey: "stackRoot").map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/agentim/stack")
        return stack.appendingPathComponent("private", isDirectory: true)
    }
}
