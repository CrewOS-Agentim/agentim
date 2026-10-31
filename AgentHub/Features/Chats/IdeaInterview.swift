import SwiftUI

// MARK: - Pitch an idea in a group chat: the idea, 10 questions (one at a time), then the agents discuss it

/// A group chat that starts from an idea: the founder's answers become the group's brief.
struct IdeaBrief: Codable, Hashable {
    var idea = ""
    var questions: [String] = []
    var answers: [String] = []
    /// idea → interview → done (the discussion runs in the chat)
    var stage = "idea"
}

extension AppStore {
    static let fallbackQuestions = [
        "Who desperately needs this, and how do you know?",
        "What do they do today instead, and what does that cost them?",
        "Why now: what changed that makes this possible or urgent?",
        "What's the insight others are missing?",
        "How will you make money, and roughly how much per customer?",
        "Why are you the right person (or team) to build this?",
        "How much time and money can you commit in the next 90 days?",
        "Who does what: which roles do you need first?",
        "What does success look like in 90 days, in numbers?",
        "What would make you stop: your kill criteria?",
    ]

    /// A group with the leadership agents you have (CPO, CTO, CMO, CRO, CFO), ready for the idea and the questions.
    @discardableResult
    func newIdeaGroup() -> Conversation {
        let wanted = ["CPO", "CTO", "CMO", "CRO", "CFO"]
        var team = wanted.compactMap { role in agents.first { $0.name.uppercased() == role } }
        if team.isEmpty { team = Array(agents.prefix(4)) }
        var group = newMeeting(with: team)
        group.brief = IdeaBrief()
        group.discussionRounds = 2
        group.title = "New idea"
        if let i = conversations.firstIndex(where: { $0.id == group.id }) { conversations[i] = group }
        return group
    }

    func updateBrief(_ conversationID: UUID, _ change: (inout IdeaBrief) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }), var brief = conversations[i].brief else { return }
        change(&brief)
        conversations[i].brief = brief
    }

    /// One answer from the best available model (no conversation, no streaming to the UI).
    func ask(_ prompt: String, system: String = "") async throws -> String {
        let decision = try ModelRouter(available: availableModels, settings: router, cloudFirst: cloudModelsFirst).route(
            RoutingRequest(text: prompt, history: [], agent: nil, conversationPin: nil, isOnline: isOnline))
        let targets = ([decision.model] + decision.fallbacks.prefix(1)).compactMap { m in client(for: m).map { (m, $0) } }
        for (model, client) in targets {
            do {
                var out = ""
                for try await chunk in client.stream(ChatRequest(model: model.modelName, system: system,
                                                                 messages: [ChatMessage(role: .user, content: prompt)])) {
                    out += chunk
                }
                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return out }
            } catch {
                continue
            }
        }
        throw RoutingError.noModelsAvailable
    }

    /// Ten follow-up questions about the idea: five as a YC partner, five as a co-founder.
    func askTheQuestions(_ conversationID: UUID) async {
        guard let idea = conversations.first(where: { $0.id == conversationID })?.brief?.idea else { return }
        let yc = skills.first { $0.slug == "yc-partner" }?.instructions ?? ""
        let cofounder = skills.first { $0.slug == "co-founder" }?.instructions ?? ""
        let prompt = """
        A founder pitched this idea: "\(idea)"

        Write exactly 10 short follow-up questions for them, one per line, numbered 1–10: questions 1–5 as a YC partner \
        (who needs it, how they know, why now, the insight, the money), questions 6–10 as a potential co-founder \
        (why them, commitment, roles, the first 90 days, kill criteria). Make each specific to this idea. No other text.

        YC partner guidance:
        \(yc.prefix(1200))

        Co-founder guidance:
        \(cofounder.prefix(1200))
        """
        var questions = (try? await ask(prompt)).map(Self.numberedLines) ?? []
        if questions.count < 10 {
            questions += Self.fallbackQuestions.filter { !questions.contains($0) }
        }
        updateBrief(conversationID) {
            $0.questions = Array(questions.prefix(10))
            $0.answers = Array(repeating: "", count: $0.questions.count)
            $0.stage = "interview"
        }
        if !isWatching(conversationID) {
            Notifier.shared.post(title: "Your 10 questions are ready", body: questions.first ?? "Agent Tim has questions about your idea.",
                                 conversationID: conversationID, needsInput: true)
        }
    }

    /// "1. Who …" lines → the questions.
    nonisolated static func numberedLines(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let match = trimmed.firstMatch(of: /^\**\s*\d{1,2}[.)]\**\s*(.+)$/) else { return nil }
            let question = String(match.1).trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            return question.isEmpty ? nil : question
        }
    }

    /// The AI drafts an answer from the idea and the other answers (the founder edits it).
    func suggestAnswer(_ index: Int, in conversationID: UUID) async -> String? {
        guard let brief = conversations.first(where: { $0.id == conversationID })?.brief,
              index < brief.questions.count else { return nil }
        let known = zip(brief.questions, brief.answers).enumerated()
            .filter { $0.offset != index && !$0.element.1.isEmpty }
            .map { "Q: \($0.element.0)\nA: \($0.element.1)" }.joined(separator: "\n")
        let prompt = """
        A founder is answering questions about their idea: "\(brief.idea)"
        \(known.isEmpty ? "" : "What they answered so far:\n\(known)\n")
        Answer this question as the founder would: specific and realistic (a named customer type, a price, a number), \
        consistent with the idea, 1–3 sentences, no preamble:
        \(brief.questions[index])
        """
        return try? await ask(prompt).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Fills every blank answer with an AI suggestion (marked), then the discussion starts.
    func answerTheRest(_ conversationID: UUID) async {
        guard let brief = conversations.first(where: { $0.id == conversationID })?.brief else { return }
        for index in brief.questions.indices where index >= brief.answers.count || brief.answers[index].trimmingCharacters(in: .whitespaces).isEmpty {
            if let answer = await suggestAnswer(index, in: conversationID), !answer.isEmpty {
                updateBrief(conversationID) {
                    while $0.answers.count <= index { $0.answers.append("") }
                    $0.answers[index] = answer + " (suggested by AI)"
                }
            }
        }
        finishInterview(conversationID)
    }

    /// The brief every member sees: the idea and the answers.
    func briefText(_ conversation: Conversation) -> String? {
        guard let brief = conversation.brief, brief.stage == "done", !brief.idea.isEmpty else { return nil }
        let qa = zip(brief.questions, brief.answers).filter { !$0.1.isEmpty }.map { "- \($0.0)\n  \($0.1)" }.joined(separator: "\n")
        return "The founder's idea: \(brief.idea)" + (qa.isEmpty ? "" : "\nTheir answers:\n\(qa)")
    }

    /// The interview is over: the idea and the answers go to the group, and the members start discussing.
    func finishInterview(_ conversationID: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == conversationID }), let brief = conversations[i].brief else { return }
        updateBrief(conversationID) { $0.stage = "done" }
        let words = brief.idea.split(separator: " ").prefix(5).joined(separator: " ")
        conversations[i].title = words.isEmpty ? "Idea" : String(words)
        let qa = zip(brief.questions, brief.answers).filter { !$0.1.isEmpty }
            .map { "**\($0.0)**\n\($0.1)" }.joined(separator: "\n\n")
        let text = "**My idea:** \(brief.idea)" + (qa.isEmpty ? "" : "\n\n\(qa)")
            + "\n\nWhat do you think? Pressure-test it and tell me the first steps, each from your own area."
        sendToMeeting(text, in: conversationID)
    }
}

/// Shown in a pitch group chat until the interview is done: the idea, then the 10 questions one at a time.
struct IdeaInterview: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation
    @State private var idea = ""
    @State private var index = 0
    @State private var answer = ""
    @State private var working: String?
    @State private var answerHeight: CGFloat = 110

    private var brief: IdeaBrief { conversation.brief ?? IdeaBrief() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                if brief.stage == "idea" { ideaStep } else { questionStep }
                if let working {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(working).foregroundStyle(.secondary) }
                }
            }
            .padding(Theme.s8)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { idea = brief.idea; load(index) }
    }

    private var ideaStep: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            HStack(spacing: Theme.s3) {
                TimAvatar(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's the idea?").headlineStyle(26)
                    Text("Agent Tim asks 10 questions (5 as a YC partner, 5 as a co-founder), then the group talks it through.")
                        .foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $idea)
                .frame(height: 120).padding(6)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
            Text("What it is, who it's for, and why now. A sentence or two is plenty.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Skip the questions") {
                    store.updateBrief(conversation.id) { $0.idea = idea }
                    store.finishInterview(conversation.id)
                }
                .disabled(trimmed(idea).count < 10 || working != nil)
                Spacer()
                Button {
                    store.updateBrief(conversation.id) { $0.idea = idea }
                    working = "Agent Tim is writing your questions…"
                    Task {
                        await store.askTheQuestions(conversation.id)
                        working = nil
                        index = 0
                        load(0)
                    }
                } label: { Label("Ask me the 10 questions", systemImage: "questionmark.bubble") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(trimmed(idea).count < 10 || working != nil)
            }
        }
    }

    private var questionStep: some View {
        let total = brief.questions.count
        return VStack(alignment: .leading, spacing: Theme.s4) {
            HStack {
                Text("Question \(min(index + 1, total)) of \(total)").font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                Spacer()
                Text("\(brief.answers.filter { !trimmed($0).isEmpty }.count) answered").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Theme.accent : (i < brief.answers.count && !trimmed(brief.answers[i]).isEmpty
                                                           ? Theme.accent.opacity(0.45) : Color.secondary.opacity(0.2)))
                        .frame(height: 6)
                        .onTapGesture { save(); index = i; load(i) }
                }
            }
            if index < total {
                Text(brief.questions[index]).headlineStyle(22).fixedSize(horizontal: false, vertical: true)
                ComposerTextView(text: $answer, placeholder: "Your answer…  (Return for next · ⇧Return for a new line)",
                                 minHeight: 110, maxHeight: 280, onSubmit: { next() }, height: $answerHeight)
                    .frame(height: answerHeight)
                    .padding(Theme.s2)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1.5))
                Button {
                    working = "Thinking…"
                    let current = index
                    Task {
                        if let text = await store.suggestAnswer(current, in: conversation.id), current == index { answer = text }
                        working = nil
                    }
                } label: { Label(trimmed(answer).isEmpty ? "Suggest an answer" : "Suggest another", systemImage: "sparkles") }
                    .disabled(working != nil)
            }
            HStack(spacing: Theme.s3) {
                Button { save(); index = max(0, index - 1); load(index) } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(index == 0 || working != nil)
                Button {
                    save()
                    working = "The AI is answering the rest…"
                    Task { await store.answerTheRest(conversation.id); working = nil }
                } label: { Label("Let AI answer the rest", systemImage: "wand.and.stars") }
                    .disabled(working != nil)
                Spacer()
                Button("Skip") { answer = ""; next() }.disabled(working != nil)
                Button { next() } label: {
                    Label(index >= total - 1 ? "Start the discussion" : "Next", systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .disabled(working != nil)
            }
            .controlSize(.large)
        }
        .card(radius: Theme.radiusLarge, padding: Theme.s6)
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func load(_ i: Int) { answer = i < brief.answers.count ? brief.answers[i] : "" }

    private func save() {
        let i = index, text = trimmed(answer)
        store.updateBrief(conversation.id) {
            while $0.answers.count <= i { $0.answers.append("") }
            $0.answers[i] = text
        }
    }

    private func next() {
        save()
        if index >= brief.questions.count - 1 {
            store.finishInterview(conversation.id)
        } else {
            index += 1
            load(index)
        }
    }
}
