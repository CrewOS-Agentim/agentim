import XCTest
@testable import AgentHub

final class HostControllerTests: XCTestCase {
    func testComposeJSONLines() {
        let output = """
        {"Service":"runner","State":"running","Health":""}
        {"Service":"gateway","State":"running","Health":"healthy"}
        {"Service":"whatsapp","State":"exited","Health":""}
        """
        let services = HostController.parseComposePS(output)
        XCTAssertEqual(services.map(\.name), ["gateway", "runner", "whatsapp"])
        XCTAssertEqual(services.filter(\.isRunning).count, 2)
        XCTAssertEqual(services.first?.health, "healthy")
    }

    func testComposeJSONArray() {
        let output = #"[{"Service":"ollama","State":"running"},{"Service":"runner","State":"restarting"}]"#
        let services = HostController.parseComposePS(output)
        XCTAssertEqual(services.map(\.state), ["running", "restarting"])
    }

    func testComposeGarbage() {
        XCTAssertEqual(HostController.parseComposePS("no configuration file provided"), [])
    }

    func testPower() {
        XCTAssertEqual(HostController.parsePower("Now drawing from 'AC Power'\n -InternalBattery-0"), .charger)
        XCTAssertEqual(HostController.parsePower("Now drawing from 'Battery Power'"), .battery)
        XCTAssertEqual(HostController.parsePower(""), .unknown)
    }

    func testSleepDisabled() {
        XCTAssertTrue(HostController.parseSleepDisabled(" sleep 0\n SleepDisabled\t\t1\n"))
        XCTAssertFalse(HostController.parseSleepDisabled(" SleepDisabled\t\t0\n"))
        XCTAssertFalse(HostController.parseSleepDisabled(" sleep 1\n displaysleep 10\n"))  // omitted when off
    }

    func testEnv() {
        let env = HostController.parseEnv("""
        # comment
        RUNNER_TOKEN=abc123
        QUOTED="x y"
        EMPTY=
        """)
        XCTAssertEqual(env["RUNNER_TOKEN"], "abc123")
        XCTAssertEqual(env["QUOTED"], "x y")
        XCTAssertEqual(env["EMPTY"], "")
        XCTAssertNil(env["# comment"])
    }

    func testFindStackRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let deep = root.appendingPathComponent("build/DD/Build/Products/Debug/agentim.app")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("gateway"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: root.appendingPathComponent("docker-compose.yml").path, contents: Data())
        XCTAssertEqual(HostController.findStackRoot(from: deep)?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertNil(HostController.findStackRoot(from: FileManager.default.temporaryDirectory.appendingPathComponent("nope")))
    }

    @MainActor
    func testDemoIsHealthy() {
        let host = HostController(demo: true)
        XCTAssertTrue(host.isHealthy)
        XCTAssertEqual(host.summary, "All 4 services running")
    }

    @MainActor
    func testDemoNeverOverwritesTheSavedStackRoot() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "stackRoot")
        defer { defaults.set(previous, forKey: "stackRoot") }
        defaults.set("/real/stack", forKey: "stackRoot")
        _ = HostController(demo: true)
        XCTAssertEqual(defaults.string(forKey: "stackRoot"), "/real/stack")
    }

    func testSavedStackRootMustHoldTheComposeFile() throws {
        XCTAssertNil(HostController.validStackRoot("/Users/you/agentim"))
        XCTAssertNil(HostController.validStackRoot(nil))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("docker-compose.yml").path, contents: Data())
        XCTAssertEqual(HostController.validStackRoot(dir.path)?.standardizedFileURL, dir.standardizedFileURL)
    }

    /// Regression: chatty commands (docker pulling gigabytes) used to deadlock on a full pipe.
    func testShellHandlesLotsOfOutput() async {
        let result = await Shell.run(["sh", "-c", "yes agentim | head -c 2000000; echo done >&2"])
        XCTAssertTrue(result.ok)
        XCTAssertGreaterThan(result.output.count, 2_000_000)
        XCTAssertTrue(result.output.hasSuffix("done\n"))
    }

    func testShellReportsFailure() async {
        let result = await Shell.run(["sh", "-c", "echo nope; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.output, "nope\n")
    }

    func testMacMemoryIsSane() {
        XCTAssertGreaterThan(DeviceMemory.availableToAppBytes, 0)
        XCTAssertLessThanOrEqual(DeviceMemory.availableToAppBytes, DeviceMemory.physicalBytes)
        XCTAssertEqual(DeviceMemory.appCeilingBytes, Int64(Double(DeviceMemory.physicalBytes) * 0.75))
    }

    func testDecodesModelsInMemory() throws {
        let json = #"{"models":[{"id":"ollama/qwen3:4b","name":"qwen3:4b","size_bytes":5100000000,"vram_bytes":0}],"ltx_running":true}"#
        let loaded = try JSONDecoder().decode(HostController.LoadedResponse.self, from: Data(json.utf8))
        XCTAssertEqual(loaded.models.first?.name, "qwen3:4b")
        XCTAssertEqual(loaded.models.first?.gigabytes, "5.1 GB")
        XCTAssertEqual(loaded.ltx_running, true)
    }

    func testParsesDockerPS() {
        let output = """
        {"Names":"agentim-ollama-1","State":"running","Status":"Up 2 hours","Labels":"com.docker.compose.project=agentim,com.docker.compose.service=ollama"}
        {"Names":"agentim-gateway-1","State":"running","Status":"Up 1 minute (unhealthy)","Labels":"com.docker.compose.service=gateway,x=y"}
        {"Names":"agentim-voice-1","State":"exited","Status":"Exited (1) 3 minutes ago","Labels":"com.docker.compose.service=voice"}
        not json
        """
        let containers = HostController.parseDockerPS(output)
        XCTAssertEqual(containers.map(\.service), ["gateway", "ollama", "voice"])
        XCTAssertEqual(containers.first { $0.service == "voice" }?.isRunning, false)
        XCTAssertEqual(containers.first { $0.service == "gateway" }?.status, "Up 1 minute (unhealthy)")
        XCTAssertEqual(containers.first { $0.service == "ollama" }?.name, "agentim-ollama-1")
    }

    func testLogFilter() {
        let log = "loading model qwen\nserving on :11434\nModel unloaded"
        XCTAssertEqual(LogsView.filter(log, by: "model"), "loading model qwen\nModel unloaded")
        XCTAssertEqual(LogsView.filter(log, by: "  "), log, "blank filter shows everything")
        let ollama = """
        [GIN] 2026/10/28 - 18:44:41 | 200 | 21µs | 172.21.0.4 | GET      "/api/ps"
        time=2026-10-28T18:45:00 level=INFO msg="loading model" model=qwen3
        [GIN] 2026/10/28 - 18:45:25 | 200 | 38µs | 172.21.0.4 | GET      "/api/version"
        [GIN] 2026/10/28 - 18:45:30 | 200 | 2.1s | 172.21.0.4 | POST     "/v1/chat/completions"
        """
        XCTAssertEqual(LogsView.withoutStatusChecks(ollama).split(separator: "\n").count, 2,
                       "model loading and chat requests stay; polling goes")
    }

    func testParsesDockerStats() {
        let output = """
        {"Name":"agentim-ollama-1","CPUPerc":"312.50%","MemUsage":"2.71GiB / 7.65GiB","MemPerc":"35.43%"}
        {"Name":"someone-else-1","CPUPerc":"1.00%","MemUsage":"1MiB / 7.65GiB","MemPerc":"0.01%"}
        {"Name":"agentim-gateway-1","CPUPerc":"0.40%","MemUsage":"61MiB / 7.65GiB","MemPerc":"0.78%"}
        """
        let stats = StatusModel.parseDockerStats(output)
        XCTAssertEqual(stats.map(\.service), ["gateway", "ollama"], "only agentim's containers")
        XCTAssertEqual(stats[1].cpuPercent, 312.5)
        XCTAssertEqual(stats[1].memoryUsage, "2.71GiB / 7.65GiB")
    }

    func testDecodesTasks() throws {
        let json = #"{"running":[{"id":"a","model":"ollama/qwen3:4b","label":"Telegram chat","preview":"hi","started":10,"seconds":2.5}],"recent":[{"id":"b","model":"ltx/video","label":"API chat","started":5,"ended":8,"seconds":75.0,"ok":false,"error":"busy"}],"now":12}"#
        let snapshot = try JSONDecoder().decode(StatusModel.TaskSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.running.first?.modelName, "qwen3:4b")
        XCTAssertEqual(snapshot.running.first?.duration, "2.5 s")
        XCTAssertEqual(snapshot.recent.first?.duration, "1 min 15 s")
        XCTAssertEqual(snapshot.recent.first?.ok, false)
    }

    func testMacCPUAndMemoryReadings() {
        XCTAssertNotNil(StatusModel.cpuTicks())
        let memory = StatusModel.memory()
        XCTAssertEqual(memory.total, ProcessInfo.processInfo.physicalMemory)
        XCTAssertGreaterThan(memory.used, 0)
        XCTAssertLessThan(memory.fraction, 1.0)
    }
}
