import AppKit
import UserNotifications

/// macOS notifications: a conversation ended (with a summary), or an agent needs your answer.
/// Only when you're not already looking at that chat; clicking one opens it.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    /// Opens a conversation when its notification is clicked (set by the app).
    var open: ((UUID) -> Void)?

    static var whenDone: Bool {
        UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true
    }
    static var whenNeeded: Bool {
        UserDefaults.standard.object(forKey: "notifyWhenNeeded") as? Bool ?? true
    }

    func setUp() {
        guard !AppStore.isTesting, !AppStore.isDemo else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, conversationID: UUID, needsInput: Bool) {
        guard !AppStore.isTesting, !AppStore.isDemo, needsInput ? Self.whenNeeded : Self.whenDone else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = String(body.prefix(240))
        content.sound = .default
        content.threadIdentifier = conversationID.uuidString
        content.userInfo = ["conversation": conversationID.uuidString]
        if needsInput { content.interruptionLevel = .timeSensitive }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["conversation"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            if let id { self.open?(id) }
        }
        completionHandler()
    }

    /// Shown even while agentim is in front (you may be in another chat).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension AppStore {
    /// You're looking at this chat right now (no notification needed).
    func isWatching(_ conversationID: UUID) -> Bool {
        NSApp?.isActive == true && visibleConversationID == conversationID
    }

    /// A direct chat's reply finished: tell the user if they're elsewhere (a question for them is "needs your answer").
    func replyFinished(_ conversationID: UUID, replyID: UUID) {
        guard !isWatching(conversationID), let conversation = conversations.first(where: { $0.id == conversationID }),
              let reply = conversation.messages.first(where: { $0.id == replyID }), !reply.content.isEmpty, !reply.isError
        else { return }
        let name = agent(for: conversation)?.name ?? "Your agent"
        let asks = Self.asksTheUser(reply.content)
        Notifier.shared.post(title: asks ? "\(name) needs your answer" : "\(name) replied",
                             body: Self.plain(asks ? Self.lastQuestion(reply.content) ?? reply.content : reply.content),
                             conversationID: conversationID, needsInput: asks)
    }

    /// A group discussion ended: a short summary, and whether the members need something from the user.
    func discussionEnded(_ conversationID: UUID) async {
        guard !isWatching(conversationID), let conversation = conversations.first(where: { $0.id == conversationID }) else { return }
        let prompt = """
        Here is a group discussion between the user and their agents:

        \(transcript(conversation, limit: 14))

        Write a 2-sentence summary for the user of where the discussion landed. Then, on its own line, write \
        QUESTION: followed by the one thing the members need the user to answer or decide, or QUESTION: none.
        """
        let reply = (try? await ask(prompt)) ?? ""
        let (summary, question) = Self.splitSummary(reply)
        let fallback = conversation.messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content ?? ""
        let title = conversation.title
        if let question {
            Notifier.shared.post(title: "\(title): the team needs your answer", body: question,
                                 conversationID: conversationID, needsInput: true)
        } else {
            Notifier.shared.post(title: "\(title): discussion finished", body: Self.plain(summary.isEmpty ? fallback : summary),
                                 conversationID: conversationID, needsInput: false)
        }
    }

    /// "summary text\nQUESTION: …" → (summary, question or nil).
    nonisolated static func splitSummary(_ text: String) -> (String, String?) {
        var summary: [String] = []
        var question: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let match = trimmed.firstMatch(of: /^\**QUESTION\**\s*:\s*(.+)$/.ignoresCase()) {
                let value = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "* "))
                question = ["none", "none.", "n/a", "-"].contains(value.lowercased()) ? nil : value
            } else {
                summary.append(trimmed)
            }
        }
        return (summary.joined(separator: " "), question)
    }

    /// Does the reply end by asking the user something?
    nonisolated static func asksTheUser(_ text: String) -> Bool {
        let tail = text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(300)
        return tail.hasSuffix("?") || tail.split(separator: "\n").last?.contains("?") == true
    }

    nonisolated static func lastQuestion(_ text: String) -> String? {
        text.split(separator: "\n").last(where: { $0.contains("?") }).map(String.init)
    }

    /// Markdown → plain text for a notification.
    nonisolated static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
