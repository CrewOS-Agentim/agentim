import SwiftUI

// MARK: - Work: tasks that start as soon as they're ready, and handoffs between agents

struct WorkTask: Decodable, Equatable, Identifiable {
    let id: String
    let owner: String
    let task: String
    var eta: String? = nil
    let status: String          // todo | doing | done | cancelled
    var depends_on: String? = nil
    var waiting_for: String? = nil
    var from_role: String? = nil
    var output: String? = nil
    var ready: Bool? = nil
    var created: Double? = nil
    var finished: Double? = nil
}

struct WorkBoard: Decodable, Equatable {
    let tasks: [WorkTask]
    let working: [String]
    var started_today: Int? = nil
    var budget: Int? = nil
}

extension StartupClient {
    func board(_ id: String) async throws -> WorkBoard { try await getJSON("v1/startups/\(id)/tasks") }

    func assign(_ id: String, owner: String, task: String) async throws -> WorkBoard {
        try await sendBoard("v1/startups/\(id)/tasks", body: ["owner": owner, "task": task])
    }

    func cancelTask(_ id: String, task: String) async throws -> WorkBoard {
        try await sendBoard("v1/startups/\(id)/tasks", body: ["cancel": task])
    }

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

    func cancelTask(_ task: WorkTask, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act(nil, stackRoot) { client in self.workBoard = try await client.cancelTask(id, task: task.id) }
    }

    func setRhythm(_ rhythm: String, stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        await act(nil, stackRoot) { client in self.detail = try await client.setRhythm(id, rhythm) }
    }
}

/// The Work tab: what's being worked on, what's next, what's waiting for someone else, and what's done.
struct WorkPanel: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?

    private var tasks: [WorkTask] { model.workBoard?.tasks ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                header
                assignRow
                column("Working now", systemImage: "hammer.fill", color: Theme.accent,
                       tasks.filter { $0.status == "doing" }, empty: "Nobody is working right now.")
                column("Up next", systemImage: "arrow.right.circle", color: .orange,
                       tasks.filter { $0.status == "todo" && $0.ready == true }, empty: "Nothing queued.")
                column("Waiting", systemImage: "hourglass", color: .secondary,
                       tasks.filter { $0.status == "todo" && $0.ready != true }, empty: nil)
                column("Done", systemImage: "checkmark.circle.fill", color: .green,
                       Array(tasks.filter { $0.status == "done" }.suffix(12).reversed()), empty: nil)
            }
            .padding(Theme.s4)
        }
        .task(id: detail.id) {
            while !Task.isCancelled {
                await model.loadBoard(stackRoot: stackRoot)
                try? await Task.sleep(for: .seconds(model.workBoard?.working.isEmpty == false ? 3 : 8))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("How the team works").font(.headline)
                Spacer()
                Picker("", selection: Binding(get: { detail.rhythm ?? "events" },
                                              set: { value in Task { await model.setRhythm(value, stackRoot: stackRoot) } })) {
                    Text("Hand off as they finish").tag("events")
                    Text("Meet every \(detail.min_minutes)–\(detail.max_minutes) min").tag("timer")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 380)
            }
            Text((detail.rhythm ?? "events") == "events"
                 ? "Each meeting's action items become tasks. An agent starts as soon as a task is ready, delivers the result, and hands off to whoever continues from it. The team meets again when the board is empty."
                 : "The team meets every \(detail.min_minutes)–\(detail.max_minutes) minutes; tasks you assign here still start right away.")
                .font(.caption).foregroundStyle(.secondary)
            if let started = model.workBoard?.started_today, let budget = model.workBoard?.budget {
                Text("\(started) of \(budget) tasks today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private var assignRow: some View {
        HStack(spacing: Theme.s2) {
            Picker("", selection: $model.taskOwner) {
                Text("Who?").tag("")
                ForEach(detail.team) { person in
                    Text("\(person.emoji) \(person.name.split(separator: " ").first.map(String.init) ?? person.name)")
                        .tag(person.name.split(separator: " ").first.map(String.init) ?? person.name)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            TextField("Give them a task, e.g. write 3 launch posts", text: $model.taskDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.assignTask(stackRoot: stackRoot) } }
            Button("Assign") { Task { await model.assignTask(stackRoot: stackRoot) } }
                .buttonStyle(.borderedProminent)
                .disabled(model.taskOwner.isEmpty || model.taskDraft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private func column(_ title: String, systemImage: String, color: Color, _ items: [WorkTask], empty: String?) -> some View {
        if !items.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(title) · \(items.count)", systemImage: systemImage).font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)
                if items.isEmpty, let empty {
                    Text(empty).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(items) { card($0) }
            }
        }
    }

    private func card(_ task: WorkTask) -> some View {
        let person = detail.person(task.owner)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: Theme.s2) {
                AvatarView(image: Avatars.teamMember(task.owner, startup: detail.id), emoji: person.emoji, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.task).font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(person.name.split(separator: " ").first.map(String.init) ?? person.name)
                            .font(.caption.weight(.semibold))
                        if let from = task.from_role, from != "meeting" {
                            Text(from == "founder" ? "· from you" : "· handed off by \(detail.person(from).name.split(separator: " ").first.map(String.init) ?? from)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let eta = task.eta, !eta.isEmpty, task.status != "done" {
                            Text("· \(eta)").font(.caption).foregroundStyle(.secondary)
                        }
                        if task.status == "doing" { ProgressView().controlSize(.mini) }
                    }
                    if let waiting = task.waiting_for, task.status == "todo", task.ready != true {
                        Label("after: \(waiting)", systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if task.status == "todo" {
                    Button { Task { await model.cancelTask(task, stackRoot: stackRoot) } } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Cancel this task")
                }
            }
            if let output = task.output, !output.isEmpty, task.status == "done" {
                DisclosureGroup("Result") {
                    Text(LocalizedStringKey(output)).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(Theme.s2)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }
}
