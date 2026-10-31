import SwiftUI

/// Group chats that work "until it's ready": how long they may keep going before they stop and hand over.
struct DiscussionLimitsSection: View {
    @AppStorage("discussionMaxDisagreements") private var disagreements = AppStore.defaultMaxDisagreements
    @AppStorage("discussionMaxMinutes") private var minutes = AppStore.defaultMaxDiscussionMinutes

    var body: some View {
        Section {
            Stepper(value: $disagreements, in: 1...200) {
                LabeledContent("Up to", value: "\(disagreements) disagreement\(disagreements == 1 ? "" : "s")")
            }
            Stepper(value: $minutes, in: 15...(24 * 60), step: 15) {
                LabeledContent("Or up to", value: AppStore.duration(minutes: minutes))
            }
            if disagreements != AppStore.defaultMaxDisagreements || minutes != AppStore.defaultMaxDiscussionMinutes {
                Button("Back to \(AppStore.defaultMaxDisagreements) disagreements or \(AppStore.duration(minutes: AppStore.defaultMaxDiscussionMinutes))") {
                    disagreements = AppStore.defaultMaxDisagreements
                    minutes = AppStore.defaultMaxDiscussionMinutes
                }
            }
        } header: {
            Text("Group chats: until it's ready")
        } footer: {
            Text("Give a group a task and they keep working until the result is ready and everyone agrees. A disagreement is a round where someone still pushes back. When a limit is reached they stop, and the lead member writes the best version so far and what's still open. Long runs on cloud models cost more.")
        }
    }
}
