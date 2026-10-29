import Foundation

enum Role: String, Codable {
    case system, user, assistant
}

struct ChatMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    var role: Role
    var content: String
    var createdAt = Date()
    /// Which model answered, and why the router picked it.
    var modelID: String?
    var routingReason: String?
    var isError = false
    /// Files sent with the message (optional so older saved conversations still decode).
    var attachments: [ChatAttachment]?
    /// In a group chat: which agent (or skill) wrote this reply.
    var agentID: UUID?
    var skillID: UUID?

    /// What the model reads: the text plus every attached file.
    var modelContent: String {
        guard let attachments, !attachments.isEmpty else { return content }
        let files = attachments.map(\.promptBlock).joined(separator: "\n\n")
        return content.isEmpty ? files : content + "\n\n" + files
    }
}

struct Conversation: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var agentID: UUID
    var messages: [ChatMessage] = []
    /// Sticky per-conversation override. nil = follow the agent / router.
    var pinnedModelID: String?
    /// A meeting room: these agents all take part (each answers in turn). nil or empty = a normal chat.
    var participantIDs: [UUID]?
    /// Skills that take part in the group chat as their own members ("Web QA", "CFO"…).
    var participantSkillIDs: [UUID]?
    /// Group chats: the model each member thinks with (member id → model id), or one per member automatically.
    var memberModels: [UUID: String]?
    var autoDivideModels: Bool?
    /// How many rounds the members talk to each other after a message (1 = each answers once; 5 = until they agree).
    var discussionRounds: Int?

    var isMeeting: Bool { participantIDs != nil }
    var updatedAt = Date()

    /// Last message as plain text (markdown markers removed) for list rows.
    var preview: String {
        guard let last = messages.last(where: { $0.role != .system }) else { return "New conversation" }
        let content = last.content.isEmpty ? (last.attachments ?? []).map { "📎 \($0.name)" }.joined(separator: " ") : last.content
        return content
            .replacingOccurrences(of: #"\[(video|image)\]\([^)]*\)"#, with: "🎬", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`#>]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
