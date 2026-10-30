import AppKit
import SwiftUI

/// What a coding agent did in the chat's codebase: working → the changed files (with links) → a pull request.
struct WorkResultCard: View {
    let work: WorkResult
    var codebase: Codebase?
    var onOpenPullRequest: (() -> Void)?
    @State private var confirming = false
    @State private var showsOutput = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if work.state == .running {
                Text(work.request).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
            if let error = work.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            if !work.files.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(work.files.prefix(40)) { file in fileRow(file) }
                    if work.files.count > 40 {
                        Text("and \(work.files.count - 40) more").font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
            }
            if let output = work.output, !output.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $showsOutput) {
                    Text(output).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                } label: {
                    Text("What \(work.agentName) said").font(.callout)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            if work.state != .running && work.state != .failed {
                Divider()
                actions.padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
        .frame(maxWidth: 620, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.s2) {
            switch work.state {
            case .running, .openingPullRequest: ProgressView().controlSize(.small)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                if let place = place { Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer()
            if !work.files.isEmpty {
                HStack(spacing: 4) {
                    Text("+\(work.linesAdded)").foregroundStyle(.green)
                    Text("−\(work.linesRemoved)").foregroundStyle(.red)
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                .accessibilityLabel("\(work.linesAdded) lines added, \(work.linesRemoved) removed")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var title: String {
        switch work.state {
        case .running: "\(work.agentName) is building…"
        case .openingPullRequest: "Opening a pull request…"
        case .failed: "\(work.agentName) couldn't finish"
        case .done:
            if let number = work.pullRequestNumber { "Pull request #\(number) is open" }
            else if work.files.isEmpty { "\(work.agentName) finished: no files changed" }
            else { "\(work.agentName) changed \(work.files.count) file\(work.files.count == 1 ? "" : "s")" }
        }
    }

    private var place: String? {
        let where_ = work.repo ?? codebase?.name ?? work.folder.map { URL(fileURLWithPath: $0).lastPathComponent }
        guard let where_ else { return nil }
        return work.branch.map { "\(where_) · \($0)" } ?? where_
    }

    private func fileRow(_ file: FileChange) -> some View {
        HStack(spacing: Theme.s2) {
            Image(systemName: file.status == "added" ? "plus.square" : "pencil")
                .foregroundStyle(file.status == "added" ? .green : .secondary)
                .frame(width: 16)
                .accessibilityLabel(file.status == "added" ? "New file" : "Changed")
            Text(file.path).font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 8)
            if let added = file.added { Text("+\(added)").foregroundStyle(.green) }
            if let removed = file.removed, removed > 0 { Text("−\(removed)").foregroundStyle(.red) }
            if let url = work.link(for: file) {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: url.isFileURL ? "arrow.up.forward.app" : "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .help(url.isFileURL ? "Open on this Mac" : "Open on GitHub")
                .accessibilityLabel(url.isFileURL ? "Open \(file.path)" : "Open \(file.path) on GitHub")
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 14).padding(.vertical, 5)
        .contentShape(Rectangle())
        .contextMenu {
            if let folder = work.folder {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder).appendingPathComponent(file.path)])
                }
            }
            Button("Copy path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Theme.s2) {
            if let url = work.pullRequestURL.flatMap(URL.init(string:)) {
                Link(destination: url) { Label("View pull request", systemImage: "arrow.triangle.pull") }
                    .buttonStyle(.borderedProminent)
                if let files = work.pullRequestFilesURL {
                    Link(destination: files) { Label("Files changed", systemImage: "doc.on.doc") }.buttonStyle(.bordered)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: { Label("Copy link", systemImage: "link") }
                .buttonStyle(.bordered)
            } else if !work.files.isEmpty, let onOpenPullRequest {
                Button { confirming = true } label: { Label("Open pull request", systemImage: "arrow.triangle.pull") }
                    .buttonStyle(.borderedProminent)
                    .disabled(work.state == .openingPullRequest)
                    .confirmationDialog("Open a pull request\(work.repo.map { " on \($0)" } ?? "")?", isPresented: $confirming) {
                        Button("Push a branch and open it", action: onOpenPullRequest)
                    } message: {
                        Text("agentim commits these \(work.files.count) files on a new branch (never your main branch), pushes it with your git login and opens the pull request with gh. Nothing is merged.")
                    }
                if let folder = work.folder {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) } label: { Label("Open folder", systemImage: "folder") }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .controlSize(.regular)
    }
}
