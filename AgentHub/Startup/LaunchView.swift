import AppKit
import SwiftUI

// MARK: - Launch: design → build → test → deploy → live

/// How a startup ships: where the code lives, the stack, how to test it and where it deploys.
struct LaunchConfig: Codable, Equatable {
    var folder = ""
    var stack = ""
    var deploy = "none"
    var deploy_command = ""
    var test_command = ""
    var live_url = ""
    var team_reviews = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        stack = try c.decodeIfPresent(String.self, forKey: .stack) ?? ""
        deploy = try c.decodeIfPresent(String.self, forKey: .deploy) ?? "none"
        deploy_command = try c.decodeIfPresent(String.self, forKey: .deploy_command) ?? ""
        test_command = try c.decodeIfPresent(String.self, forKey: .test_command) ?? ""
        live_url = try c.decodeIfPresent(String.self, forKey: .live_url) ?? ""
        team_reviews = try c.decodeIfPresent(Bool.self, forKey: .team_reviews) ?? true
    }

    var json: [String: Any] {
        ["folder": folder, "stack": stack, "deploy": deploy, "deploy_command": deploy_command,
         "test_command": test_command, "live_url": live_url, "team_reviews": team_reviews]
    }
}

struct LaunchStage: Decodable, Equatable, Identifiable {
    let stage: String
    let status: String     // idle | running | waiting | done | failed | skipped
    var output: String? = nil
    var changed: String? = nil
    var url: String? = nil
    var at: Double? = nil
    var id: String { stage }

    var title: String {
        ["design": "Design", "build": "Build", "test": "Test", "deploy": "Deploy", "live": "Live"][stage] ?? stage.capitalized
    }

    var symbol: String {
        ["design": "pencil.and.ruler", "build": "hammer", "test": "checkmark.seal", "deploy": "paperplane",
         "live": "globe"][stage] ?? "circle"
    }

    var blurb: String {
        switch stage {
        case "design": "Claude Code designs v1 from the plan: screens, look, data, stack. Read-only."
        case "build": "Claude Code writes the code in the project folder, then the tests run (one automatic fix)."
        case "test": "Runs your test command in the project folder."
        case "deploy": "Runs your deploy command with your own CLI login, then checks the live URL."
        default: "Checks that the live URL answers."
        }
    }

    var color: Color {
        switch status {
        case "done": .green
        case "running": .accentColor
        case "waiting": .orange
        case "failed": .red
        default: .secondary
        }
    }

    var statusText: String {
        switch status {
        case "idle": "Not started"
        case "waiting": "Ready"
        default: status.capitalized
        }
    }
}

/// Launch mode's progress: everyone in parallel, then the build, then a wrap-up meeting.
struct SprintState: Decodable, Equatable {
    let status: String   // running | done | failed
    var output: String? = nil
    var started: Double? = nil
    var seconds: Double? = nil
}

struct DeployProvider: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let command: String
}

extension StartupClient {
    func configureLaunch(_ id: String, _ config: LaunchConfig) async throws -> StartupDetail {
        try await sendDetail("v1/startups/\(id)/config", body: config.json)
    }

    func sprint(_ id: String) async throws {
        try await post("v1/startups/\(id)/sprint", body: ["confirmed": true])
    }

    func launch(_ id: String, stage: String, confirmed: Bool) async throws {
        try await post("v1/startups/\(id)/launch", body: ["stage": stage, "confirmed": confirmed])
    }
}

extension StartupModel {
    /// Build and deploy change code or the outside world: they're confirmed in a dialog first.
    static let confirmedStages: Set<String> = ["build", "deploy"]

    func editLaunch() { launchDraft = detail?.config ?? LaunchConfig() }

    func saveLaunch(stackRoot: URL?) async {
        guard let id = detail?.id, let draft = launchDraft else { return }
        if !draft.folder.isEmpty { Self.allowWorkspace(URL(fileURLWithPath: draft.folder), stackRoot: stackRoot) }
        if isDemo { detail?.config = draft; launchDraft = nil; return }
        await act("Saving the launch settings…", stackRoot) { client in
            self.detail = try await client.configureLaunch(id, draft)
            self.launchDraft = nil
        }
    }

    func chooseLaunchFolder(stackRoot: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder this startup's code lives in (or a new empty one)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Self.allowWorkspace(url, stackRoot: stackRoot)
        launchDraft?.folder = url.path
    }

    /// Launch mode (confirmed in its dialog): design + every employee's launch deliverable in parallel, then the build.
    func runSprint(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        confirmingSprint = false
        meetingRequested = true
        await act("Starting launch mode…", stackRoot) { client in try await client.sprint(id) }
    }

    func runStage(_ stage: String, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        confirmingStage = nil
        meetingRequested = true
        // The button press (and for build/deploy, the dialog) is the founder's confirmation.
        await act("Starting \(stage)…", stackRoot) { client in try await client.launch(id, stage: stage, confirmed: true) }
    }
}

/// The Launch tab: settings, then the five stages with their buttons and output.
struct LaunchPanel: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?

    private var stages: [LaunchStage] {
        detail.pipeline ?? ["design", "build", "test", "deploy", "live"].map { LaunchStage(stage: $0, status: "idle") }
    }
    private var config: LaunchConfig { detail.config ?? LaunchConfig() }
    private var running: Bool { detail.launch_running == true || stages.contains { $0.status == "running" } }
    private var providers: [DeployProvider] { detail.providers ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                sprintCard
                rail
                if model.launchDraft != nil { settingsForm } else { settingsSummary }
                ForEach(stages) { stage in stageCard(stage) }
                Text("agentim never pushes your code. Deploys use your own CLI (vercel, netlify, fly…) and its saved login on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Theme.s4)
        }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { model.confirmingStage != nil },
                                                             set: { if !$0 { model.confirmingStage = nil } }),
                            presenting: model.confirmingStage) { stage in
            Button(stage == "deploy" ? "Deploy" : "Build it") { Task { await model.runStage(stage, stackRoot: stackRoot) } }
        } message: { stage in
            Text(dialogMessage(stage))
        }
    }

    // MARK: Launch mode

    private var sprintCard: some View {
        let sprint = detail.sprint
        return HStack(alignment: .top, spacing: Theme.s3) {
            Image(systemName: "bolt.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Launch mode").font(.headline)
                Group {
                    switch sprint?.status {
                    case "running":
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = Int(context.date.timeIntervalSince1970 - (sprint?.started ?? context.date.timeIntervalSince1970))
                            Text("Everyone is working in parallel… \(elapsed / 60) min \(elapsed % 60) s")
                        }
                    case "done": Text("Done: \(sprint?.output ?? ""). Review the build, then Deploy.")
                    case "failed": Text("Stopped: \(sprint?.output ?? "")").foregroundStyle(.red)
                    default: Text("Every agent at once: Claude Code designs and builds v1 while the team writes the launch kit (landing copy, posts, emails, pricing, tracking). Then a wrap-up meeting. Deploying stays your call.")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if sprint?.status == "running" {
                ProgressView().controlSize(.small)
            } else {
                Button("Launch mode…") { model.confirmingSprint = true }
                    .buttonStyle(.borderedProminent).tint(.orange)
                    .disabled(running || model.busy != nil)
            }
        }
        .padding(Theme.s3)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }

    // MARK: Progress

    private var rail: some View {
        HStack(spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                VStack(spacing: 4) {
                    ZStack {
                        Circle().fill(stage.color.opacity(stage.status == "idle" ? 0.12 : 0.2)).frame(width: 34, height: 34)
                        if stage.status == "running" {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: stage.status == "done" ? "checkmark" : stage.symbol)
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(stage.color)
                        }
                    }
                    Text(stage.title).font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stage.title): \(stage.statusText)")
                if index < stages.count - 1 {
                    Rectangle().fill(stage.status == "done" ? Color.green.opacity(0.5) : Theme.border)
                        .frame(height: 2).frame(maxWidth: 30).padding(.bottom, 18)
                }
            }
        }
        .padding(.vertical, Theme.s2)
    }

    // MARK: Settings

    private var settingsSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Launch settings").font(.headline)
                Spacer()
                Button("Edit", systemImage: "slider.horizontal.3") { model.editLaunch() }
            }
            row("folder", config.folder.isEmpty ? "A new folder is created when you start (or the first linked folder)" : config.folder) {
                if !config.folder.isEmpty {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: config.folder)]) }
                        .buttonStyle(.link)
                }
            }
            row("square.stack.3d.up", config.stack.isEmpty ? "Stack: Claude Code recommends one" : "Stack: \(config.stack)") {}
            row("checkmark.seal", config.test_command.isEmpty ? "Tests: set by the build" : "Tests: \(config.test_command)") {}
            row("paperplane", "Deploy: " + deployDescription) {}
            row("globe", config.live_url.isEmpty ? "Live URL: from the deploy" : config.live_url) {
                if let url = URL(string: config.live_url), !config.live_url.isEmpty { Link("Open", destination: url) }
            }
        }
        .padding(Theme.s3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }

    private var deployDescription: String {
        let name = providers.first { $0.id == config.deploy }?.name ?? (config.deploy == "none" ? "not chosen yet" : config.deploy)
        return config.deploy_command.isEmpty ? name : "\(name) (`\(config.deploy_command)`)"
    }

    private func row<Accessory: View>(_ symbol: String, _ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(text).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            accessory()
        }
    }

    @ViewBuilder private var settingsForm: some View {
        if let draft = Binding($model.launchDraft) {
            VStack(alignment: .leading, spacing: Theme.s2) {
                Text("Launch settings").font(.headline)
                labeled("Project folder") {
                    HStack {
                        TextField("Created for you if empty", text: draft.folder)
                        Button("Choose…") { model.chooseLaunchFolder(stackRoot: stackRoot) }
                    }
                }
                labeled("Stack") { TextField("e.g. Next.js + Tailwind + SQLite (empty: Claude Code picks)", text: draft.stack) }
                labeled("Test command") { TextField("e.g. npm test (empty: the build sets one)", text: draft.test_command) }
                labeled("Deploy to") {
                    Picker("", selection: draft.deploy) {
                        ForEach(providers) { Text($0.name).tag($0.id) }
                        if providers.isEmpty { Text("Not yet").tag("none") }
                    }
                    .labelsHidden()
                }
                labeled("Deploy command") {
                    TextField(providers.first { $0.id == draft.wrappedValue.deploy }?.command.nilIfEmpty ?? "e.g. ./deploy.sh",
                              text: draft.deploy_command)
                }
                labeled("Live URL") { TextField("https://… (empty: taken from the deploy output)", text: draft.live_url) }
                Toggle("The team meets after the design and after going live", isOn: draft.team_reviews)
                HStack {
                    Spacer()
                    Button("Cancel") { model.launchDraft = nil }
                    Button("Save") { Task { await model.saveLaunch(stackRoot: stackRoot) } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(Theme.s3)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.accent))
        }
    }

    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Stages

    private func stageCard(_ stage: LaunchStage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.s2) {
                Image(systemName: stage.symbol).foregroundStyle(stage.color).frame(width: 20)
                Text(stage.title).font(.headline)
                Text(stage.statusText).font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(stage.color.opacity(0.15), in: Capsule()).foregroundStyle(stage.color)
                Spacer()
                action(for: stage)
            }
            Text(stage.blurb).font(.caption).foregroundStyle(.secondary)
            if let url = stage.url, let link = URL(string: url), stage.stage == "live" || stage.stage == "deploy" {
                Link(url, destination: link).font(.callout)
            }
            if let output = stage.output, !output.isEmpty {
                DisclosureGroup(stage.status == "failed" ? "What went wrong" : "Output") {
                    ScrollView {
                        Text(output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                }
                .font(.caption)
            }
        }
        .padding(Theme.s3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(stage.status == "waiting" ? Color.orange.opacity(0.6) : Theme.border))
    }

    @ViewBuilder private func action(for stage: LaunchStage) -> some View {
        let label: String = switch stage.stage {
        case "design": stage.status == "done" ? "Redesign" : "Design it"
        case "build": stage.status == "done" ? "Rebuild…" : "Build it…"
        case "test": "Run tests"
        case "deploy": stage.status == "done" ? "Redeploy…" : "Deploy…"
        default: "Check now"
        }
        let blocked = running || model.busy != nil
            || (stage.stage == "test" && config.test_command.isEmpty)
            || (stage.stage == "deploy" && config.deploy == "none" && config.deploy_command.isEmpty)
            || (stage.stage == "live" && config.live_url.isEmpty)
        Button(label) {
            if StartupModel.confirmedStages.contains(stage.stage) {
                model.confirmingStage = stage.stage
            } else {
                Task { await model.runStage(stage.stage, stackRoot: stackRoot) }
            }
        }
        .buttonStyle(.bordered)
        .tint(stage.status == "waiting" ? .orange : nil)
        .disabled(blocked)
        .help(blocked && stage.stage == "deploy" ? "Choose where to deploy in the launch settings." : stage.blurb)
    }

    private var dialogTitle: String {
        model.confirmingStage == "deploy" ? "Deploy \(detail.name)?" : "Let Claude Code write the code?"
    }

    private func dialogMessage(_ stage: String) -> String {
        if stage == "deploy" {
            let command = config.deploy_command.isEmpty
                ? providers.first { $0.id == config.deploy }?.command ?? "" : config.deploy_command
            return "This runs `\(command)` in \(config.folder.isEmpty ? "the project folder" : config.folder) and puts it live for anyone with the link."
        }
        return "Claude Code will create and edit files in \(config.folder.isEmpty ? "the project folder" : config.folder), then run the tests. It doesn't push or deploy."
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
