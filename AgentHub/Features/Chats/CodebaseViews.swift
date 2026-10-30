import AppKit
import SwiftUI

/// Toolbar: connect the chat to a folder on this Mac or a GitHub repo (agents read it; Claude Code builds in it).
struct CodebaseMenu: View {
    @Environment(AppStore.self) private var store
    @Environment(HostController.self) private var host
    let conversation: Conversation
    @State private var askingRepo = false
    @State private var repo = ""
    @State private var problem: String?

    var body: some View {
        Menu {
            Section(conversation.codebase.map { "Working on \($0.name)" } ?? "Work on code") {
                Button("Connect a folder on this Mac…", systemImage: "folder.badge.plus") { pickFolder() }
                Button("Connect a GitHub repo…", systemImage: "arrow.triangle.branch") { repo = ""; askingRepo = true }
            }
            if let codebase = conversation.codebase {
                Divider()
                if codebase.kind == .github, let url = URL(string: "https://github.com/\(codebase.location)") {
                    Link(destination: url) { Label("Open on GitHub", systemImage: "safari") }
                } else {
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: codebase.location))
                    }
                }
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                    store.setCodebase(nil, in: conversation.id)
                }
            }
        } label: {
            Label(conversation.codebase?.name ?? "Codebase", systemImage: "chevron.left.forwardslash.chevron.right")
                .labelStyle(.titleAndIcon)
        }
        .help(conversation.codebase.map { "This chat works on \($0.name)" } ?? "Connect a folder or a GitHub repo to this chat")
        .accessibilityLabel(conversation.codebase.map { "Codebase: \($0.name)" } ?? "Connect a codebase")
        .alert("Connect a GitHub repo", isPresented: $askingRepo) {
            TextField("owner/name or a github.com link", text: $repo)
            Button("Connect") { connectRepo() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("agentim clones it on this Mac with your GitHub login (gh), so private repos work too. Agents read it; Claude Code builds in it when you say so.")
        }
        .alert("Couldn't connect", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Connect"
        panel.message = "Choose the project folder. Agents can read it; Claude Code edits it only when you press Build it."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            // The runner may only read folders listed in AGENTIM_WORKSPACES: this one is added.
            StartupModel.allowWorkspace(url, stackRoot: host.stackRoot)
            store.setCodebase(Codebase(kind: .folder, location: url.path), in: conversation.id)
        }
    }

    private func connectRepo() {
        guard let codebase = Codebase.github(repo) else {
            problem = "Use owner/name, like apple/swift, or a github.com link."
            return
        }
        store.setCodebase(codebase, in: conversation.id)
    }
}

/// Above the message box: the chat's codebase and Build it (Claude Code makes the changes; you review them).
struct CodebaseBar: View {
    @Environment(AppStore.self) private var store
    let conversation: Conversation
    let codebase: Codebase
    @State private var confirming = false

    var body: some View {
        let request = store.buildRequest(in: conversation.id)
        HStack(spacing: Theme.s2) {
            Image(systemName: codebase.symbol).foregroundStyle(.secondary)
            Text(codebase.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            Text(request == nil ? "Ask for a change, then build it" : "Agents read this codebase")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Button { confirming = true } label: {
                Label("Build it", systemImage: "hammer.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(request == nil || store.isStreaming(conversation.id))
            .help(request == nil ? "Describe what to change first" : "Claude Code makes the change in \(codebase.name)")
            .confirmationDialog("Let Claude Code edit \(codebase.name)?", isPresented: $confirming) {
                Button("Build it") { store.buildIt(in: conversation.id) }
            } message: {
                Text("It changes files in \(codebase.kind == .github ? "your clone of " : "")\(codebase.location) to do what you asked. You see every changed file, and nothing goes to GitHub unless you open a pull request.")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
        .padding(.leading, 42)
    }
}
