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
        .sheet(item: $model.pendingDelete) { startup in
            DeleteStartupConfirmation(startup: startup,
                                      onCancel: { model.askToDelete(nil) },
                                      onDelete: { Task { await model.confirmDelete(stackRoot: host.stackRoot) } })
        }
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
                    .contextMenu {
                        Button("Delete \(startup.name)…", systemImage: "trash", role: .destructive) { model.askToDelete(startup) }
                    }
                }
            }
            .onDeleteCommand { model.askToDelete(model.selectedSummary) }
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
                TimAvatar(size: 84)
                Text("Pitch me your startup").headlineStyle(34)
                Text("I'll ask a few follow-up questions, then put a team of agents on it. They work every 10–30 minutes, like a real company.")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 600)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 10) {
                    ForEach(team) { person in
                        VStack(spacing: 2) {
                            AvatarView(image: Avatars.teamMember(person.key), emoji: person.emoji, size: 40)
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
    @State private var answerHeight: CGFloat = 120
    @State private var forward = true

    private var index: Int { min(model.questionIndex, max(detail.questions.count - 1, 0)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s6) {
                    header
                    if !detail.questions.isEmpty { questionCard }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning).font(.callout)
                    }
                }
                .padding(Theme.s8)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            Divider()
            controls
        }
        .onAppear { model.prepareInterview() }
        .onChange(of: detail.id) { model.prepareInterview() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            HStack(spacing: Theme.s3) {
                TimAvatar(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A few questions about \(detail.name)").headlineStyle(24)
                    Text("So your agents start from what you know, not guesses.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit agents", systemImage: "person.2.badge.gearshape") { model.beginTeamEdit() }
            }
            DisclosureGroup("Your pitch") {
                Text(detail.pitch).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.top, Theme.s2)
            }
            .font(.callout)
        }
    }

    private var questionCard: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            // Step indicator: "Question 3 of 10" + one segment per question.
            HStack {
                Text("Question \(index + 1) of \(detail.questions.count)")
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                Spacer()
                Text("\(model.answeredCount) answered").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(detail.questions.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Theme.accent : (i < model.draftAnswers.count && !model.draftAnswers[i].isEmpty
                                                           ? Theme.accent.opacity(0.45) : Color.secondary.opacity(0.2)))
                        .frame(height: 6)
                        .onTapGesture { model.questionIndex = i }
                        .accessibilityLabel("Question \(i + 1)")
                }
            }

            Text(detail.questions[index])
                .headlineStyle(22)
                .fixedSize(horizontal: false, vertical: true)
                .id("q\(index)")
                .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                        removal: .opacity))

            ComposerTextView(text: answerBinding, placeholder: "Your answer…  (Return for next · ⇧Return for a new line)",
                             minHeight: 120, maxHeight: 300,
                             onSubmit: { go(skip: false) }, height: $answerHeight)
                .id("a\(index)")
                .frame(height: answerHeight)
                .padding(Theme.s2)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1.5))
        }
        .card(radius: Theme.radiusLarge, padding: Theme.s6)
        .animation(.easeOut(duration: 0.22), value: index)
    }

    private var controls: some View {
        HStack(spacing: Theme.s3) {
            Button {
                forward = false
                model.previousQuestion()
            } label: {
                Label("Back", systemImage: "chevron.left").frame(minWidth: 70)
            }
            .controlSize(.large)
            .disabled(index == 0 || model.busy != nil)
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Menu("Skip all") {
                Button("Skip the rest and start the agents now") { Task { await model.skipQuestions(stackRoot: stackRoot) } }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)

            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(.secondary)
            }
            Button("Skip") { go(skip: true) }
                .controlSize(.large)
                .disabled(model.busy != nil)
                .help("Leave this one blank")
            Button {
                go(skip: false)
            } label: {
                HStack(spacing: 6) {
                    Text(model.isLastQuestion ? "Start the agents" : "Next")
                    Image(systemName: model.isLastQuestion ? "person.3.fill" : "chevron.right")
                }
                .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.busy != nil)
            .keyboardShortcut(.rightArrow, modifiers: .command)
        }
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s4)
        .background(.bar)
    }

    private func go(skip: Bool) {
        forward = true
        Task { await model.nextQuestion(skip: skip, stackRoot: stackRoot) }
    }

    private var answerBinding: Binding<String> {
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
                TeamRoom(model: model, detail: detail, stackRoot: stackRoot).frame(minWidth: 360)
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
            Button("Agents", systemImage: "person.2.badge.gearshape") { model.beginTeamEdit() }
            Button("Meet now", systemImage: "person.3.fill") { Task { await model.meetNow(stackRoot: stackRoot) } }
                .disabled(model.busy != nil || !detail.isRunning)
            Toggle("On", isOn: Binding(get: { detail.isRunning },
                                       set: { on in Task { await model.setEnabled(on, stackRoot: stackRoot) } }))
                .toggleStyle(.switch)
            Menu {
                Button("Delete startup…", systemImage: "trash", role: .destructive) { model.askToDelete(model.selectedSummary) }
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
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?
    @State private var draftHeight: CGFloat = 44

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Agents room", systemImage: "bubble.left.and.bubble.right.fill").font(.headline).foregroundStyle(.tint)
                .padding([.horizontal, .top], 20).padding(.bottom, 10)
            if let meeting = detail.meeting {
                LiveMeetingBar(detail: detail, meeting: meeting)
                    .padding(.horizontal, 20).padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if detail.messages.isEmpty {
                            Text("The agents' first meeting starts in about a minute.").foregroundStyle(.secondary)
                        }
                        ForEach(detail.messages) { message in
                            if message.role == "founder" {
                                FounderBubble(message: message).id(message.id)
                            } else {
                                AgentMessageRow(detail: detail, message: message).id(message.id)
                            }
                        }
                        if let speaking = detail.meeting?.speaking {
                            TypingRow(detail: detail, key: speaking).id("typing")
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }
                .onChange(of: detail.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
                .onChange(of: detail.meeting?.speaking) { _, speaking in
                    if speaking != nil { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                }
            }
            Divider()
            founderComposer
        }
    }

    /// The founder's line into the meeting: Return sends, Shift+Return for a new line.
    private var founderComposer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerTextView(text: $model.founderDraft,
                             placeholder: detail.meeting != nil ? "Jump into the meeting…" : "Message the agents…",
                             minHeight: 44, maxHeight: 140, font: .systemFont(ofSize: NSFont.systemFontSize + 1),
                             focusOnAppear: false, onSubmit: { send() }, height: $draftHeight)
                .frame(height: draftHeight)
                .padding(.horizontal, 6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(model.founderDraft.isEmpty ? 0.25 : 0.6), lineWidth: 1.5))
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(model.canSendToAgents ? Theme.accent : Color.secondary.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canSendToAgents)
            .accessibilityLabel("Send to the agents")
            .padding(.bottom, 5)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .topLeading) {
            Text(detail.meeting != nil ? "The agents speaking next will answer you." : "The next meeting starts from your message.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 20).offset(y: -2)
        }
    }

    private func send() {
        Task { await model.sendToAgents(stackRoot: stackRoot) }
    }
}

/// One agent's message in the agents room (Tim's is highlighted).
private struct AgentMessageRow: View {
    let detail: StartupDetail
    let message: StartupDetail.Message

    var body: some View {
        let person = detail.person(message.role)
        let isCEO = message.role == "ceo"
        HStack(alignment: .top, spacing: 10) {
            AvatarView(image: Avatars.teamMember(message.role, startup: detail.id), emoji: person.emoji, size: 38)
                .overlay(Circle().strokeBorder(isCEO ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 2))
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
    }
}

/// The founder's own messages in the agents room, on the right like a chat.
private struct FounderBubble: View {
    let message: StartupDetail.Message

    var body: some View {
        HStack {
            Spacer(minLength: 50)
            VStack(alignment: .trailing, spacing: 3) {
                Text("You · meeting \(message.round)").font(.caption).foregroundStyle(.secondary)
                Text(LocalizedStringKey(message.content))
                    .font(.callout)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(.vertical, 4)
    }
}

/// "In a meeting" banner: who's in the room and who's talking right now.
private struct LiveMeetingBar: View {
    let detail: StartupDetail
    let meeting: StartupDetail.Meeting

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
                .symbolEffect(.pulse)
                .accessibilityHidden(true)
            Text("Meeting \(meeting.round) in progress").font(.callout.weight(.semibold))
            HStack(spacing: -8) {
                ForEach((meeting.speakers ?? []) + ["ceo"], id: \.self) { key in
                    AvatarView(image: Avatars.teamMember(key, startup: detail.id), emoji: detail.person(key).emoji, size: 24)
                        .overlay(Circle().strokeBorder(key == meeting.speaking ? Color.accentColor : Color(nsColor: .windowBackgroundColor),
                                                       lineWidth: 2))
                        .help(detail.person(key).name)
                }
            }
            Spacer()
            if let speaking = meeting.speaking {
                Text("\(detail.person(speaking).name.split(separator: " ").first.map(String.init) ?? "") is talking…")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The agent who's writing right now, with animated dots.
private struct TypingRow: View {
    let detail: StartupDetail
    let key: String
    @State private var phase = 0.0

    var body: some View {
        let person = detail.person(key)
        HStack(alignment: .center, spacing: 10) {
            AvatarView(image: Avatars.teamMember(key, startup: detail.id), emoji: person.emoji, size: 38)
            Text(person.name).font(.callout.weight(.semibold))
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary).frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * max(0, sin(phase - Double(i) * 0.8)))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1), in: Capsule())
        }
        .padding(12)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = .pi * 2 }
        }
        .accessibilityLabel("\(person.name) is writing")
    }
}

/// "Delete this startup?": what goes away, and a clear way out.
struct DeleteStartupConfirmation: View {
    let startup: StartupSummary
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: Theme.s4) {
            Image(systemName: "trash.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text("Delete \(startup.name)?").headlineStyle(22).multilineTextAlignment(.center)
            Text(startup.pitch).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
            VStack(alignment: .leading, spacing: Theme.s2) {
                Label("Its plan, interview answers and agents", systemImage: "doc.text")
                Label(startup.rounds > 0 ? "\(startup.rounds) meetings of agent messages" : "Its agents room", systemImage: "bubble.left.and.bubble.right")
                Label("Scheduled meetings stop right away", systemImage: "calendar.badge.minus")
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: Theme.radius, padding: Theme.s4)
            Text("This can't be undone.").font(.callout.weight(.semibold)).foregroundStyle(.red)
            HStack(spacing: Theme.s3) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button(role: .destructive, action: onDelete) {
                    Label("Delete startup", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
        }
        .padding(Theme.s6)
        .frame(width: 420)
    }
}
