import XCTest
@testable import AgentHub

final class ModelCatalogTests: XCTestCase {
    private let gb: Int64 = 1_073_741_824

    func testEveryCategoryHasOptions() {
        for category in ModelCategory.allCases {
            XCTAssertFalse(ModelCatalog.options(for: category).isEmpty, category.title)
        }
        XCTAssertEqual(Set(ModelCatalog.all.map(\.id)).count, ModelCatalog.all.count, "ids are unique")
    }

    func testGGUFRefsAreHuggingFaceQ4() {
        for choice in ModelCatalog.all {
            guard let ref = choice.ollamaRef else { continue }
            XCTAssertTrue(ref.hasPrefix("hf.co/"), ref)
            XCTAssertTrue(ref.hasSuffix(":Q4_K_M"), ref)
            XCTAssertGreaterThan(choice.sizeBytes, 0, ref)
        }
    }

    func testSmallMacGetsSmallModels() {
        // 8 GB Mac → Docker gets ~4 GB.
        let chat = ModelCatalog.recommended(for: .chat, memory: 4 * gb, ltxInstalled: false)
        XCTAssertLessThanOrEqual(ModelCatalog.requiredBytes(chat), 4 * gb * 70 / 100)
        XCTAssertEqual(ModelCatalog.recommended(for: .voice, memory: 4 * gb, ltxInstalled: false).id, "voice-base")
        let coding = ModelCatalog.recommended(for: .coding, memory: 4 * gb, ltxInstalled: false)
        XCTAssertTrue(coding.kind == .none || ModelCatalog.requiredBytes(coding) <= 4 * gb * 70 / 100)
    }

    func testMidMacGetsTheDefaults() {
        let memory = 12 * gb
        XCTAssertEqual(ModelCatalog.recommended(for: .chat, memory: memory, ltxInstalled: false).id, "chat-qwen3-4b")
        XCTAssertEqual(ModelCatalog.recommended(for: .coding, memory: memory, ltxInstalled: false).id, "code-qwen2.5-7b")
        XCTAssertEqual(ModelCatalog.recommended(for: .voice, memory: memory, ltxInstalled: false).id, "voice-small")
    }

    func testBigMacStepsUpButNotToThe30B() {
        let chat = ModelCatalog.recommended(for: .chat, memory: 64 * gb, ltxInstalled: true)
        XCTAssertEqual(chat.id, "chat-qwen3-14b")
        XCTAssertEqual(ModelCatalog.recommended(for: .coding, memory: 64 * gb, ltxInstalled: true).id, "code-qwen2.5-14b")
    }

    func testMediaFollowsLTX() {
        XCTAssertEqual(ModelCatalog.recommended(for: .media, memory: 16 * gb, ltxInstalled: true).kind, .ltx)
        XCTAssertEqual(ModelCatalog.recommended(for: .media, memory: 16 * gb, ltxInstalled: false).kind, .none)
    }

    func testFits() {
        let big = ModelCatalog.choice(id: "chat-qwen3-30b")!
        XCTAssertFalse(ModelCatalog.fits(big, memory: 16 * gb))
        XCTAssertTrue(ModelCatalog.fits(big, memory: 32 * gb))
        XCTAssertTrue(ModelCatalog.fits(ModelCatalog.choice(id: "code-same")!, memory: 0))
    }
}

final class EnvFileTests: XCTestCase {
    func testSetKeepsCommentsAndOrder() {
        var env = EnvFile(text: "# header\nA=1\n# B=old\nC=3\n")
        env.set("A", "one")
        env.set("B", "two")      // replaces the commented-out line
        env.set("D", "four")     // appended
        XCTAssertEqual(env.text, "# header\nA=one\nB=two\nC=3\nD=four\n")
        XCTAssertEqual(env["B"], "two")
        XCTAssertNil(env["# header"])
    }

    func testFillSecrets() {
        var env = EnvFile(text: "RUNNER_TOKEN=change-me\nKEEP=mine\n")
        env.fillSecrets { "s3cr3t" }
        XCTAssertEqual(env["RUNNER_TOKEN"], "s3cr3t")
        XCTAssertEqual(env["KEEP"], "mine")
        XCTAssertEqual(EnvFile.randomSecret().count, 48)
        XCTAssertNotEqual(EnvFile.randomSecret(), EnvFile.randomSecret())
    }

    func testPlanWithVoiceAndLTX() {
        let plan = OnboardingPlan(chat: ModelCatalog.choice(id: "chat-qwen3-4b")!, coding: ModelCatalog.choice(id: "code-qwen2.5-7b")!,
                                  voice: ModelCatalog.choice(id: "voice-turbo")!, media: ModelCatalog.choice(id: "media-ltx")!)
        var env = EnvFile(text: "TELEGRAM_BOT_TOKEN=123:abc\n")
        plan.apply(to: &env)
        XCTAssertEqual(env["AGENTIM_DEFAULT_MODELS"],
                       "hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M,hf.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF:Q4_K_M")
        XCTAssertEqual(env["COMPOSE_PROFILES"], "voice")
        XCTAssertEqual(env["VOICE_URL"], "http://voice:8000")
        XCTAssertEqual(env["AGENTIM_STT_MODEL"], "deepdml/faster-whisper-large-v3-turbo-ct2")
        XCTAssertEqual(env["AGENTIM_LTX"], "true")
        XCTAssertEqual(env["TELEGRAM_BOT_TOKEN"], "123:abc", "user settings survive")
        XCTAssertEqual(plan.ollamaRefs.count, 2)
    }

    func testAppleSiliconGetsTheArmWhatsAppBridge() {
        let plan = OnboardingPlan(chat: ModelCatalog.choice(id: "chat-qwen3-4b")!, coding: ModelCatalog.choice(id: "code-same")!,
                                  voice: ModelCatalog.choice(id: "voice-off")!, media: ModelCatalog.choice(id: "media-off")!)
        var arm = EnvFile(text: "WAHA_TAG=latest\n")
        plan.apply(to: &arm, appleSilicon: true)
        XCTAssertEqual(arm["WAHA_TAG"], "arm")
        var intel = EnvFile(text: "")
        plan.apply(to: &intel, appleSilicon: false)
        XCTAssertEqual(intel["WAHA_TAG"], "latest")
    }

    /// Every image the stack pulls must exist for the Mac it runs on (WAHA's :latest is Intel-only).
    func testComposeLetsTheWhatsAppTagFollowTheMac() throws {
        let stack = try XCTUnwrap(StackFiles.bundled)
        let compose = try String(contentsOf: stack.appendingPathComponent("docker-compose.yml"), encoding: .utf8)
        XCTAssertTrue(compose.contains("devlikeapro/waha:${WAHA_TAG:-latest}"))
        XCTAssertFalse(compose.contains("image: devlikeapro/waha:latest"))
    }

    func testBlockedRegistryTriggersTheVoiceFallback() {
        XCTAssertTrue(OnboardingModel.isRegistryBlocked("Error response from daemon: error from registry: denied"))
        XCTAssertTrue(OnboardingModel.isRegistryBlocked("unauthorized: authentication required"))
        XCTAssertFalse(OnboardingModel.isRegistryBlocked("no space left on device"))
        XCTAssertTrue(OnboardingModel.fallbackVoiceImage.hasPrefix("fedirz/"), "must come from Docker Hub")
    }

    func testDockerFailuresAreExplained() {
        let creds = OnboardingModel.explainDockerFailure("Error getting credentials - err: signal: terminated, out: ``")
        XCTAssertTrue(creds.contains("Keychain"))
        XCTAssertTrue(OnboardingModel.explainDockerFailure("error from registry: denied").contains("Docker Desktop"))
        XCTAssertTrue(OnboardingModel.explainDockerFailure("Cannot connect to the Docker daemon at unix://").contains("isn't running"))
        XCTAssertTrue(OnboardingModel.explainDockerFailure("write /var/lib: no space left on device").contains("disk space"))
        XCTAssertEqual(OnboardingModel.explainDockerFailure("  something else  "), "something else")
    }

    func testPlanWithoutVoiceOrCoderModel() {
        let plan = OnboardingPlan(chat: ModelCatalog.choice(id: "chat-llama3.2-3b")!, coding: ModelCatalog.choice(id: "code-same")!,
                                  voice: ModelCatalog.choice(id: "voice-off")!, media: ModelCatalog.choice(id: "media-off")!)
        var env = EnvFile(text: "")
        plan.apply(to: &env)
        XCTAssertEqual(env["AGENTIM_DEFAULT_MODELS"], "hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M")
        XCTAssertEqual(env["COMPOSE_PROFILES"], "")
        XCTAssertEqual(env["VOICE_URL"], "")
        XCTAssertEqual(env["AGENTIM_LTX"], "false")
        XCTAssertEqual(plan.downloadBytes, ModelCatalog.choice(id: "chat-llama3.2-3b")!.sizeBytes)
    }
}

final class StackBundleTests: XCTestCase {
    func testAppShipsTheDockerStack() throws {
        let stack = try XCTUnwrap(StackFiles.bundled, "stack folder missing from the app bundle")
        for path in ["docker-compose.yml", ".env.example", "gateway/Dockerfile", "gateway/agentim/core.py",
                     "gateway/skills/validate-your-startup.md", "runner/runner.py", "deploy/macos/install.sh"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stack.appendingPathComponent(path).path), path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stack.appendingPathComponent("gateway/tests").path),
                       "tests aren't shipped")
    }

    /// Onboarding starts services by name; they must match the compose file it ships.
    func testCoreServicesMatchTheComposeFile() throws {
        let stack = try XCTUnwrap(StackFiles.bundled)
        let compose = try String(contentsOf: stack.appendingPathComponent("docker-compose.yml"), encoding: .utf8)
        let servicesBlock = try XCTUnwrap(compose.components(separatedBy: "\nservices:\n").last?.components(separatedBy: "\nvolumes:\n").first)
        let names = servicesBlock.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":") else { return nil }
            return line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ":", with: "")
        }
        XCTAssertEqual(Set(names), Set(OnboardingModel.coreServices + HostController.optionalServices))
        XCTAssertEqual(Set(HostController.services), Set(OnboardingModel.coreServices))
    }

    func testInstallCopiesStackAndKeepsEnv() throws {
        let fm = FileManager.default
        let target = StackFiles.installedRoot
        let backup = target.deletingLastPathComponent().appendingPathComponent("stack-backup-\(UUID().uuidString)")
        if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: backup) }
        defer {
            try? fm.removeItem(at: target)
            if fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: target) }
        }
        let root = try StackFiles.ensureInstalled(repoRoot: nil)
        try "KEEP=me\n".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        _ = try StackFiles.ensureInstalled(repoRoot: nil)  // a second run (app update) keeps .env
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8), "KEEP=me\n")
        XCTAssertTrue(fm.isExecutableFile(atPath: root.appendingPathComponent("deploy/macos/install.sh").path))
        // A stale copy (from an older app version) is refreshed even when passed back in as the root.
        let compose = root.appendingPathComponent("docker-compose.yml")
        try "image: devlikeapro/waha:latest\n".write(to: compose, atomically: true, encoding: .utf8)
        _ = try StackFiles.ensureInstalled(repoRoot: root)
        XCTAssertTrue(try String(contentsOf: compose, encoding: .utf8).contains("${WAHA_TAG:-latest}"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8), "KEEP=me\n")
        let repo = URL(fileURLWithPath: "/tmp/some-repo")
        XCTAssertEqual(try StackFiles.ensureInstalled(repoRoot: repo), repo, "a repo checkout is used as-is")
    }
}
