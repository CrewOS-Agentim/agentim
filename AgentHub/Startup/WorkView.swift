import SwiftUI

// MARK: - Harness, loops and graphs: goals become task graphs, checked work, gates, memory

struct WorkTask: Decodable, Equatable, Identifiable {
    let id: String
    let owner: String
    let task: String
    var eta: String? = nil
    let status: String          // todo | doing | approval | done | blocked | cancelled
    var depends_on: String? = nil
    var deps: [String]? = nil
    var waiting_for: String? = nil
    var from_role: String? = nil
    var output: String? = nil
    var ready: Bool? = nil
    var created: Double? = nil
    var finished: Double? = nil
    var done_when: String? = nil
    var gate: String? = nil
    var attempts: Int? = nil
    var feedback: String? = nil
    var goal: String? = nil
    var layer: Int? = nil
}

struct WorkBoard: Decodable, Equatable {
    let tasks: [WorkTask]
    let working: [String]
    var started_today: Int? = nil
    var budget: Int? = nil
}

/// What the team knows, outside any one chat: the founder's rules, decisions, facts and lessons.
struct MemoryItem: Decodable, Equatable, Identifiable {
    let id: String
    let kind: String     // rule | decision | fact | lesson
    var role: String? = nil
    let text: String
}

struct AgentModelChoice: Decodable, Equatable, Identifiable {
    let alias: String
    let id: String
    var agent = false
}

/// Is it worth building? Who already solves it, build vs buy, the gap.
struct WorthCheck: Codable, Equatable {
    struct Existing: Codable, Equatable, Hashable { let name: String; let what: String }
    var status: String? = nil     // running | done | failed
    var verdict: String? = nil    // build | buy | build-on-top | stop
    var why: String? = nil
    var existing: [Existing]? = nil
    var gap: String? = nil
    var recommendation: String? = nil
    var source: String? = nil

    var verdictText: String {
        switch verdict {
        case "build": "✅ Worth building"
        case "buy": "🛒 Better to buy or use what exists"
        case "build-on-top": "🧩 Build on top of something that exists"
        case "stop": "🛑 Not worth building"
        default: "Checking…"
        }
    }
}

extension StartupClient {
    func board(_ id: String) async throws -> WorkBoard { try await getJSON("v1/startups/\(id)/tasks") }

    func assign(_ id: String, owner: String, task: String) async throws -> WorkBoard {
        try await sendBoard("v1/startups/\(id)/tasks", body: ["owner": owner, "task": task])
    }

    func taskAction(_ id: String, _ body: [String: Any]) async throws -> WorkBoard {
        try await sendBoard("v1/startups/\(id)/tasks", body: body)
    }

    func setGoal(_ id: String, goal: String) async throws -> WorkBoard {
        try await sendBoard("v1/startups/\(id)/goal", body: ["goal": goal])
    }

    func summarize(_ id: String) async throws { try await post("v1/startups/\(id)/summary", body: [:]) }

    func decide(_ id: String, _ decision: String) async throws -> StartupDetail {
        try await sendDetail("v1/startups/\(id)/decision", body: ["decision": decision])
    }

    func recheck(_ id: String) async throws { try await post("v1/startups/\(id)/check", body: [:]) }

    func addRule(_ id: String, _ text: String) async throws { try await post("v1/startups/\(id)/memory", body: ["text": text]) }

    func forget(_ id: String, _ item: String) async throws { try await post("v1/startups/\(id)/memory", body: ["delete": item]) }

    func setRhythm(_ id: String, _ rhythm: String) async throws -> StartupDetail {
        try await sendDetail("v1/startups/\(id)", body: ["rhythm": rhythm])
    }
}

extension StartupModel {
    func loadBoard(stackRoot: URL?) async {
        guard let id = detail?.id, !isDemo, let client = Self.client(stackRoot: stackRoot) else { return }
        if let board = try? await client.board(id) { workBoard = board }
    }

    func assignTask(stackRoot: URL?) async {
        let text = taskDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = detail?.id, !text.isEmpty, !taskOwner.isEmpty else { return }
        let owner = taskOwner
        taskDraft = ""
        await act(nil, stackRoot) { client in self.workBoard = try await client.assign(id, owner: owner, task: text) }
    }

    func setGoal(stackRoot: URL?) async {
        let goal = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = detail?.id, !goal.isEmpty else { return }
        goalDraft = ""
        await act("Agent Tim is planning…", stackRoot) { client in self.workBoard = try await client.setGoal(id, goal: goal) }
    }

    /// Approve / send back (with a note) / retry (with a hint) / cancel a task.
    func taskAction(_ action: String, _ task: WorkTask, note: String = "", stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        var body: [String: Any] = [action: task.id]
        if action == "reject" { body["note"] = note }
        if action == "retry" { body["hint"] = note }
        await act(nil, stackRoot) { client in self.workBoard = try await client.taskAction(id, body) }
    }

    func cancelTask(_ task: WorkTask, stackRoot: URL?) async { await taskAction("cancel", task, stackRoot: stackRoot) }

    func summarize(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        selectedThread = "room"
        await act("Agent Tim is summarizing…", stackRoot) { client in try await client.summarize(id) }
    }

    func decide(_ decision: String, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act(nil, stackRoot) { client in self.detail = try await client.decide(id, decision) }
    }

    func recheck(stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act("Checking…", stackRoot) { client in try await client.recheck(id) }
    }

    func addRule(stackRoot: URL?) async {
        let text = ruleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = detail?.id, !text.isEmpty else { return }
        ruleDraft = ""
        await act(nil, stackRoot) { client in try await client.addRule(id, text) }
    }

    func forget(_ item: MemoryItem, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act(nil, stackRoot) { client in try await client.forget(id, item.id) }
    }

    func setAutopilot(_ on: Bool, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        var config = detail?.config ?? LaunchConfig()
        config.autopilot = on
        await act(nil, stackRoot) { client in self.detail = try await client.configureLaunch(id, config) }
    }

    func setRhythm(_ rhythm: String, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act(nil, stackRoot) { client in self.detail = try await client.setRhythm(id, rhythm) }
    }
}

/// Under the project's header: is it worth building, and the founder's call.
struct WorthCard: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let check: WorthCheck
    let stackRoot: URL?
    @State private var expanded = false

    private var waiting: Bool { check.status == "done" && detail.config?.decision == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Theme.s2) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tint)
                Text("Worth building?").font(.callout.weight(.semibold))
                if check.status == "running" {
                    ProgressView().controlSize(.small)
                    Text("Checking who already solves this…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(check.verdictText).font(.callout)
                    if let decision = detail.config?.decision {
                        Text(decision == "build" ? "· building" : "· stopped").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if waiting {
                    Button("Stop") { Task { await model.decide("stop", stackRoot: stackRoot) } }
                    Button("Build anyway") { Task { await model.decide("build", stackRoot: stackRoot) } }
                        .buttonStyle(.borderedProminent)
                }
                if check.status != "running" {
                    Button(expanded || waiting ? "Hide" : "Details") { expanded.toggle() }.buttonStyle(.link)
                }
            }
            if (expanded || waiting) && check.status == "done" {
                if let why = check.why, !why.isEmpty { Text(why).font(.callout) }
                if let existing = check.existing, !existing.isEmpty {
                    Text("Already out there").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(existing, id: \.self) { item in
                        Text("• **\(item.name)**: \(item.what)").font(.callout)
                    }
                }
                if let gap = check.gap { Text("**The gap**: \(gap)").font(.callout) }
                if let rec = check.recommendation, !rec.isEmpty { Text("**Recommendation**: \(rec)").font(.callout) }
                HStack {
                    Text("Source: \(check.source ?? "model")").font(.caption).foregroundStyle(.secondary)
                    Button("Check again") { Task { await model.recheck(stackRoot: stackRoot) } }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(waiting ? Color.orange.opacity(0.08) : Theme.surfaceMuted)
    }
}

/// The Graph tab: the goal, its tasks as a graph (columns by dependency), checks and gates, memory, autopilot.
struct WorkPanel: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?
    @State private var notes: [String: String] = [:]
    @State private var confirmingAutopilot = false

    private var tasks: [WorkTask] { (model.workBoard?.tasks ?? []).filter { $0.status != "cancelled" } }
    private var currentGoal: String? { tasks.last(where: { $0.goal != nil && !($0.goal ?? "").isEmpty })?.goal }
    private var goalTasks: [WorkTask] { currentGoal.map { goal in tasks.filter { $0.goal == goal } } ?? tasks }
    private var needsYou: [WorkTask] { tasks.filter { $0.status == "approval" || $0.status == "blocked" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                goalRow
                if !needsYou.isEmpty { section("Needs you", "hand.raised.fill", .orange) { ForEach(needsYou) { card($0) } } }
                if let goal = currentGoal {
                    Text("Goal: \(goal)").font(.headline)
                }
                graph
                memory
                settings
            }
            .padding(Theme.s4)
        }
        .task(id: detail.id) {
            while !Task.isCancelled {
                await model.loadBoard(stackRoot: stackRoot)
                try? await Task.sleep(for: .seconds(model.workBoard?.working.isEmpty == false ? 3 : 8))
            }
        }
        .confirmationDialog("Turn on autopilot?", isPresented: $confirmingAutopilot) {
            Button("Turn on autopilot") { Task { await model.setAutopilot(true, stackRoot: stackRoot) } }
        } message: {
            Text("The team keeps going, goal after goal, until the project is developed. Claude Code may create and change code in the project folder (each change is tested and saved as a version). Deploys, public posts, emails to customers and spending still wait for you.")
        }
    }

    private var goalRow: some View {
        HStack(spacing: Theme.s2) {
            TextField("Set a goal, e.g. \"Get 10 pilot customers\" (Agent Tim plans the tasks)", text: $model.goalDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.setGoal(stackRoot: stackRoot) } }
            Button("Plan it") { Task { await model.setGoal(stackRoot: stackRoot) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.goalDraft.trimmingCharacters(in: .whitespaces).isEmpty || model.busy != nil)
        }
    }

    /// Columns by dependency: tasks in a column don't need each other and run in parallel.
    private var graph: some View {
        let layers = Dictionary(grouping: goalTasks.filter { $0.status != "approval" && $0.status != "blocked" }) { $0.layer ?? 0 }
        return ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: Theme.s3) {
                if layers.isEmpty {
                    Text("No tasks yet. Set a goal above.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(layers.keys.sorted(), id: \.self) { layer in
                    VStack(alignment: .leading, spacing: Theme.s2) {
                        Text(layer == 0 ? "Start" : "Then (\(layer))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(layers[layer] ?? []) { card($0).frame(width: 260) }
                    }
                    if layer != layers.keys.max() {
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 30)
                    }
                }
            }
            .padding(.bottom, 6)
        }
    }

    private func card(_ task: WorkTask) -> some View {
        let person = detail.person(task.owner)
        let first = person.name.split(separator: " ").first.map(String.init) ?? person.name
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: Theme.s2) {
                AvatarView(image: Avatars.teamMember(task.owner, startup: detail.id), emoji: person.emoji, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.task).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Text(first).font(.caption.weight(.semibold))
                        Text(statusText(task)).font(.caption).foregroundStyle(statusColor(task))
                        if task.status == "doing" { ProgressView().controlSize(.mini) }
                        if let gate = task.gate, gate != "auto" {
                            Text(gate == "founder" ? "🙋 you approve" : gate == "code" ? "💻 code" : "🔍 checked")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let done = task.done_when, !done.isEmpty, task.status != "done" {
                        Text("Done when: \(done)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let waiting = task.waiting_for, task.status == "todo" {
                        Label("after: \(waiting)", systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
                    }
                    if let feedback = task.feedback, !feedback.isEmpty, task.status != "done" {
                        Text("↩︎ \(feedback)").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            if task.status == "approval" || task.status == "blocked" {
                TextField(task.status == "blocked" ? "A hint for the retry (optional)" : "What should change? (to send it back)",
                          text: Binding(get: { notes[task.id] ?? "" }, set: { notes[task.id] = $0 }))
                    .textFieldStyle(.roundedBorder).font(.caption)
                HStack {
                    if task.status == "approval" {
                        Button("Approve") { Task { await model.taskAction("approve", task, stackRoot: stackRoot) } }
                            .buttonStyle(.borderedProminent)
                        Button("Send back") { Task { await model.taskAction("reject", task, note: notes[task.id] ?? "", stackRoot: stackRoot) } }
                    } else {
                        Button("Retry") { Task { await model.taskAction("retry", task, note: notes[task.id] ?? "", stackRoot: stackRoot) } }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Cancel", role: .destructive) { Task { await model.taskAction("cancel", task, stackRoot: stackRoot) } }
                }
                .controlSize(.small)
            }
            if let output = task.output, !output.isEmpty, ["done", "approval", "blocked"].contains(task.status) {
                DisclosureGroup(task.status == "done" ? "Result" : "The result so far") {
                    Text(LocalizedStringKey(output)).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(Theme.s2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .strokeBorder(task.status == "approval" || task.status == "blocked" ? Color.orange.opacity(0.6) : Theme.border))
    }

    private func statusText(_ task: WorkTask) -> String {
        switch task.status {
        case "doing": "working"
        case "done": "done"
        case "approval": "needs your approval"
        case "blocked": "blocked after \(task.attempts ?? 0) tries"
        default: task.ready == true ? ((task.attempts ?? 0) > 0 ? "retrying" : "up next") : "waiting"
        }
    }

    private func statusColor(_ task: WorkTask) -> Color {
        switch task.status {
        case "done": .green
        case "doing": Theme.accent
        case "approval", "blocked": .orange
        default: .secondary
        }
    }

    private var memory: some View {
        let items = detail.memory ?? []
        return section("Team memory", "brain", .purple) {
            Text("Everything here goes into every agent's brief: your rules, the decisions, and lessons from failed checks.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Add a rule, e.g. \"Never promise features we haven't built\"", text: $model.ruleDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.addRule(stackRoot: stackRoot) } }
                Button("Add") { Task { await model.addRule(stackRoot: stackRoot) } }
                    .disabled(model.ruleDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ForEach(items.reversed().prefix(20)) { item in
                HStack(alignment: .top) {
                    Text(item.kind == "rule" ? "📌" : item.kind == "lesson" ? "🎓" : "✔︎")
                    Text(item.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { Task { await model.forget(item, stackRoot: stackRoot) } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Forget this")
                }
            }
        }
    }

    private var settings: some View {
        section("How the team works", "gearshape", .secondary) {
            Toggle(isOn: Binding(get: { detail.config?.autopilot ?? false },
                                 set: { on in if on { confirmingAutopilot = true } else { Task { await model.setAutopilot(false, stackRoot: stackRoot) } } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Autopilot: keep working until it's developed").font(.callout.weight(.semibold))
                    Text("Goal after goal; Claude Code builds and the tests check it. Deploys and anything public still wait for you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Picker("Rhythm", selection: Binding(get: { detail.rhythm ?? "graph" },
                                                set: { value in Task { await model.setRhythm(value, stackRoot: stackRoot) } })) {
                Text("Goals → graph (one meeting)").tag("graph")
                Text("Meetings → handoffs").tag("events")
                Text("Meet every \(detail.min_minutes)–\(detail.max_minutes) min").tag("timer")
            }
            if let started = model.workBoard?.started_today, let budget = model.workBoard?.budget {
                Text("\(started) of \(budget) tasks today").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: Theme.s2) {
                Picker("", selection: $model.taskOwner) {
                    Text("Who?").tag("")
                    ForEach(detail.team) { person in
                        let name = person.name.split(separator: " ").first.map(String.init) ?? person.name
                        Text("\(person.emoji) \(name)").tag(name)
                    }
                }
                .labelsHidden().frame(width: 130)
                TextField("Or give one person a task", text: $model.taskDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.assignTask(stackRoot: stackRoot) } }
                Button("Assign") { Task { await model.assignTask(stackRoot: stackRoot) } }
                    .disabled(model.taskOwner.isEmpty || model.taskDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func section<Content: View>(_ title: String, _ symbol: String, _ color: Color,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            content()
        }
        .padding(Theme.s3)
        .background(Theme.surfaceMuted, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}
