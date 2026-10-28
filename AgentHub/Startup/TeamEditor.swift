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
                    Text("The team").font(.title2.bold())
                    Text("Agent Tim stays on as CEO. Everyone else is yours to shape.")
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
                    Label("Hire", systemImage: "person.badge.plus")
                }
                .fixedSize()
                .disabled(model.teamDraft.count >= 12)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach($model.teamDraft) { $person in
                        EmployeeCard(person: $person) { model.remove(person) }
                    }
                    if model.teamDraft.isEmpty {
                        Text("Hire at least one person.").foregroundStyle(.secondary).padding()
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Text("\(model.teamDraft.count) of 12 people").font(.caption).foregroundStyle(.secondary)
                if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button("Cancel") { model.editingTeam = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save team") { Task { await model.saveTeam(stackRoot: stackRoot) } }
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
    @Binding var person: StartupPerson
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TextField("🙂", text: $person.emoji)
                .font(.system(size: 26))
                .multilineTextAlignment(.center)
                .frame(width: 48, height: 48)
                .textFieldStyle(.plain)
                .background(Color.secondary.opacity(0.12), in: Circle())
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
            }
            Button(role: .destructive, action: remove) {
                Image(systemName: "person.badge.minus")
            }
            .buttonStyle(.borderless)
            .help("Let \(person.name) go. Their messages stay in the team room.")
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
