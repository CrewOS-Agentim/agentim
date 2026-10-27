import AppKit
import SwiftUI

@main
struct AgentimApp: App {
    @State private var store = AppStore.isDemo ? AppStore.demo() : AppStore()
    @State private var host = HostController(demo: AppStore.isDemo)
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup("agentim", id: "main") {
            RootView()
                .environment(store)
                .environment(host)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    host.startPolling()
                    guard !AppStore.isDemo else { return }
                    async let account: Void = store.refreshHuggingFaceAccount()
                    async let servers: Void = store.refreshServers()
                    _ = await (account, servers)
                }
        }
        .defaultSize(width: 1180, height: 780)
        .onChange(of: scenePhase) { _, phase in
            guard !AppStore.isDemo else { return }
            if phase == .background { store.saveNow() }
            if phase == .active { Task { await store.refreshServers() } }
        }

        MenuBarExtra {
            MenuBarContent().environment(host)
        } label: {
            Image(systemName: host.isHealthy ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.exclamationmark.bubble.right")
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case chats, agents, skills, models, host, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: "Chats"
        case .agents: "Agents"
        case .skills: "Skills"
        case .models: "Models"
        case .host: "This Mac"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .agents: "person.2.badge.gearshape"
        case .skills: "wand.and.stars"
        case .models: "cpu"
        case .host: "desktopcomputer"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    /// `-section models` on launch picks the starting section (used for screenshots).
    @State private var selection: SidebarItem? = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .chats
    @Environment(HostController.self) private var host

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 6) {
                    Circle().fill(host.isHealthy ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(host.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(10)
            }
        } detail: {
            switch selection ?? .chats {
            case .chats: ConversationListView()
            case .agents: AgentListView()
            case .skills: SkillListView()
            case .models: ModelsView()
            case .host: HostView()
            case .settings: SettingsView()
            }
        }
        .onAppear { Snapshots.runIfRequested { selection = $0 } }
    }
}

/// `-demo YES -snapshotDir DIR` saves a PNG of every section and quits. Used for the website;
/// renders the window itself, so it needs no Screen Recording permission.
enum Snapshots {
    @MainActor
    static func runIfRequested(select: @escaping (SidebarItem) -> Void) {
        guard let dir = UserDefaults.standard.string(forKey: "snapshotDir") else { return }
        let shots: [(String, SidebarItem, String?)] = [
            ("chats", .chats, nil), ("chat", .chats, "openChat"), ("agents", .agents, nil),
            ("skills", .skills, nil), ("models", .models, nil), ("host", .host, nil),
        ]
        Task { @MainActor in
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(2))
            for (name, item, flag) in shots {
                UserDefaults.standard.set(flag != nil, forKey: "openChat")
                select(item == .chats ? .agents : .chats)  // force a fresh detail view
                try? await Task.sleep(for: .milliseconds(300))
                select(item)
                try? await Task.sleep(for: .seconds(1.5))
                save(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
            NSApp.terminate(nil)
        }
    }

    @MainActor
    private static func save(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
