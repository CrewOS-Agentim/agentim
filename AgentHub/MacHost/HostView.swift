import SwiftUI

/// "This Mac": the control center for the always-on host.
struct HostView: View {
    @Environment(AppStore.self) private var store
    @Environment(HostController.self) private var host

    var body: some View {
        @Bindable var host = host
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Agent Tim is \(host.isHealthy ? "on duty" : "taking a nap")")
                                .font(.title2.bold())
                            Label(host.summary, systemImage: host.isHealthy ? "checkmark.seal.fill" : "moon.zzz.fill")
                                .foregroundStyle(host.isHealthy ? .green : .orange)
                        }
                        Spacer()
                        if let busy = host.busy { ProgressView().controlSize(.small); Text(busy).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, 4)
                }

                Section("Stack") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(host.stackRoot?.path ?? "Not set").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button("Choose…") { host.chooseStackRoot() }
                        }
                    }
                    if !host.dockerRunning {
                        LabeledContent("Docker") {
                            Button("Open Docker Desktop") { host.startDocker() }
                        }
                    }
                    ForEach(HostController.services, id: \.self) { name in
                        let service = host.services.first { $0.name == name }
                        LabeledContent {
                            Text(service.map { $0.health.isEmpty ? $0.state : "\($0.state) · \($0.health)" } ?? "not created")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label {
                                Text(title(for: name))
                            } icon: {
                                Circle().fill(service?.isRunning == true ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 9, height: 9)
                            }
                        }
                    }
                    HStack {
                        Button("Start", systemImage: "play.fill") { Task { await host.start() } }
                        Button("Restart", systemImage: "arrow.clockwise") { Task { await host.restart() } }
                        Button("Stop", systemImage: "stop.fill") { Task { await host.stop() } }
                        Spacer()
                        Button("Edit settings (.env)") { host.editSettings() }
                    }
                    .disabled(host.busy != nil || !host.dockerRunning)
                }

                Section {
                    LabeledContent("Power", value: host.power == .charger ? "Charger" : host.power == .battery ? "Battery" : "Unknown")
                    LabeledContent("Lid closed") {
                        Text(host.lidSleepDisabled ? "Stays awake" : "Sleeps")
                            .foregroundStyle(host.lidSleepDisabled ? .green : .secondary)
                    }
                    ForEach(["watchdog", "runner", "power"], id: \.self) { key in
                        LabeledContent(helperTitle(key)) {
                            Image(systemName: host.helpers[key] == true ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(host.helpers[key] == true ? .green : .secondary)
                        }
                    }
                    Toggle("Open agentim at login", isOn: $host.launchAtLogin)
                    HStack {
                        Button("Install always-on helpers…") { host.installHelpers() }
                        Button("Open logs") { host.openLogs() }
                    }
                } header: {
                    Text("Always on")
                } footer: {
                    Text("The helpers restart Docker and the stack if anything stops (and after a reboot once you log in), keep the Mac awake with the lid closed while it's on the charger, and boot it again after a power cut. Installing asks for your password in Terminal.")
                }

                Section {
                    Button("Connect this Mac's models", systemImage: "desktopcomputer") { host.connectThisMac(to: store) }
                    Button("Link WhatsApp (scan QR)", systemImage: "qrcode") { host.openWhatsAppQR() }
                } header: {
                    Text("Channels & models")
                } footer: {
                    Text("Telegram and Slack tokens live in .env. Hugging Face models run in the Docker stack; LTX video runs natively.")
                }

                if let error = host.lastError {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("This Mac")
            .toolbar {
                ToolbarItem { Button("Refresh", systemImage: "arrow.clockwise") { Task { await host.refresh() } } }
            }
        }
    }

    private func title(for service: String) -> String {
        switch service {
        case "ollama": "Hugging Face models (Ollama)"
        case "runner": "Runner (memory checks)"
        case "gateway": "Gateway (Telegram · Slack · WhatsApp)"
        case "whatsapp": "WhatsApp bridge"
        default: service
        }
    }

    private func helperTitle(_ key: String) -> String {
        switch key {
        case "watchdog": "Restart watchdog"
        case "runner": "LTX runner"
        default: "Lid-close power guard"
        }
    }
}

/// The 🐙 in the menu bar.
struct MenuBarContent: View {
    @Environment(HostController.self) private var host
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(host.summary)
        Text(host.lidSleepDisabled ? "Lid closed: stays awake" : "Lid closed: sleeps")
        Divider()
        Button("Start stack") { Task { await host.start() } }
        Button("Restart stack") { Task { await host.restart() } }
        Button("Stop stack") { Task { await host.stop() } }
        Divider()
        Button("Open agentim") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit agentim") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
