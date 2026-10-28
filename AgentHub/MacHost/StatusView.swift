import Charts
import SwiftUI

/// Status: which models are running, CPU and memory (the Mac and each container), and the tasks the models
/// are working on now and before.
struct StatusView: View {
    @Environment(HostController.self) private var host
    @State private var status = StatusModel(demo: AppStore.isDemo)
    @State private var sort = [KeyPathComparator(\StatusModel.Task.started, order: .reverse)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.s6) {
                overview
                modelsSection
                containersSection
                tasksSection
            }
            .padding(Theme.s6)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Status")
        .onAppear { status.start(host: host) }
        .onDisappear { status.stop() }
    }

    // MARK: - Overview cards

    private var overview: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.s4), count: 4), spacing: Theme.s4) {
            MetricCard(title: "CPU", value: percent(status.cpu), detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores",
                       symbol: "cpu", history: status.cpuHistory, tint: .purple)
            MetricCard(title: "Memory", value: gigabytes(status.memory.used),
                       detail: "of \(gigabytes(status.memory.total)) · \(percent(status.memory.fraction))",
                       symbol: "memorychip", history: status.memoryHistory, tint: .blue)
            MetricCard(title: "Models in memory", value: "\(host.loadedModels.count)",
                       detail: host.loadedModels.isEmpty ? "none loaded" : host.memoryInUse,
                       symbol: "brain", history: nil, tint: .green)
            MetricCard(title: "Tasks running", value: "\(status.running.count)",
                       detail: "\(status.recent.count) in history", symbol: "bolt.horizontal", history: nil, tint: .orange)
        }
    }

    // MARK: - Models

    private var modelsSection: some View {
        StatusSection(title: "Models running", symbol: "brain") {
            if host.loadedModels.isEmpty {
                Text("No models in memory. They load on the next message and unload 5 minutes after their last use.")
                    .foregroundStyle(.secondary)
            }
            ForEach(host.loadedModels) { model in
                HStack {
                    Circle().fill(.green).frame(width: 8, height: 8)
                    Text(model.name).font(.body.weight(.medium))
                    Spacer()
                    Text(model.gigabytes).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            HStack {
                Circle().fill(host.ltxRunning ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text("LTX Desktop (video & images)")
                Spacer()
                Text(host.ltxRunning ? "running" : "closed").foregroundStyle(.secondary)
            }
            HStack {
                Button("Free memory", systemImage: "memorychip") { Task { await host.freeMemory() } }
                    .disabled(host.loadedModels.isEmpty)
                Button("Stop LTX", systemImage: "stop.circle") { Task { await host.stopLTX() } }
                    .disabled(!host.ltxRunning)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Containers

    private var containersSection: some View {
        StatusSection(title: "Containers", symbol: "shippingbox") {
            if status.containers.isEmpty {
                Text(host.dockerRunning ? "Reading docker stats…" : "Docker is off.").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: Theme.s4, verticalSpacing: Theme.s2) {
                if !status.containers.isEmpty {
                    GridRow {
                        Text("Container"); Text("CPU"); Text("Memory"); Text("")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                ForEach(status.containers) { container in
                    GridRow {
                        Text(container.service).font(.body.weight(.medium))
                        Text(String(format: "%.1f%%", container.cpuPercent)).monospacedDigit()
                        Text(container.memoryUsage).monospacedDigit().foregroundStyle(.secondary)
                        ProgressView(value: min(container.memoryPercent, 100), total: 100)
                            .frame(width: 140)
                            .tint(container.memoryPercent > 80 ? .orange : .accentColor)
                    }
                }
            }
            Text("CPU above 100% means more than one core. Memory is out of Docker's limit.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Tasks

    private var tasksSection: some View {
        StatusSection(title: "Tasks", symbol: "list.bullet.rectangle") {
            Text("Running now").font(.headline)
            if status.running.isEmpty {
                Text("Nothing running.").foregroundStyle(.secondary)
            }
            ForEach(status.running) { task in
                HStack(spacing: Theme.s3) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.label).font(.body.weight(.medium))
                        Text("\(task.modelName) · \(task.runner ?? "")" + (task.preview.map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(task.duration).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Divider().padding(.vertical, Theme.s1)
            Text("History").font(.headline)
            Table(status.recent.sorted(using: sort), sortOrder: $sort) {
                TableColumn("When", value: \.started) { task in
                    Text(task.startedAt.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                }
                .width(min: 120, ideal: 150)
                TableColumn("Task", value: \.label) { task in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.label)
                        if let preview = task.preview, !preview.isEmpty {
                            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                TableColumn("Model", value: \.model) { task in Text(task.modelName) }
                    .width(min: 120, ideal: 180)
                TableColumn("Time", value: \.started) { task in Text(task.duration).monospacedDigit() }
                    .width(70)
                TableColumn("Result") { task in
                    if task.ok == true {
                        Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .help(task.error ?? "")
                    }
                }
                .width(80)
            }
            .frame(minHeight: 260)
        }
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func gigabytes(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let history: [Double]?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s2) {
            Label(title, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText())
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let history, history.count > 1 {
                Chart(Array(history.enumerated()), id: \.offset) { point in
                    AreaMark(x: .value("t", point.offset), y: .value("v", point.element))
                        .foregroundStyle(tint.opacity(0.18))
                    LineMark(x: .value("t", point.offset), y: .value("v", point.element))
                        .foregroundStyle(tint)
                }
                .chartYScale(domain: 0...1)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 36)
                .accessibilityLabel("\(title) over the last two minutes")
            } else {
                Spacer().frame(height: 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Theme.radius, padding: Theme.s4)
    }
}

private struct StatusSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Label(title, systemImage: symbol).font(.title3.weight(.semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: Theme.radius, padding: Theme.s4)
    }
}
