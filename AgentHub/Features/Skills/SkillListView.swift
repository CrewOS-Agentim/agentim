import SwiftUI

struct SkillListView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: Skill?
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.skills) { skill in
                    Button { editing = skill } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(skill.name).font(.headline)
                                Text("/\(skill.slug)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            Text(skill.summary).font(.subheadline).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                if skill.alwaysOn { Tag(text: "Always on", symbol: "bolt.fill") }
                                ForEach(skill.triggers.prefix(2), id: \.self) { Tag(text: $0, symbol: "text.magnifyingglass") }
                                Tag(text: usage(skill) == 1 ? "1 agent" : "\(usage(skill)) agents", symbol: "person.2")
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.skills[$0].id }
                    store.skills.remove(atOffsets: offsets)
                    for i in store.agents.indices { store.agents[i].skillIDs.removeAll { ids.contains($0) } }
                }
            }
            .navigationTitle("Skills")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("New skill", systemImage: "plus") {
                            editing = Skill(name: "", summary: "", instructions: "")
                        }
                        Button("Import SKILL.md", systemImage: "square.and.arrow.down") { importing = true }
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { skill in
                SkillEditorView(skill: skill) { saved in
                    if let i = store.skills.firstIndex(where: { $0.id == saved.id }) {
                        store.skills[i] = saved
                    } else {
                        store.skills.append(saved)
                    }
                }
            }
            .sheet(isPresented: $importing) {
                SkillImportView { editing = $0 }
            }
        }
    }

    private func usage(_ skill: Skill) -> Int {
        store.agents.filter { $0.skillIDs.contains(skill.id) }.count
    }
}

struct SkillEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State var skill: Skill
    let onSave: (Skill) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $skill.name)
                    TextField("Description", text: $skill.summary)
                } footer: {
                    Text("Invoke from any chat with /\(skill.slug.isEmpty ? "name" : skill.slug).")
                }
                Section("Instructions") {
                    TextEditor(text: $skill.instructions).frame(minHeight: 180).font(.callout.monospaced())
                }
                Section {
                    TextField("review, diff, pull request", text: Binding(
                        get: { skill.triggers.joined(separator: ", ") },
                        set: { skill.triggers = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                    Toggle("Always on for attached agents", isOn: $skill.alwaysOn)
                } header: {
                    Text("Activation")
                } footer: {
                    Text("Attached skills activate when a message contains a trigger word.")
                }
                SkillModelSuggestions(skills: [skill], limit: 4)
            }
            .navigationTitle(skill.name.isEmpty ? "New Skill" : skill.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        skill.triggers.removeAll { $0.isEmpty }
                        onSave(skill)
                        dismiss()
                    }
                    .disabled(skill.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

private struct SkillImportView: View {
    @Environment(\.dismiss) private var dismiss
    let onParsed: (Skill) -> Void
    @State private var markdown = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $markdown).frame(minHeight: 260).font(.callout.monospaced())
                } header: {
                    Text("Paste a SKILL.md")
                } footer: {
                    Text("Front matter needs at least `name:`. Optional: `description:`, `triggers:` (comma separated), `always: true`.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Import Skill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") {
                        guard let skill = Skill.parse(markdown: markdown) else {
                            error = "Couldn't find front matter with a name."
                            return
                        }
                        dismiss()
                        onParsed(skill)
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Button("Paste from clipboard", systemImage: "doc.on.clipboard") {
                        markdown = NSPasteboard.general.string(forType: .string) ?? ""
                    }
                }
            }
        }
    }
}
