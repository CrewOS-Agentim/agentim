import SwiftUI

/// The paid "Cloud models" switch: ChatGPT, Claude and Grok first for performance, when they're connected.
struct CloudModelsSection: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        let paid = store.paidCloudModels
        Section {
            Toggle(isOn: $store.cloudModelsFirst) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cloud models")
                    Text("Paid: ChatGPT, Claude and Grok first, for the best performance").font(.caption).foregroundStyle(.secondary)
                }
            }
            if paid.isEmpty {
                Label("None connected yet. Add an OpenAI, Anthropic or xAI key under Cloud providers, or sign in to Claude or ChatGPT on this Mac.",
                      systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Theme.warning)
            } else {
                LabeledContent("Will use") {
                    Text(paid.map(\.displayName).joined(separator: ", ")).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("On: agents answer with the connected paid models (each still gets the kind it needs: coding, reasoning or writing), even agents set to prefer private models. Messages that look sensitive still stay on your Mac. You pay the provider per use. Off: local models first.")
        }
    }
}
