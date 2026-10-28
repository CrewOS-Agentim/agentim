import Foundation

/// Sample content for screenshots and previews. Launch with `-demo YES` (optionally `-tab N`,
/// `-openChat YES`); it uses a throwaway store so real data is never touched.
extension AppStore {
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "demo") }
    /// Running as the unit-test host: skip startup work that reads the Keychain (it can block on a prompt).
    static var isTesting: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    static func demo() -> AppStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentim-demo-\(UUID().uuidString).json")
        let store = AppStore(fileURL: url)
        store.seedDemo()
        return store
    }

    func seedDemo() {
        let mac = LocalServer(name: "Mac Studio", baseURL: URL(string: "http://mac-studio.local:8765")!)
        let infos: [ServerModelInfo] = [
            .init(id: "ollama/hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M", kind: "chat",
                  size_bytes: 2_500_000_000, parameter_size: "4.0B", loaded: true),
            .init(id: "ollama/hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M", kind: "chat",
                  size_bytes: 2_000_000_000, parameter_size: "3.2B", loaded: false),
            .init(id: "ollama/qwen2.5-coder:14b", kind: "chat", size_bytes: 9_000_000_000, parameter_size: "14.8B", loaded: false),
            .init(id: "ltx/video", kind: "video", size_bytes: nil, parameter_size: nil, loaded: nil),
            .init(id: "ltx/image", kind: "image", size_bytes: nil, parameter_size: nil, loaded: nil),
        ]
        servers = [mac]
        serverModels = infos.map { AIModel.server($0, on: mac) }
        markOnline(mac.id, system: RunnerClient.System(
            hostname: "mac-studio.local", os: "Darwin arm64", version: "0.1.0", in_container: true,
            memory: .init(total_bytes: 64 * 1_073_741_824, available_bytes: 41 * 1_073_741_824, ceiling_bytes: 48 * 1_073_741_824),
            gpus: [.init(name: "Apple silicon (unified memory)", memory_bytes: nil)],
            backends: ["ollama": .init(url: "http://ollama:11434", healthy: true)], ltx: true))

        let qwen = serverModels[0], coder = serverModels[2], video = serverModels[3]
        func agent(_ name: String) -> UUID { agents.first { $0.name == name }?.id ?? agents[0].id }
        func chat(_ title: String, _ agentName: String, minutesAgo: Double, _ turns: [(String, String, AIModel, String)]) -> Conversation {
            var conversation = Conversation(title: title, agentID: agent(agentName))
            for (question, answer, model, reason) in turns {
                conversation.messages.append(ChatMessage(role: .user, content: question))
                conversation.messages.append(ChatMessage(role: .assistant, content: answer, modelID: model.id, routingReason: reason))
            }
            conversation.updatedAt = Date().addingTimeInterval(-minutesAgo * 60)
            return conversation
        }

        conversations = [
            chat("Office plant subscription?", "Startup Validator", minutesAgo: 2, [(
                "Validate my startup idea: a monthly subscription that delivers and swaps office plants.",
                """
                **The idea:** offices (who) lose plants and morale to neglect (problem); we deliver and swap plants monthly (solution).

                **Riskiest assumption:** office managers will pay *monthly* for something they buy once today.

                **Cheapest test this week:**
                • 10 calls with office managers: "When did a plant last die? Who dealt with it?"
                • Landing page at $49/mo, pass if 5% of 200 visitors join the waitlist

                🟡 **Promising but sharpen** the buyer: target landlords of shared workspaces first.
                """, qwen, "Reasoning task → Qwen3 4B (strong at reasoning, balanced mode) · 🪄 Validate Your Startup")]),
            chat("Channel about octopus facts", "YouTube Creator", minutesAgo: 18, [(
                "Give me 3 title ideas for my first video about octopus intelligence",
                """
                1. **Octopuses Have 9 Brains. Here's What They Do** (52 chars)
                2. **I Tried to Outsmart an Octopus (I Lost)**
                3. **The Alien Genius Living in Your Sea**

                Thumbnail: close-up eye, one curious tentacle on a jar lid, text "9 BRAINS?" in yellow.
                """, qwen, "Creative task → Qwen3 4B · 🪄 YouTube Channel Creator")]),
            chat("Make Agent Tim surf", "YouTube Creator", minutesAgo: 41, [(
                "/video a tiny purple octopus in sunglasses surfing a wave of chat bubbles",
                "Rendering video with LTX Desktop… done. 🎬", video, "Video task → LTX Video (on your Mac)")]),
            chat("Swift actor deadlock", "Software Engineer", minutesAgo: 95, [(
                "Why does my Swift code hang when I call an actor method from MainActor in a loop?",
                """
                Likely **actor reentrancy + a semaphore**: `DispatchSemaphore.wait()` blocks the main thread while the actor's task needs it to resume.

                ```swift
                // ❌ blocks the main actor
                semaphore.wait()
                // ✅ await instead
                let value = await cache.value(for: key)
                ```
                Regression test: call it 1,000× in a `Task` group with a 2 s timeout.
                """, coder, "Coding task → qwen2.5-coder 14B · 🪄 Software Engineer")]),
            chat("PRD: dark mode", "Product Manager", minutesAgo: 240, [(
                "One-page PRD for dark mode",
                "**Problem:** 38% of sessions start after 8 pm; users report eye strain.\n**Metric:** night-time session length +10%.\n**Non-goals:** custom themes.",
                qwen, "General task → Qwen3 4B · 🪄 Product Manager")]),
        ]
    }
}
