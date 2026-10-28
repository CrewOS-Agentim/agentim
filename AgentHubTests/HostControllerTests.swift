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
}
