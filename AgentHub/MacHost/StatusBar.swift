import SwiftUI

/// Always at the bottom of the window: agentim's containers (from `docker ps`), the models in memory and LTX.
/// Click anything to open its logs.
struct StatusBar: View {
    @Environment(HostController.self) private var host
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: Theme.s3) {
            if let note = host.startupNote {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(note)
                }
                .foregroundStyle(.secondary)
            }
            if !host.dockerRunning && !host.containers.contains(where: \.isRunning) {
                Label("Docker is off", systemImage: "shippingbox").foregroundStyle(.orange)
                Button("Open Docker") { host.startDocker() }.controlSize(.small)
            } else {
                ForEach(host.containers) { container in
                    Button { showLogs(.container(container.service)) } label: {
                        HStack(spacing: 4) {
                            Circle().fill(color(container)).frame(width: 7, height: 7)
                            Text(container.service)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(container.name): \(container.status). Click for logs.")
                    .accessibilityLabel("\(container.service), \(container.status)")
                }
            }
            Divider().frame(height: 14)
            Button { showLogs(.container("ollama")) } label: {
                Label(modelsText, systemImage: "cpu")
            }
            .buttonStyle(.plain)
            .help(host.loadedModels.map { "\($0.name) · \($0.gigabytes)" }.joined(separator: "\n").isEmpty
                  ? "No models in memory. They load on the next message." : host.loadedModels.map { "\($0.name) · \($0.gigabytes)" }.joined(separator: "\n"))
            Button { showLogs(.nativeRunner) } label: {
                Label(host.ltxRunning ? "LTX running" : "LTX closed", systemImage: "film")
            }
            .buttonStyle(.plain)
            .help("LTX Desktop. Click for the runner's log on this Mac.")
            Spacer()
            Button { showLogs(host.logSource) } label: { Label("Logs", systemImage: "text.alignleft") }
                .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.s4)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var modelsText: String {
        guard !host.loadedModels.isEmpty else { return "No models in memory" }
        let names = host.loadedModels.map { $0.name.split(separator: "/").last.map(String.init) ?? $0.name }
        return "\(names.joined(separator: ", ")) · \(host.memoryInUse)"
    }

    private func color(_ container: HostController.Container) -> Color {
        if container.isRunning { return container.status.contains("unhealthy") ? .orange : .green }
        return container.state == "restarting" ? .orange : .red
    }

    private func showLogs(_ source: HostController.LogSource) {
        host.logSource = source
        openWindow(id: "logs")
    }
}

/// A window with the logs of every container and the native runner; refreshes every 2 seconds while open.
struct LogsView: View {
    @Environment(HostController.self) private var host
    @State private var text = ""
    @State private var filter = ""
    @State private var lines = 300
    @State private var follow = true
    /// The app's own polling (models in memory, health) fills Ollama's log; hide it by default.
    @State private var hideChecks = true

    var body: some View {
        @Bindable var host = host
        NavigationSplitView {
            List(host.logSources, selection: Binding(get: { host.logSource }, set: { if let s = $0 { host.logSource = s } })) { source in
                Label {
                    Text(source.title)
                } icon: {
                    if case .container(let service) = source, let container = host.containers.first(where: { $0.service == service }) {
                        Circle().fill(container.isRunning ? Color.green : .red).frame(width: 8, height: 8)
                    } else {
                        Image(systemName: "laptopcomputer")
                    }
                }
                .tag(source)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    TextField("Filter lines", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    Picker("Lines", selection: $lines) {
                        Text("300").tag(300); Text("1,000").tag(1000); Text("5,000").tag(5000)
                    }
                    .fixedSize()
                    Toggle("Live", isOn: $follow).toggleStyle(.switch).controlSize(.small)
                    Toggle("Hide status checks", isOn: $hideChecks).toggleStyle(.checkbox)
                        .help("Hide agentim's own polling (GET /api/ps, /health…) so model activity stands out.")
                    Spacer()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(shown, forType: .string)
                    }
                    Button("Open in Terminal", systemImage: "terminal") { host.openLogsInTerminal(host.logSource) }
                }
                .padding(Theme.s3)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        Text(placeholderOrLog)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.s3)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: text) { if follow { proxy.scrollTo("end", anchor: .bottomLeading) } }
                }
            }
            .navigationTitle("Logs · \(host.logSource.title)")
        }
        .task(id: "\(host.logSource.id)-\(lines)-\(follow)") {
            while !Task.isCancelled {
                text = await host.logs(host.logSource, lines: lines)
                guard follow else { break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }

    /// The log, filtered to lines containing the search text (case-insensitive).
    private var shown: String {
        LogsView.filter(hideChecks ? LogsView.withoutStatusChecks(text) : text, by: filter)
    }

    private var placeholderOrLog: String {
        if text.isEmpty { return "Loading…" }
        if !shown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return shown }
        if !filter.isEmpty { return "No lines match “\(filter)”." }
        return "Only status checks in the last \(lines) lines: no model activity. Uncheck “Hide status checks” or show more lines."
    }

    /// Requests agentim makes every few seconds to show status; they say nothing about the models.
    static let statusChecks = ["\"/api/ps\"", "\"/api/version\"", "\"/api/tags\"", "GET /health", "\"/health\"",
                               "/v1/models/loaded", "/v1/status", "GET /v1/models "]

    static func withoutStatusChecks(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !statusChecks.contains { line.contains($0) } }
            .joined(separator: "\n")
    }

    static func filter(_ text: String, by query: String) -> String {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return text }
        return text.split(separator: "\n").filter { $0.localizedCaseInsensitiveContains(query) }.joined(separator: "\n")
    }
}
