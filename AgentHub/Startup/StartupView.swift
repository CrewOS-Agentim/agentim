import SwiftUI

/// Startup Mode: your startups, each run by a team of agents who act like real employees.
struct StartupView: View {
    @Environment(HostController.self) private var host
    @Bindable var model: StartupModel

    var body: some View {
        HSplitView {
            StartupList(model: model, stackRoot: host.stackRoot)
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            Group {
                if model.composing || (model.listing?.startups.isEmpty ?? false) && model.detail == nil {
                    NewStartup(model: model, team: model.listing?.team ?? StartupModel.demoTeam, stackRoot: host.stackRoot)
                } else if let detail = model.detail, detail.isInterview {
                    Interview(model: model, detail: detail, stackRoot: host.stackRoot)
                } else if let detail = model.detail {
                    RunningStartup(model: model, detail: detail, stackRoot: host.stackRoot)
                } else {
                    ContentUnavailableView("Pick a startup", systemImage: "lightbulb",
                                           description: Text(model.error ?? "Or pitch a new one."))
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Startups")
        .sheet(isPresented: $model.editingTeam) {
            TeamEditor(model: model, presets: model.detail?.presets ?? StartupModel.demoPresets, stackRoot: host.stackRoot)
        }
        .onAppear { model.startPolling(stackRoot: host.stackRoot) }
        .task {
            // `-demo YES -editTeam YES` opens the team editor once the window is up (screenshots).
            guard model.isDemo, UserDefaults.standard.bool(forKey: "editTeam") else { return }
            try? await Task.sleep(for: .seconds(1))
            model.beginTeamEdit()
            model.hire(StartupModel.demoPresets.first)
        }
        .onDisappear { model.stopPolling() }
    }
}

private struct StartupList: View {
    @Bindable var model: StartupModel
    let stackRoot: URL?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selection }, set: { id in Task { await model.select(id, stackRoot: stackRoot) } })) {
                ForEach(model.listing?.startups ?? []) { startup in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(startup.name).font(.headline).lineLimit(1)
                            Spacer()
                            StatusBadge(status: startup.status)
                        }
                        Text(startup.pitch).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if startup.rounds > 0 {
                            Text("\(startup.rounds) meetings").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(startup.id)
                }
            }
            Divider()
            Button { model.newStartup() } label: {
                Label("New startup", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
    }
}

private struct StatusBadge: View {
    let status: String

    var body: some View {
        let (label, color): (String, Color) = switch status {
        case "running": ("Running", .green)
        case "interview": ("Interview", .orange)
        default: ("Paused", .secondary)
        }
        Text(label).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

// MARK: - New startup: the pitch

private struct NewStartup: View {
    @Bindable var model: StartupModel
    let team: [StartupPerson]
    let stackRoot: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("🚀").font(.system(size: 56))
                Text("Pitch me your startup").font(.system(size: 34, weight: .bold))
                Text("I'll ask a few follow-up questions, then hire a team that works on it every 10–30 minutes, like a real company.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 600)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(team) { person in
                        VStack(spacing: 2) {
                            Text(person.emoji).font(.title2)
                            Text(person.name).font(.caption.weight(.semibold))
                            Text(person.title).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 74)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .frame(maxWidth: 600)

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Name (optional)", text: $model.draftName).textFieldStyle(.roundedBorder)
                    Text("The pitch").font(.headline)
                    TextEditor(text: $model.draftPitch)
                        .frame(height: 120).padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    Text("What it is, who it's for, and why now. Two or three sentences is plenty.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Stepper("Meet every \(model.minMinutes)", value: $model.minMinutes, in: 5...model.maxMinutes)
                        Stepper("to \(model.maxMinutes) min", value: $model.maxMinutes, in: model.minMinutes...240)
                    }
                    .font(.callout)
                }
                .frame(maxWidth: 600)

                Button {
                    Task { await model.submitPitch(stackRoot: stackRoot) }
                } label: {
                    if let busy = model.busy { Label(busy, systemImage: "hourglass") } else { Label("Pitch it", systemImage: "paperplane.fill") }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.draftPitch.trimmingCharacters(in: .whitespacesAndNewlines).count < 10 || model.busy != nil)
                if let error = model.error { Text(error).foregroundStyle(.orange).font(.callout) }
            }
            .padding(36)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Interview: Tim's follow-up questions

private struct Interview: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Text("🐙").font(.system(size: 40))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A few questions about \(detail.name)").font(.title2.bold())
                        Text("So the team starts from what you know, not guesses.").foregroundStyle(.secondary)
                    }
                }
                Text(detail.pitch).font(.callout).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                ForEach(Array(detail.questions.enumerated()), id: \.offset) { index, question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(index + 1). \(question)").font(.headline)
                        TextField("Your answer", text: answerBinding(index), axis: .vertical)
                            .lineLimit(2...5).textFieldStyle(.roundedBorder)
                    }
                }
                HStack {
                    Button("Skip questions") { Task { await model.skipQuestions(stackRoot: stackRoot) } }
                    Button("Edit the team", systemImage: "person.2.badge.gearshape") { model.beginTeamEdit() }
                    Spacer()
                    Button {
                        Task { await model.submitAnswers(stackRoot: stackRoot) }
                    } label: {
                        Label(model.busy ?? "Hire the team", systemImage: "person.3.fill")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(model.busy != nil || model.draftAnswers.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
                }
                if let error = model.error { Text(error).foregroundStyle(.orange).font(.callout) }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if model.draftAnswers.count != detail.questions.count {
                model.draftAnswers = Array(repeating: "", count: detail.questions.count)
            }
        }
    }

    private func answerBinding(_ index: Int) -> Binding<String> {
        Binding(get: { index < model.draftAnswers.count ? model.draftAnswers[index] : "" },
                set: { value in
                    if index < model.draftAnswers.count { model.draftAnswers[index] = value }
                })
    }
}

// MARK: - A running startup: plan + team room

private struct RunningStartup: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("The plan", systemImage: "doc.text.fill").font(.headline).foregroundStyle(.tint)
                        PlanText(markdown: detail.plan)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 300, idealWidth: 400)
                TeamRoom(detail: detail).frame(minWidth: 360)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(detail.name).font(.title2.bold())
                    StatusBadge(status: detail.status)
                }
                Text(detail.pitch).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 14) {
                    Label("\(detail.rounds) meetings", systemImage: "arrow.triangle.2.circlepath")
                    if let minutes = detail.minutesToNext {
                        Label(minutes == 0 ? "Meeting now…" : "Next meeting in \(minutes) min", systemImage: "clock")
                    }
                    Label("Every \(detail.min_minutes)–\(detail.max_minutes) min", systemImage: "shuffle")
                }
                .font(.callout).foregroundStyle(.secondary)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Button("Team", systemImage: "person.2.badge.gearshape") { model.beginTeamEdit() }
            Button("Meet now", systemImage: "person.3.fill") { Task { await model.meetNow(stackRoot: stackRoot) } }
                .disabled(model.busy != nil || !detail.isRunning)
            Toggle("On", isOn: Binding(get: { detail.isRunning },
                                       set: { on in Task { await model.setEnabled(on, stackRoot: stackRoot) } }))
                .toggleStyle(.switch)
            Menu {
                Button("Delete startup", role: .destructive) { Task { await model.delete(stackRoot: stackRoot) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(18)
    }
}

/// The plan's markdown: headings, bullets and inline styles.
private struct PlanText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    Text(trimmed.dropFirst(2)).font(.title2.bold()).padding(.bottom, 4)
                } else if trimmed.hasPrefix("## ") {
                    Text(trimmed.dropFirst(3)).font(.headline).padding(.top, 8)
                } else if trimmed.hasPrefix("### ") {
                    Text(trimmed.dropFirst(4)).font(.subheadline.weight(.semibold)).padding(.top, 4)
                } else if !trimmed.isEmpty {
                    Text(LocalizedStringKey(trimmed)).font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}

private struct TeamRoom: View {
    let detail: StartupDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Team room", systemImage: "bubble.left.and.bubble.right.fill").font(.headline).foregroundStyle(.tint)
                .padding([.horizontal, .top], 20).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if detail.messages.isEmpty {
                            Text("The team's first meeting starts in about a minute.").foregroundStyle(.secondary)
                        }
                        ForEach(detail.messages) { message in
                            let person = detail.person(message.role)
                            let isCEO = message.role == "ceo"
                            HStack(alignment: .top, spacing: 10) {
                                Text(person.emoji).font(.title2).frame(width: 38, height: 38)
                                    .background(isCEO ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(person.name).font(.callout.weight(.semibold))
                                        if person.former == true {
                                            Text("former").font(.caption2.weight(.semibold))
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(Color.secondary.opacity(0.15), in: Capsule())
                                        }
                                        Text(person.title).font(.caption).foregroundStyle(.secondary)
                                        Text("· meeting \(message.round)").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    Text(LocalizedStringKey(message.content)).font(.callout).textSelection(.enabled)
                                }
                            }
                            .padding(12)
                            .background(isCEO ? Color.accentColor.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
                .onChange(of: detail.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }
}
