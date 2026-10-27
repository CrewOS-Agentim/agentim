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
}

struct Conversation: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var agentID: UUID
    var messages: [ChatMessage] = []
    /// Sticky per-conversation override. nil = follow the agent / router.
    var pinnedModelID: String?
    var updatedAt = Date()

    var preview: String {
        messages.last(where: { $0.role != .system })?.content ?? "New conversation"
    }
}
