# AgentHub

A native SwiftUI iOS app that puts your cloud agents, on-device models, skills and conversations in one place, with a router that picks the right model for each message.

## Features

- **Agents**: assistants (instructions, skills and a routing preference) or **cloud agents**, meaning any hosted agent behind an OpenAI-compatible `/chat/completions` endpoint.
- **Skills**: reusable instruction blocks in the same format as `SKILL.md`. A skill turns on when it is attached to the agent and the message contains a trigger word, or when you type `/skill-name`. You can import skills by pasting a `SKILL.md` file.
- **Models**: a cloud catalog for Anthropic, OpenAI, Gemini, OpenRouter and Hugging Face Inference Providers. You can also add any custom model id.
- **On-device models**: connect your Hugging Face account, search MLX models, and download them to run offline with [MLX Swift](https://github.com/ml-explore/mlx-swift-lm).
  - **Memory check**: before any download, the app fetches the repo's real file sizes and estimates the memory needed: weights × 1.2 + 400 MB.
  - It compares that estimate with what the app can use right now (`os_proc_available_memory`), the device's per-app limit (about 60% of RAM with the increased-memory-limit entitlement), and free disk space.
  - Models rated **too large** or **not enough storage** can't be downloaded. Models rated **tight** show a warning.
- **Router** (`AgentHub/Routing`), in order of precedence:
  1. `@alias` in the message, for example `@opus explain this`
  2. the model pinned to the conversation (toolbar menu in a chat)
  3. the model pinned to the agent
  4. offline → the best installed local model
  5. sensitive-looking prompt (passwords, medical, card numbers…) → a local model, if that setting is on
  6. the agent prefers on-device → a local model
  7. scoring: how well the model's strengths match the task (code, reasoning, writing, quick, long context), its quality and cost tiers, the Economy/Balanced/Quality setting, and whether the conversation fits the context window

  The composer shows which model a message will go to and why, before you send it. If a model errors before producing any output, the next-ranked model is tried, up to two fallbacks.
- **Security**: API keys and the Hugging Face token are stored in the Keychain on this device only. App data is a single JSON file with complete file protection.

## Build

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # MLX needs it; one-time download
xcodegen generate
open AgentHub.xcodeproj
```

Command-line build and tests:

```sh
xcodebuild -project AgentHub.xcodeproj -scheme AgentHub \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipMacroValidation -skipPackagePluginValidation test
```

On-device inference needs a **real iPhone or iPad** (Apple silicon GPU). In the simulator, local models report a clear error and the router uses cloud models. To run on a device, set your signing team in Xcode. The `increased-memory-limit` entitlement is already in `AgentHub.entitlements`.

## Layout

| Path | What |
|---|---|
| `Models/` | Provider, AIModel (capabilities, cost and quality tiers), Agent, Skill, Conversation |
| `Routing/` | `PromptClassifier` (task profile) and `ModelRouter` (decision, reason, fallbacks) |
| `Providers/` | streaming clients: Anthropic Messages API, OpenAI-compatible, SSE parsing |
| `Local/` | Hugging Face Hub client, `DeviceMemory` assessment, downloader, MLX client |
| `Store/` | `AppStore` (state, persistence, send pipeline), Keychain |
| `Features/` | SwiftUI screens: Chats, Agents, Skills, Models (+ HF browser), Settings |
