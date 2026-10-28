import SwiftUI

/// A startup's agents, full page (not a modal): cards on the left, the selected agent's editor on the right.
/// Rename, retitle, change what someone owns, give them a persona and an avatar, hire, or let people go.
struct TeamEditor: View {
    @Bindable var model: StartupModel
    let presets: [RolePreset]
    let stackRoot: URL?
    @State private var selectedKey: String?

    private var selectedIndex: Int? {
        model.teamDraft.firstIndex { $0.key == selectedKey } ?? (model.teamDraft.isEmpty ? nil : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: Theme.s3)], spacing: Theme.s3) {
                        ForEach(model.teamDraft) { person in
                            AgentCard(model: model, person: person, selected: person.key == model.teamDraft[safe: selectedIndex]?.key)
                                .onTapGesture { selectedKey = person.key }
                        }
                        addCard
                    }
                    .padding(Theme.s6)
                }
                .frame(minWidth: 320, maxWidth: .infinity)
                .background(Theme.surfaceMuted)

                Divider()
                Group {
                    if let index = selectedIndex {
                        AgentDetailEditor(model: model, person: $model.teamDraft[index], stackRoot: stackRoot) {
                            let removed = model.teamDraft[index]
                            model.remove(removed)
                            selectedKey = model.teamDraft.first?.key
                        }
                        .id(model.teamDraft[index].key)
                    } else {
                        ContentUnavailableView("No agents yet", systemImage: "person.3",
                                               description: Text("Add at least one agent."))
                    }
                }
                .frame(width: 400)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.s3) {
            Button { model.editingTeam = false } label: { Label("Back", systemImage: "chevron.left") }
                .keyboardShortcut(.cancelAction)
                .help("Leave without saving")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.detail?.name ?? "Your") agents").headlineStyle(22)
                Text("\(model.teamDraft.count) of 12 · Agent Tim stays on as CEO. Every other agent is yours to shape.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let error = model.error ?? model.avatarError {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 260)
            }
            hireMenu
            Button("Cancel") { model.editingTeam = false }
            Button("Save agents") { Task { await model.saveTeam(stackRoot: stackRoot) } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.teamDraftIsValid || model.busy != nil)
        }
        .controlSize(.large)
        .padding(.horizontal, Theme.s6)
        .padding(.vertical, Theme.s3)
    }

    private var hireMenu: some View {
        Menu {
            ForEach(presets) { preset in
                Button("\(preset.emoji) \(preset.title)") { hire(preset) }
            }
            Divider()
            Button("Someone else…") { hire(nil) }
        } label: {
            Label("Add agent", systemImage: "person.badge.plus")
        }
        .fixedSize()
        .disabled(model.teamDraft.count >= 12)
    }

    /// The last card: a big "+" that opens the same presets.
    private var addCard: some View {
        Menu {
            ForEach(presets) { preset in
                Button("\(preset.emoji) \(preset.title)") { hire(preset) }
            }
            Divider()
            Button("Someone else…") { hire(nil) }
        } label: {
            VStack(spacing: Theme.s2) {
                Image(systemName: "plus.circle.fill").font(.system(size: 34)).foregroundStyle(.tint)
                Text("Add agent").font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 190)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
            .strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        .disabled(model.teamDraft.count >= 12)
    }

    private func hire(_ preset: RolePreset?) {
        model.hire(preset)
        selectedKey = model.teamDraft.last?.key
    }
}

/// One agent in the grid: avatar, name, title, what they own.
private struct AgentCard: View {
    let model: StartupModel
    let person: StartupPerson
    let selected: Bool

    var body: some View {
        VStack(spacing: Theme.s2) {
            AvatarView(image: model.editorAvatar(for: person), emoji: person.emoji, size: 72)
                .overlay(Circle().strokeBorder(selected ? Theme.accent : .clear, lineWidth: 3))
            Text(person.name.isEmpty ? "New agent" : person.name).font(.headline).lineLimit(1)
            Text(person.title).font(.subheadline).foregroundStyle(.tint).lineLimit(1)
            Text(person.owns ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .multilineTextAlignment(.center).frame(minHeight: 30, alignment: .top)
            if let persona = person.persona, !persona.isEmpty {
                Label("Persona", systemImage: "theatermasks").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
            }
        }
        .padding(Theme.s4)
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous)
            .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// The selected agent, editable: avatar, name, title, emoji, what they own, persona.
private struct AgentDetailEditor: View {
    @Bindable var model: StartupModel
    @Binding var person: StartupPerson
    let stackRoot: URL?
    let remove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                HStack {
                    Spacer()
                    VStack(spacing: Theme.s2) {
                        avatarMenu
                        Text(person.name.isEmpty ? "New agent" : person.name).headlineStyle(20)
                        Text(person.title).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                field("Name") { TextField("Jordan Lee", text: $person.name) }
                field("Title") { TextField("CTO, Head of Sales, Designer…", text: $person.title) }
                field("Emoji (shown when there's no avatar)") { TextField("🙂", text: $person.emoji) }
                field("What they own") {
                    TextField("e.g. pricing, onboarding, the first 10 customers",
                              text: Binding(get: { person.owns ?? "" }, set: { person.owns = $0 }), axis: .vertical)
                        .lineLimit(2...4)
                }
                field("Persona") {
                    TextField("Personality, background and how they talk, e.g. ex-Stripe, blunt, loves data, short bullets",
                              text: Binding(get: { person.persona ?? "" }, set: { person.persona = String($0.prefix(600)) }),
                              axis: .vertical)
                        .lineLimit(3...8)
                }
                Text("They stay in this character in every meeting.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Button(role: .destructive, action: remove) {
                    Label("Remove \(person.name.isEmpty ? "agent" : person.name)", systemImage: "person.badge.minus")
                }
                .help("Their messages stay in the agents room, marked former.")
            }
            .textFieldStyle(.roundedBorder)
            .padding(Theme.s6)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    /// Click the avatar to choose a picture, generate one with LTX, or go back to the default.
    private var avatarMenu: some View {
        Menu {
            Button("Choose image…", systemImage: "photo") { model.chooseAvatar(for: person) }
            Button("Generate with LTX", systemImage: "wand.and.stars") {
                Task { await model.generateAvatar(for: person, stackRoot: stackRoot) }
            }
            .disabled(model.generatingAvatars.contains(person.key))
            Divider()
            Button("Use default", systemImage: "arrow.uturn.backward") { model.resetAvatar(for: person) }
        } label: {
            ZStack(alignment: .bottomTrailing) {
                AvatarView(image: model.editorAvatar(for: person), emoji: person.emoji, size: 112)
                    .overlay {
                        if model.generatingAvatars.contains(person.key) {
                            Circle().fill(.black.opacity(0.35))
                            ProgressView().tint(.white)
                        }
                    }
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white, Theme.accent)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change \(person.name)'s avatar")
        .accessibilityLabel("Change avatar")
    }
}

extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}
