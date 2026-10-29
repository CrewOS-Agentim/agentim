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
                    guard !AppStore.isDemo, !AppStore.isTesting else { return }
                    async let account: Void = store.refreshHuggingFaceAccount()
                    async let servers: Void = store.refreshServers()
                    _ = await (account, servers)
                    // Start Docker, the models and the local agents if they aren't running, and connect Claude.
                    await host.bringUp(store: store)
                    // Keep the model list current: every 10 s while something's offline, else every minute.
                    while !Task.isCancelled {
                        let offline = store.servers.contains { server in
                            if case .online? = store.serverStatus[server.id] { false } else { true }
                        }
                        try? await Task.sleep(for: .seconds(offline || !store.hasChatModel ? 10 : 60))
                        await store.refreshServers()
                    }
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .help) {
                Button("Report an Issue on GitHub…") { IssueReporter.open(kind: .bug) }
                Button("Suggest a Feature…") { IssueReporter.open(kind: .feature) }
                Button("Share an Idea or Ask a Question…") { IssueReporter.openIdeas() }
            }
        }
        .onChange(of: store.credentialsVersion) {
            // A Claude or ChatGPT key was saved in Settings: the gateway gets it too.
            guard !AppStore.isDemo, !AppStore.isTesting else { return }
            Task { await host.syncCloudKeys(store: store) }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !AppStore.isDemo, !AppStore.isTesting else { return }
            if phase == .background { store.saveNow() }
            if phase == .active { Task { await store.refreshServers() } }
        }

        Window("Logs", id: "logs") {
            LogsView().environment(host)
        }
        .defaultSize(width: 980, height: 620)

        MenuBarExtra {
            MenuBarContent().environment(host)
        } label: {
            Image(systemName: host.isHealthy ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.exclamationmark.bubble.right")
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case chats, startup, agents, skills, models, status, host, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chats: "Chats"
        case .startup: "Startups & Ideas"
        case .agents: "Agents"
        case .skills: "Skills"
        case .models: "Models"
        case .status: "Status"
        case .host: "This Mac"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .chats: "bubble.left.and.bubble.right"
        case .startup: "lightbulb.max.fill"
        case .agents: "person.2.badge.gearshape"
        case .skills: "wand.and.stars"
        case .models: "cpu"
        case .status: "gauge.with.dots.needle.67percent"
        case .host: "desktopcomputer"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    /// `-section models` on launch picks the starting section (used for screenshots).
    @State private var selection: SidebarItem? = SidebarItem(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .chats
    @Environment(HostController.self) private var host
    @Environment(\.openWindow) private var openWindow
    /// First launch shows onboarding; "Run setup again" in This Mac resets this.
    /// `-onboarding YES` forces it (screenshots); demo mode otherwise skips it.
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @State private var onboarding = OnboardingModel(demo: AppStore.isDemo)
    @State private var startup = StartupModel(demo: AppStore.isDemo)
    /// The left nav collapses to an icon rail for more room (⌃⌘S).
    @AppStorage("navCollapsed") private var navCollapsed = false

    private var showOnboarding: Bool {
        if UserDefaults.standard.bool(forKey: "onboarding") { return true }
        return !onboardingComplete && !AppStore.isDemo
    }

    var body: some View {
        if showOnboarding {
            OnboardingView(model: onboarding) {
                onboardingComplete = true
                UserDefaults.standard.removeObject(forKey: "onboarding")
            }
        } else {
            main
        }
    }

    private var main: some View {
        // The status bar sits under the split view, so it never covers a column's bottom buttons.
        VStack(spacing: 0) {
            split
            StatusBar()
        }
        .onAppear {
            Snapshots.runIfRequested { selection = $0 }
            // `-openLogs YES` opens the Logs window (screenshots).
            if UserDefaults.standard.bool(forKey: "openLogs") { openWindow(id: "logs") }
        }
    }

    private var split: some View {
        HStack(spacing: 0) {
            NavRail(selection: $selection, collapsed: $navCollapsed)
            Divider()
            section.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var section: some View {
        switch selection ?? .chats {
        case .chats: ConversationListView()
        case .startup: StartupView(model: startup)
        case .agents: AgentListView()
        case .skills: SkillListView()
        case .models: ModelsView()
        case .status: StatusView()
        case .host: HostView()
        case .settings: SettingsView()
        }
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

/// The app's left navigation: icons and names, or just icons (hover for names) when collapsed.
struct NavRail: View {
    @Binding var selection: SidebarItem?
    @Binding var collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
            } label: {
                Image(systemName: "sidebar.left").font(.system(size: 15))
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("s", modifiers: [.control, .command])
            .help(collapsed ? "Show names (⌃⌘S)" : "Collapse the sidebar (⌃⌘S)")
            .accessibilityLabel(collapsed ? "Expand sidebar" : "Collapse sidebar")
            .padding(.leading, 6).padding(.bottom, 6)

            ForEach(SidebarItem.allCases) { item in
                let isOn = (selection ?? .chats) == item
                Button { selection = item } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 15)).frame(width: 22)
                        if !collapsed { Text(item.title).lineLimit(1) }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).frame(height: 32)
                    .foregroundStyle(isOn ? Color.white : Color.primary)
                    .background(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.title)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .frame(width: collapsed ? 60 : 200, alignment: .leading)
        .background(.regularMaterial)
    }
}
