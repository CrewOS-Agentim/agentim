import SwiftUI

/// When a model stops responding, the agent switches to another one: how long to wait.
struct ModelTimeoutsSection: View {
    @AppStorage("modelFirstReplyTimeout") private var firstReply = ModelWatchdog.defaultFirstReplySeconds
    @AppStorage("modelStallTimeout") private var stall = ModelWatchdog.defaultStallSeconds

    var body: some View {
        Section {
            Stepper(value: $firstReply, in: 15...600, step: 15) {
                LabeledContent("First words within", value: "\(firstReply) s")
            }
            Stepper(value: $stall, in: 10...600, step: 5) {
                LabeledContent("Silent mid-answer for at most", value: "\(stall) s")
            }
        } header: {
            Text("When a model doesn't respond")
        } footer: {
            Text("The agent switches to the next model and starts the answer over, and the slow model is tried last for 5 minutes. Claude and ChatGPT through your login and LoRA models get at least 4 minutes (they answer all at once or load first); videos, images and coding agents aren't timed.")
        }
    }
}
