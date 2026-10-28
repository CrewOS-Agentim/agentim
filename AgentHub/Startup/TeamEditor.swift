import SwiftUI

/// Edit a startup's team: rename, retitle, change what someone owns, hire, or let people go.
struct TeamEditor: View {
    @Bindable var model: StartupModel
    let presets: [RolePreset]
    let stackRoot: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your agents").headlineStyle(22)
                    Text("Agent Tim stays on as CEO. Every other agent is yours to shape.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(presets) { preset in
                        Button("\(preset.emoji) \(preset.title)") { model.hire(preset) }
                    }
                    Divider()
                    Button("Someone else…") { model.hire(nil) }
                } label: {
                    Label("Add agent", systemImage: "person.badge.plus")
                }
                .fixedSize()
                .disabled(model.teamDraft.count >= 12)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($model.teamDraft) { $person in
                        EmployeeCard(model: model, person: $person, stackRoot: stackRoot) { model.remove(person) }
                    }
                    if model.teamDraft.isEmpty {
                        Text("Add at least one agent.").foregroundStyle(.secondary).padding()
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("\(model.teamDraft.count) of 12 agents").font(.caption).foregroundStyle(.secondary)
                if let error = model.error ?? model.avatarError { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Cancel") { model.editingTeam = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save agents") { Task { await model.saveTeam(stackRoot: stackRoot) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.teamDraftIsValid || model.busy != nil)
            }
            .padding(16)
        }
        .frame(width: 640, height: 620)
    }
}

private struct EmployeeCard: View {
    @Bindable var model: StartupModel
    @Binding var person: StartupPerson
    let stackRoot: URL?
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatarMenu
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Name", text: $person.name).textFieldStyle(.roundedBorder)
                    TextField("Title", text: $person.title).textFieldStyle(.roundedBorder)
                }
                TextField("What they own (e.g. pricing, onboarding, the first 10 customers)",
                          text: Binding(get: { person.owns ?? "" }, set: { person.owns = $0 }), axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                TextField("Persona: personality, background, how they talk (e.g. ex-Stripe, blunt, loves data, uses short bullets)",
                          text: Binding(get: { person.persona ?? "" }, set: { person.persona = String($0.prefix(600)) }),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .help("The agent stays in this character in every meeting.")
            }
            Button(role: .destructive, action: remove) {
                Image(systemName: "person.badge.minus")
            }
            .buttonStyle(.borderless)
            .help("Remove \(person.name). Their messages stay in the agents room.")
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}

extension EmployeeCard {
    /// Click the avatar to choose a picture, generate one with LTX, or go back to the default (emoji if none).
    var avatarMenu: some View {
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
                AvatarView(image: model.editorAvatar(for: person), emoji: person.emoji, size: 56)
                    .overlay {
                        if model.generatingAvatars.contains(person.key) {
                            Circle().fill(.black.opacity(0.35))
                            ProgressView().controlSize(.small).tint(.white)
                        }
                    }
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white, Theme.accent)
                    .offset(x: 2, y: 2)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change \(person.name)'s avatar")
        .accessibilityLabel("Change avatar")
    }
}
