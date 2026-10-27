<p align="center">
  <img src="docs/assets/banner.png" alt="agentim: Agent Tim routes every chat to the right AI" width="100%">
</p>

<p align="center">
  <b>Chat with your AI agents from Telegram, WhatsApp and Slack.</b><br>
  Agent Tim, a secret-agent octopus on a switchboard, plugs every message into the right model:<br>
  private Hugging Face models in Docker on your always-on Mac, LTX video, and cloud models when you want them.
</p>

<p align="center">
  <a href="https://doron2402.github.io/agentim/"><b>Website</b></a> ·
  <a href="#-quick-start">Quick start</a> ·
  <a href="#-how-it-works">How it works</a> ·
  <a href="#-the-mac-app">Mac app</a> ·
  <a href="#-skills">Skills</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <a href="https://github.com/doron2402/agentim/actions"><img alt="tests" src="https://github.com/doron2402/agentim/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="license" src="https://img.shields.io/badge/license-MIT-8b5cf6">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-1d1d1f?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-f05138?logo=swift&logoColor=white">
  <img alt="Docker" src="https://img.shields.io/badge/Docker-compose-2496ed?logo=docker&logoColor=white">
  <img alt="Hugging Face" src="https://img.shields.io/badge/%F0%9F%A4%97-Hugging%20Face-ffcc4d">
</p>

---

<img src="docs/assets/agent-tim-demo.gif" align="right" width="300" alt="Agent Tim, the agentim mascot, bouncing on his switchboard">

### 🐙 Meet Agent Tim

`agent·im` → **Agent Tim**. He's an octopus, so he has eight arms for eight jobs:

- 💬 answers you on **Telegram, WhatsApp and Slack**
- 🤗 runs **Hugging Face models in Docker** on your own Mac, after checking they fit in memory
- 🧭 **routes every message**: quick question → small fast model; code → coder model; secrets → never leave your Mac; "make a video" → LTX
- 🪄 comes with **built-in skills**: Validate Your Startup, YouTube Channel Creator, Software Engineer, Product Manager, Project Manager, Video Director
- 🎬 **makes videos** with LTX Desktop, locally and for free, and sends them back to your chat
- 🔌 **stays up**: the lid closes, the Mac is on the charger, and Tim is still answering. Anything that stops gets started again.
- 🖥️ ships with a **native macOS app** (Swift/SwiftUI) to manage it all
- ☁️ and if you *want* the cloud, Claude, GPT and Gemini plug in too

<br clear="right">

## 🚀 Quick start

You need a Mac with Apple silicon, [Docker Desktop](https://www.docker.com/products/docker-desktop/), and five minutes.

```sh
git clone https://github.com/doron2402/agentim.git && cd agentim

# 1. Always-on: creates .env with fresh secrets, installs the restart watchdog,
#    the LTX runner and the lid-close power guard (asks for your password once)
./deploy/macos/install.sh

# 2. Add your Telegram bot token (from @BotFather) and/or Slack tokens,
#    plus who's allowed to talk to Tim
open -e .env

# 3. Start everything. Hugging Face models download on first start.
docker compose up -d
```

Then message your bot: `/help`, `/agents`, `/validate-your-startup an app for…`, `/video a cat surfing at sunset`.

**WhatsApp:** open <http://localhost:3000/dashboard> and scan the QR code with *WhatsApp → Linked devices*.
**Who can talk to Tim:** strangers only get a polite "who are you?" with their id. Add `channel:id` pairs to `AGENTIM_ALLOWED_USERS`.

<details>
<summary><b>Getting Telegram and Slack tokens</b></summary>

- **Telegram:** chat with [@BotFather](https://t.me/BotFather) → `/newbot` → paste the token into `TELEGRAM_BOT_TOKEN`.
- **Slack:** [create an app](https://api.slack.com/apps):
  - turn on **Socket Mode** and create an app token (`xapp-…`, scope `connections:write`) → `SLACK_APP_TOKEN`
  - give the bot the scopes `app_mentions:read chat:write files:write im:history im:read`
  - subscribe to the bot events `app_mention` and `message.im`
  - install the app, then copy the bot token (`xoxb-…`) → `SLACK_BOT_TOKEN`

  No public URL is needed, for Slack or Telegram.
</details>

## 🧠 How it works

```
 Telegram ─┐                    ┌──────────────── your Mac ────────────────┐
 WhatsApp ─┼──► gateway ──► router ──► runner ──► Ollama (Hugging Face GGUF, Docker)
 Slack ────┘    agents          │        │   └──► memory check before every pull
                skills          │        └──────► LTX Desktop (video/image, native)
                history         └──► Claude / GPT (optional; never for sensitive prompts)
```

| Piece | What it is | Where |
|---|---|---|
| **gateway** | Connects Telegram (long polling), Slack (Socket Mode) and WhatsApp (WAHA bridge) to agents, skills, per-chat memory and the router. | [`gateway/`](gateway) · Python, in Docker |
| **runner** | One OpenAI-compatible API over Ollama, LM Studio, llama.cpp, vLLM and Docker Model Runner. Reports host memory, **refuses models that won't fit**, and bridges LTX Desktop. | [`runner/`](runner) · Python, standard library only |
| **models** | Hugging Face GGUF builds served by Ollama in Docker. Defaults: Qwen3-4B-Instruct-2507 and Llama 3.2 3B (Q4_K_M), memory-checked before download. | [`docker-compose.yml`](docker-compose.yml) |
| **always-on** | A watchdog restarts Docker and the stack, a power guard disables lid-close sleep *only on the charger*, and the Mac boots again after a power cut. | [`deploy/macos/`](deploy/macos) · [`deploy/linux/`](deploy/linux) |
| **Mac app** | A native SwiftUI app: chats, agents, skills, models, on-Mac MLX models, and the **This Mac** control center, plus a menu bar icon. | [`AgentHub/`](AgentHub) · Swift |

### The router

Each message is classified (code, reasoning, writing, quick, long context, video, image, sensitive) and sent to the best model you have. **Local models are preferred by default.** The order of precedence is:

1. `@alias` in the message (`@qwen3-4b-instruct-2507 explain this`)
2. the model pinned to the chat (`/model <alias>`)
3. the model pinned to the agent
4. sensitive-looking prompts (passwords, medical, card numbers…) go to a local model
5. "make a video/image" goes to LTX; text never goes to media models
6. the best score for the task, weighed by quality, cost and your *economy / balanced / quality* setting

If a model fails, the next one in the ranking answers. Every reply says which model answered and why.

### Memory check

Before any download, the runner looks up the real file sizes from the Ollama registry or Hugging Face. It then estimates the memory needed: weights × 1.2 + 512 MB. The verdict depends on how that compares with the machine:

| Verdict | When | Pull |
|---|---|---|
| `fits` | it fits in the memory free right now | allowed |
| `tight` | it fits the machine, but not with what's free now | allowed, with a warning |
| `too_large` | it's bigger than one model may use (about 75% of RAM on Apple silicon) | refused (HTTP 409) |
| `not_enough_disk` | there isn't enough free disk space | refused (HTTP 409) |

## 🖥 The Mac app

<p align="center"><img src="docs/assets/screenshots/chat.png" alt="agentim for macOS: chats" width="90%"></p>

<table>
  <tr>
    <td><img src="docs/assets/screenshots/host.png" alt="This Mac control center"></td>
    <td><img src="docs/assets/screenshots/models.png" alt="Models: Hugging Face in Docker and LTX"></td>
  </tr>
  <tr>
    <td align="center"><b>This Mac</b>: start the stack, keep it awake, launch at login</td>
    <td align="center"><b>Models</b>: Hugging Face in Docker, LTX, on-Mac MLX, cloud</td>
  </tr>
</table>

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # once; MLX needs it
xcodegen generate && open agentim.xcodeproj     # ⌘R
```

The app can also run Hugging Face **MLX** models directly on your Mac's GPU, after the same memory check. Use **Models → Browse Hugging Face**.

## 🪄 Skills

Skills are plain `SKILL.md` files in [`gateway/skills/`](gateway/skills). They're shared by the gateway and the Mac app. An agent uses a skill when a message contains one of its trigger words, or when anyone types `/skill-name`.

| Skill | Try |
|---|---|
| 🚀 **Validate Your Startup**: problem, customers, market math, riskiest assumption, a <$100 test | `/validate-your-startup Uber for dog walking` |
| 🎬 **YouTube Channel Creator**: niche, names, calendar, titles, thumbnails, hooks | `/youtube-channel-creator cooking for students` |
| 🧑‍💻 **Software Engineer**: debugging, design trade-offs, reviews with the bugs first | `/software-engineer why does this deadlock?` |
| 🧭 **Product Manager**: one-page PRDs, RICE, metrics | `/product-manager PRD for dark mode` |
| 📋 **Project Manager**: plans, critical path, risks, status updates | `/project-manager plan a launch in 6 weeks` |
| 🎥 **Video Director**: idea → on-model shot prompts → LTX clips | `/video-director a 20 s teaser for my app` |

Adding your own is as easy as dropping a markdown file in that folder:

```markdown
---
name: Release Notes
description: Turn a changelog into release notes people read
triggers: release notes, changelog
---
Group changes by user benefit, lead with the biggest one, keep it under 200 words.
```

## 🎬 Making videos

With [LTX Desktop](https://ltx.studio) open on the Mac, the native runner (installed by `install.sh`) adds `ltx/video` and `ltx/image`. In any chat:

```
/video a tiny purple cartoon octopus in sunglasses surfing a wave made of chat bubbles
```

Agent Tim renders it locally, for free, and sends the clip back to Telegram, WhatsApp or Slack. The clip on the [website](https://doron2402.github.io/agentim/#video) was made exactly this way.

## 🔒 Privacy & security

- **Local by default.** Models run on your machine, and cloud keys are optional.
- **Sensitive prompts never go to the cloud**, even when cloud models are configured.
- **Allow-list.** Only the users in `AGENTIM_ALLOWED_USERS` get answers.
- **Tokens everywhere.** The runner and gateway APIs need a bearer token, and the WhatsApp webhook needs a secret. The WAHA dashboard is bound to localhost.
- WhatsApp uses [WAHA](https://waha.devlike.pro/), which links like WhatsApp Web. It isn't the official Business API, so use a number you're comfortable linking.

## 🧪 Tests

```sh
python3 -m unittest discover -s gateway/tests     # gateway: router, skills, channels, API
(cd runner && python3 -m unittest test_runner)    # runner: memory check, refs, LTX chat
python3 -m unittest discover -s deploy/tests      # always-on scripts and launchd plists
xcodebuild -project agentim.xcodeproj -scheme AgentHub -destination platform=macOS \
  -skipMacroValidation -skipPackagePluginValidation test   # Mac app
```

CI runs all four on every push.

## 🗺 Roadmap

- [ ] Sync agents and skills between the Mac app and the gateway
- [ ] Voice notes in and out (Whisper + Kokoro)
- [ ] Discord and iMessage channels
- [ ] One-click Hugging Face model picker in the Mac app for the Docker stack

## 🤝 Contributing

PRs are welcome, especially new skills, channels and model backends. See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

[MIT](LICENSE). Agent Tim was drawn and animated locally with LTX Desktop. No octopuses were harmed. 🐙
