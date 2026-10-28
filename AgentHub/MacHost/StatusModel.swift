import Darwin
import Foundation
import Observation

/// Live numbers for the Status page: this Mac's CPU and memory, each container's usage (docker stats)
/// and the tasks the runners are working on.
@MainActor
@Observable
final class StatusModel {
    struct Memory: Equatable {
        var total: UInt64 = 0
        var app: UInt64 = 0
        var wired: UInt64 = 0
        var compressed: UInt64 = 0
        var used: UInt64 { app + wired + compressed }
        var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }
    }

    struct ContainerStats: Identifiable, Equatable {
        let name: String
        let cpuPercent: Double
        let memoryUsage: String   // "512MiB / 7.6GiB"
        let memoryPercent: Double
        var id: String { name }
        var service: String { name.replacingOccurrences(of: "agentim-", with: "").replacingOccurrences(of: #"-\d+$"#, with: "", options: .regularExpression) }
    }

    struct Task: Decodable, Identifiable, Equatable {
        let id: String
        let model: String
        let label: String
        let preview: String?
        let started: Double
        let seconds: Double?
        let ok: Bool?
        let error: String?
        var runner: String? = nil

        var startedAt: Date { Date(timeIntervalSince1970: started) }
        var modelName: String { model.split(separator: "/").last.map(String.init) ?? model }
        var duration: String {
            guard let seconds else { return "" }
            return seconds < 60 ? String(format: "%.1f s", seconds) : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
        }
    }

    struct TaskSnapshot: Decodable { let running: [Task]; let recent: [Task] }

    private(set) var cpu: Double = 0             // 0…1, whole Mac
    private(set) var cpuHistory: [Double] = []
    private(set) var memory = Memory()
    private(set) var memoryHistory: [Double] = []
    private(set) var containers: [ContainerStats] = []
    private(set) var running: [Task] = []
    private(set) var recent: [Task] = []

    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var loop: Swift.Task<Void, Never>?
    private let isDemo: Bool

    init(demo: Bool = false) {
        isDemo = demo
        if demo { seedDemo() }
    }

    /// Samples every 2 s (docker stats every other tick) while the Status page is open.
    func start(host: HostController) {
        guard loop == nil, !isDemo else { return }
        loop = Swift.Task { [weak self] in
            var tick = 0
            while !Swift.Task.isCancelled {
                guard let self else { return }
                self.sampleMac()
                if tick % 2 == 0 {
                    async let stats = Self.dockerStats()
                    async let tasks = host.tasks()
                    let (s, t) = await (stats, tasks)
                    self.containers = s
                    self.running = t.running
                    self.recent = t.recent
                }
                tick += 1
                try? await Swift.Task.sleep(for: .seconds(2))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    // MARK: - This Mac

    private func sampleMac() {
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
                cpuHistory = Array((cpuHistory + [cpu]).suffix(60))
            }
            lastTicks = ticks
        }
        memory = Self.memory()
        memoryHistory = Array((memoryHistory + [memory.fraction]).suffix(60))
    }

    nonisolated static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// Like Activity Monitor's "Memory Used": app memory + wired + compressed.
    nonisolated static func memory() -> Memory {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var memory = Memory(total: ProcessInfo.processInfo.physicalMemory)
        guard result == KERN_SUCCESS else { return memory }
        let page = UInt64(vm_kernel_page_size)
        memory.app = (UInt64(stats.internal_page_count) - min(UInt64(stats.purgeable_count), UInt64(stats.internal_page_count))) * page
        memory.wired = UInt64(stats.wire_count) * page
        memory.compressed = UInt64(stats.compressor_page_count) * page
        return memory
    }

    // MARK: - Containers

    nonisolated static func dockerStats() async -> [ContainerStats] {
        let result = await Shell.run(["docker", "stats", "--no-stream", "--format", "{{json .}}"])
        return result.ok ? parseDockerStats(result.output) : []
    }

    nonisolated static func parseDockerStats(_ output: String) -> [ContainerStats] {
        struct Row: Decodable { let Name: String; let CPUPerc: String; let MemUsage: String; let MemPerc: String }
        func percent(_ text: String) -> Double { Double(text.replacingOccurrences(of: "%", with: "")) ?? 0 }
        return output.split(separator: "\n").compactMap { line -> ContainerStats? in
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line.utf8)), row.Name.hasPrefix("agentim-") else { return nil }
            return ContainerStats(name: row.Name, cpuPercent: percent(row.CPUPerc), memoryUsage: row.MemUsage,
                                  memoryPercent: percent(row.MemPerc))
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - Demo (screenshots)

    private func seedDemo() {
        cpu = 0.34
        cpuHistory = (0..<60).map { 0.2 + 0.15 * sin(Double($0) / 6) + ($0 > 48 ? 0.12 : 0) }
        memory = Memory(total: 34_359_738_368, app: 9_100_000_000, wired: 5_800_000_000, compressed: 1_200_000_000)
        memoryHistory = (0..<60).map { 0.42 + 0.05 * sin(Double($0) / 9) }
        containers = [
            ContainerStats(name: "agentim-gateway-1", cpuPercent: 0.4, memoryUsage: "61MiB / 7.65GiB", memoryPercent: 0.8),
            ContainerStats(name: "agentim-ollama-1", cpuPercent: 312.5, memoryUsage: "2.71GiB / 7.65GiB", memoryPercent: 35.4),
            ContainerStats(name: "agentim-runner-1", cpuPercent: 0.2, memoryUsage: "28MiB / 7.65GiB", memoryPercent: 0.4),
            ContainerStats(name: "agentim-voice-1", cpuPercent: 0.1, memoryUsage: "412MiB / 7.65GiB", memoryPercent: 5.3),
            ContainerStats(name: "agentim-whatsapp-1", cpuPercent: 0.9, memoryUsage: "188MiB / 7.65GiB", memoryPercent: 2.4),
        ]
        let now = Date().timeIntervalSince1970
        running = [Task(id: "r1", model: "ollama/qwen3-4b-instruct-2507", label: "Startup meeting · Leafy · Zoe",
                        preview: "You are Zoe Kim, CRO at \"Leafy\"…", started: now - 12, seconds: 12, ok: nil, error: nil, runner: "Docker")]
        recent = [
            Task(id: "h1", model: "ollama/qwen3-4b-instruct-2507", label: "Startup meeting · Leafy · Leo", preview: nil,
                 started: now - 70, seconds: 41.2, ok: true, error: nil, runner: "Docker"),
            Task(id: "h2", model: "ollama/qwen2.5-coder-7b-instruct", label: "Telegram chat", preview: "Review this function…",
                 started: now - 300, seconds: 8.4, ok: true, error: nil, runner: "Docker"),
            Task(id: "h3", model: "ltx/image", label: "Claude/ChatGPT connector", preview: "a cartoon octopus waving",
                 started: now - 900, seconds: 89.0, ok: true, error: nil, runner: "This Mac"),
            Task(id: "h4", model: "local/claude-code", label: "Mac app chat", preview: "@claude-code review the auth module",
                 started: now - 1500, seconds: 49.3, ok: true, error: nil, runner: "This Mac"),
            Task(id: "h5", model: "ltx/video", label: "Telegram chat", preview: "a cat surfing at sunset",
                 started: now - 4000, seconds: 3.1, ok: false, error: "LTX Desktop is busy with another generation.", runner: "This Mac"),
        ]
    }
}

extension HostController {
    /// Running and recent tasks from both runners (Docker models, and LTX / local agents on this Mac), newest first.
    func tasks() async -> (running: [StatusModel.Task], recent: [StatusModel.Task]) {
        var running: [StatusModel.Task] = [], recent: [StatusModel.Task] = []
        for (port, name) in [(8765, "Docker"), (8766, "This Mac")] {
            guard let data = await runnerData(port, "v1/tasks"),
                  let snapshot = try? JSONDecoder().decode(StatusModel.TaskSnapshot.self, from: data) else { continue }
            running += snapshot.running.map { var t = $0; t.runner = name; return t }
            recent += snapshot.recent.map { var t = $0; t.runner = name; return t }
        }
        return (running.sorted { $0.started > $1.started }, recent.sorted { $0.started > $1.started })
    }
}
