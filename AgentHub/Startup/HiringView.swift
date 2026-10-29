import AppKit
import SwiftUI

// MARK: - Hiring: the Recruiter finds engineers on GitHub and drafts messages you send yourself

struct Candidate: Decodable, Equatable, Identifiable {
    struct Profile: Decodable, Equatable {
        struct Repo: Decodable, Equatable, Hashable {
            let name: String
            var description: String? = nil
            var language: String? = nil
            var stars: Int? = nil
            var url: String? = nil
        }

        struct Commit: Decodable, Equatable, Hashable {
            let repo: String
            let message: String
        }

        let login: String
        var name: String? = nil
        var bio: String? = nil
        var company: String? = nil
        var location: String? = nil
        var avatar_url: String? = nil
        var html_url: String? = nil
        var followers: Int? = nil
        var repos: [Repo]? = nil
        var commits: [Commit]? = nil
    }

    let id: String
    let role: String
    let login: String
    let profile: Profile
    let score: Double
    let why: String
    var note: String
    var message: String
    let status: String          // new | shortlisted | contacted | replied | skipped
    let linkedin: String
}

struct HiringBoard: Decodable, Equatable {
    let candidates: [Candidate]
    var searching: String? = nil
}

extension StartupClient {
    func hiring(_ id: String) async throws -> HiringBoard { try await getJSON("v1/startups/\(id)/candidates") }

    func recruit(_ id: String, role: String) async throws {
        try await post("v1/startups/\(id)/recruit", body: ["role": role])
    }

    func updateCandidate(_ id: String, _ body: [String: Any]) async throws {
        try await post("v1/startups/\(id)/candidates", body: body)
    }
}

extension StartupModel {
    func loadHiring(stackRoot: URL?) async {
        guard let id = detail?.id, !isDemo, let client = Self.client(stackRoot: stackRoot) else { return }
        if let board = try? await client.hiring(id) { hiring = board }
    }

    func recruit(stackRoot: URL?) async {
        let role = roleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = detail?.id, !role.isEmpty else { return }
        await act("The recruiter is searching GitHub…", stackRoot) { client in try await client.recruit(id, role: role) }
        await loadHiring(stackRoot: stackRoot)
    }

    func updateCandidate(_ candidate: Candidate, status: String? = nil, note: String? = nil, message: String? = nil,
                         stackRoot: URL?) async {
        guard let id = detail?.id else { return }
        var body: [String: Any] = ["id": candidate.id]
        if let status { body["status"] = status }
        if let note { body["note"] = note }
        if let message { body["message"] = message }
        await act(nil, stackRoot) { client in try await client.updateCandidate(id, body) }
        await loadHiring(stackRoot: stackRoot)
    }
}

/// The Hiring tab.
struct HiringPanel: View {
    @Bindable var model: StartupModel
    let detail: StartupDetail
    let stackRoot: URL?
    @State private var filter = "active"

    private var candidates: [Candidate] {
        let all = model.hiring?.candidates ?? []
        switch filter {
        case "active": return all.filter { $0.status != "skipped" }
        case "contacted": return all.filter { $0.status == "contacted" || $0.status == "replied" }
        default: return all
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s4) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("The role, e.g. \"Senior iOS engineer, Swift, Europe\"", text: $model.roleDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await model.recruit(stackRoot: stackRoot) } }
                        Button("Find engineers") { Task { await model.recruit(stackRoot: stackRoot) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.roleDraft.trimmingCharacters(in: .whitespaces).count < 5 || model.hiring?.searching != nil)
                    }
                    if let searching = model.hiring?.searching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Searching GitHub and reading repos for “\(searching)”…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("The recruiter reads public GitHub work (repos and commits) and drafts a message for each person. You send it yourself on LinkedIn: agentim never collects emails or sends messages for you.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("", selection: $filter) {
                    Text("Active").tag("active")
                    Text("Contacted").tag("contacted")
                    Text("All").tag("all")
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                if candidates.isEmpty {
                    ContentUnavailableView("No candidates yet", systemImage: "person.crop.circle.badge.magnifyingglass",
                                           description: Text("Describe a role and press Find engineers."))
                }
                ForEach(candidates) { CandidateCard(model: model, candidate: $0, stackRoot: stackRoot) }
            }
            .padding(Theme.s4)
        }
        .task(id: detail.id) {
            while !Task.isCancelled {
                await model.loadHiring(stackRoot: stackRoot)
                try? await Task.sleep(for: .seconds(model.hiring?.searching != nil ? 4 : 20))
            }
        }
    }
}

private struct CandidateCard: View {
    @Bindable var model: StartupModel
    let candidate: Candidate
    let stackRoot: URL?
    @State private var note = ""
    @State private var message = ""
    @State private var copied: String?

    var body: some View {
        let p = candidate.profile
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: Theme.s3) {
                AsyncImage(url: p.avatar_url.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: {
                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                }
                .frame(width: 44, height: 44).clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(p.name ?? p.login).font(.headline)
                        Text("@\(p.login)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f/10", candidate.score)).font(.callout.weight(.bold).monospacedDigit())
                            .foregroundStyle(candidate.score >= 7 ? .green : candidate.score >= 5 ? .orange : .secondary)
                    }
                    Text([p.location, p.company, p.followers.map { "\($0) followers" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(candidate.why).font(.callout)
                }
            }
            if let repos = p.repos, !repos.isEmpty {
                HStack(spacing: 6) {
                    ForEach(repos.prefix(4), id: \.self) { repo in
                        Text("\(repo.name)\(repo.stars.map { $0 > 0 ? " ★\($0)" : "" } ?? "")")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.surfaceMuted, in: Capsule())
                            .help(repo.description ?? repo.name)
                    }
                }
            }
            if let commits = p.commits, !commits.isEmpty {
                DisclosureGroup("Recent commits") {
                    ForEach(commits.prefix(6), id: \.self) { c in
                        Text("• \(c.repo): \(c.message)").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.caption)
            }
            labeled("LinkedIn connection note (\(note.count)/280)") {
                TextField("", text: $note, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            }
            labeled("Message") {
                TextField("", text: $message, axis: .vertical).lineLimit(3...8).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: Theme.s2) {
                Button(copied == "note" ? "Copied ✓" : "Copy note") { copy(note, "note") }
                Button(copied == "message" ? "Copied ✓" : "Copy message") { copy(message, "message") }
                Button("Find on LinkedIn", systemImage: "arrow.up.right.square") {
                    if let url = URL(string: candidate.linkedin) { NSWorkspace.shared.open(url) }
                }
                Button("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                    if let url = p.html_url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
                }
                Spacer()
                Picker("", selection: Binding(get: { candidate.status }, set: { status in
                    Task { await model.updateCandidate(candidate, status: status, note: note, message: message, stackRoot: stackRoot) }
                })) {
                    Text("New").tag("new")
                    Text("Shortlisted").tag("shortlisted")
                    Text("Contacted").tag("contacted")
                    Text("Replied").tag("replied")
                    Text("Skipped").tag("skipped")
                }
                .labelsHidden().frame(width: 130)
            }
            .controlSize(.small)
        }
        .padding(Theme.s3)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        .opacity(candidate.status == "skipped" ? 0.55 : 1)
        .onAppear { note = candidate.note; message = candidate.message }
        .onChange(of: candidate.id) { note = candidate.note; message = candidate.message }
    }

    private func copy(_ text: String, _ which: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = which
        if note != candidate.note || message != candidate.message {
            Task { await model.updateCandidate(candidate, note: note, message: message, stackRoot: stackRoot) }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
