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

                Section {
                    HStack(spacing: 10) {
                        Button { Task { await host.start() } } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(.green)
                        Button { Task { await host.restart() } } label: { Label("Restart", systemImage: "arrow.clockwise") }
                        Button { Task { await host.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                            .tint(.red)
                        Spacer()
                        Text(host.summary).font(.callout).foregroundStyle(.secondary)
                    }
                    .controlSize(.large)
                    .disabled(host.busy != nil || !host.dockerRunning)
                    LabeledContent {
                        HStack {
                            Text(host.loadedModels.isEmpty ? "None loaded" : host.memoryInUse).foregroundStyle(.secondary)
                            Button("Free memory", systemImage: "memorychip") { Task { await host.freeMemory() } }
                                .disabled(host.loadedModels.isEmpty || host.busy != nil)
                                .help("Unload the models now. They load again on the next message.")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Models in memory", systemImage: "cpu")
                            ForEach(host.loadedModels) { model in
                                Text("\(model.name) · \(model.gigabytes)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    LabeledContent {
                        HStack {
                            Text(host.ltxRunning ? "Running" : "Closed").foregroundStyle(.secondary)
                            Button("Stop LTX", systemImage: "stop.circle") { Task { await host.stopLTX() } }
                                .disabled(!host.ltxRunning || host.busy != nil)
                                .help("Quit LTX Desktop to free its GPU memory. It opens again when you ask for a video or image.")
                        }
                    } label: {
                        Label("LTX Desktop (video & images)", systemImage: "film")
                    }
                } header: {
                    Text("Quick controls")
                } footer: {
                    Text("Start, stop or restart all the Docker containers. Models unload by themselves 5 minutes after their last use; Free memory does it now.")
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
                    ForEach(HostController.services + HostController.optionalServices.filter { name in host.services.contains { $0.name == name } }, id: \.self) { name in
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
                        Button("Run setup again…") { UserDefaults.standard.set(false, forKey: "onboardingComplete") }
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

                Section {
                    LabeledContent {
                        if host.claudeConnected {
                            Button("Disconnect") { Task { await host.connectClaude(remove: true) } }
                        } else {
                            Button("Add to Claude") { Task { await host.connectClaude() } }
                        }
                    } label: {
                        Label(host.claudeConnected ? "Claude Desktop: connected" : "Claude Desktop & Claude Code",
                              systemImage: "sparkle")
                    }
                    LabeledContent {
                        if host.chatGPTConnectorURL == nil {
                            Button("Connect ChatGPT") { Task { await host.connectChatGPT() } }
                        } else {
                            Button("Close tunnel") { Task { await host.disconnectChatGPT() } }
                        }
                    } label: {
                        Label("ChatGPT", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    if let url = host.chatGPTConnectorURL {
                        HStack {
                            Text(url).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Spacer()
                            Button("Copy", systemImage: "doc.on.doc") { host.copyToClipboard(url) }
                        }
                        Text("In ChatGPT: Settings → Apps & Connectors → Advanced → turn on Developer mode, then Create, paste this URL and choose “No authentication”. Keep the URL private: it's the key to your agentim. It changes if the tunnel restarts.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let note = host.connectorNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Use agentim from Claude & ChatGPT")
                } footer: {
                    Text("Adds agentim as a connector (MCP), so Claude and ChatGPT can ask your local models and agents, make images and videos with LTX, and run your startups. Claude talks to it on this Mac; ChatGPT needs a temporary public HTTPS tunnel (Cloudflare).")
                }

                if let error = host.lastError {
                    Section {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        Button("Report this on GitHub", systemImage: "ladybug") {
                            IssueReporter.open(kind: .bug, title: "This Mac: ", details: "```\n\(error)\n```")
                        }
                    }
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
        case "voice": "Voice (Whisper + Kokoro)"
        case "tunnel": "ChatGPT tunnel (Cloudflare)"
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
        Button("Free memory (unload models)") { Task { await host.freeMemory() } }
        Button("Stop LTX Desktop") { Task { await host.stopLTX() } }
        Divider()
        Button("Open agentim") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Report an issue…") { IssueReporter.open(kind: .bug) }
        Divider()
        Button("Quit agentim") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
