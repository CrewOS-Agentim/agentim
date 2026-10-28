import SwiftUI

/// Startup Mode: describe your idea; a team of agents meets every 10–30 minutes to improve it.
struct StartupView: View {
    @Environment(HostController.self) private var host
    @Bindable var model: StartupModel

    var body: some View {
        Group {
            if let state = model.state, state.configured, state.idea?.isEmpty == false {
                RunningStartup(model: model, state: state, stackRoot: host.stackRoot)
            } else {
                StartupSetup(model: model, team: model.state?.team ?? [], stackRoot: host.stackRoot)
            }
        }
        .navigationTitle("Startup Mode")
        .onAppear { model.startPolling(stackRoot: host.stackRoot) }
        .onDisappear { model.stopPolling() }
    }
}

private struct StartupSetup: View {
    @Bindable var model: StartupModel
    let team: [StartupState.Role]
    let stackRoot: URL?

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                Text("🚀").font(.system(size: 64))
                Text("Startup Mode").font(.system(size: 38, weight: .bold))
                Text("Tell Agent Tim your idea. A team of agents meets every 10–30 minutes, argues, builds on each other's ideas, and keeps a living plan for your startup.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 620)

                if !team.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                        ForEach(team) { role in
                            VStack(spacing: 4) {
                                Text(role.emoji).font(.title)
                                Text(role.name).font(.caption.weight(.semibold)).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 70)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .frame(maxWidth: 620)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Your idea").font(.headline)
                    TextEditor(text: $model.draftIdea)
                        .font(.body)
                        .frame(height: 110)
                        .padding(6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    Text("e.g. \"A monthly subscription that delivers and swaps office plants.\" Who it's for and why helps the team.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Stepper("Meet every \(model.minMinutes)", value: $model.minMinutes, in: 5...model.maxMinutes)
                        Stepper("to \(model.maxMinutes) minutes", value: $model.maxMinutes, in: model.minMinutes...240)
                    }
                    .font(.callout)
                }
                .frame(maxWidth: 620)

                Button {
                    Task { await model.start(stackRoot: stackRoot) }
                } label: {
                    Label("Start Startup Mode", systemImage: "play.fill").frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(model.draftIdea.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)

                if let error = model.error { Text(error).foregroundStyle(.orange).font(.callout) }
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct RunningStartup: View {
    @Bindable var model: StartupModel
    let state: StartupState
    let stackRoot: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("The plan", systemImage: "doc.text.fill").font(.headline).foregroundStyle(.tint)
                        PlanText(markdown: state.plan ?? "")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 320, idealWidth: 420)

                TeamRoom(state: state)
                    .frame(minWidth: 360)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Text("🚀").font(.system(size: 34))
            VStack(alignment: .leading, spacing: 4) {
                Text(state.idea ?? "").font(.title3.weight(.semibold)).lineLimit(2)
                HStack(spacing: 14) {
                    Label("\(state.rounds ?? 0) rounds", systemImage: "arrow.triangle.2.circlepath")
                    if let minutes = state.minutesToNext {
                        Label(minutes == 0 ? "Meeting now…" : "Next meeting in \(minutes) min", systemImage: "clock")
                    } else {
                        Label("Paused", systemImage: "pause.circle")
                    }
                    Label("Every \(state.min_minutes ?? 10)–\(state.max_minutes ?? 30) min", systemImage: "shuffle")
                }
                .font(.callout).foregroundStyle(.secondary)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            Button("Meet now", systemImage: "person.3.fill") { Task { await model.meetNow(stackRoot: stackRoot) } }
                .disabled(model.busy)
            Toggle("On", isOn: Binding(
                get: { model.isRunning },
                set: { on in Task { on ? await model.start(stackRoot: stackRoot) : await model.pause(stackRoot: stackRoot) } }))
                .toggleStyle(.switch)
        }
        .padding(18)
    }
}

/// Renders the plan's markdown (headings as bold lines, bullets, inline styles).
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
    let state: StartupState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Team room", systemImage: "bubble.left.and.bubble.right.fill").font(.headline).foregroundStyle(.tint)
                .padding([.horizontal, .top], 20).padding(.bottom, 10)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if (state.messages ?? []).isEmpty {
                            Text("The team's first meeting starts in about a minute.").foregroundStyle(.secondary)
                        }
                        ForEach(state.messages ?? []) { message in
                            let role = state.role(message.role)
                            HStack(alignment: .top, spacing: 10) {
                                Text(role.emoji).font(.title2)
                                    .frame(width: 38, height: 38)
                                    .background(message.role == "chief" ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                                in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(role.name).font(.callout.weight(.semibold))
                                        Text("Round \(message.round)").font(.caption).foregroundStyle(.secondary)
                                        Text(Date(timeIntervalSince1970: message.ts), style: .relative).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(LocalizedStringKey(message.content)).font(.callout).textSelection(.enabled)
                                }
                            }
                            .padding(12)
                            .background(message.role == "chief" ? Color.accentColor.opacity(0.07) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
                .onChange(of: state.messages?.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }
}
