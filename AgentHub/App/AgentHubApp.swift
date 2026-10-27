import SwiftUI

@main
struct AgentHubApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task {
                    async let account: Void = store.refreshHuggingFaceAccount()
                    async let servers: Void = store.refreshServers()
                    _ = await (account, servers)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { store.saveNow() }
            if phase == .active { Task { await store.refreshServers() } }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ConversationListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
            AgentListView()
                .tabItem { Label("Agents", systemImage: "person.2.badge.gearshape") }
            SkillListView()
                .tabItem { Label("Skills", systemImage: "wand.and.stars") }
            ModelsView()
                .tabItem { Label("Models", systemImage: "cpu") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
