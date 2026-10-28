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

- 💬 answers you on **Telegram, WhatsApp and Slack**, in text or 🎙️ **voice notes**
- 🤗 runs **Hugging Face models in Docker** on your own Mac, after checking they fit in memory
- 🧭 **routes every message**: quick question → small fast model; code → coder model; secrets → never leave your Mac; "make a video" → LTX
- 🚀 **Startup Mode**: pitch any number of startups; Tim interviews you (10 YC + co-founder questions), then a team of agent employees works on each one every 10–30 minutes
- 🪄 comes with **built-in skills**: Validate Your Startup, YouTube Channel Creator, Software Engineer, Product Manager, Project Manager, Video Director, Web QA, Mobile QA, API Testing, Data Analytics
- 🐞 ships **agents with their own cartoon avatars** (made locally with LTX), including a **QA Engineer** that tests web apps, mobile apps and APIs and a **Data Analyst** that sets up your metrics
- 🎬 **makes videos** with LTX Desktop, locally and for free, and sends them back to your chat
- 🔌 **stays up**: the lid closes, the Mac is on the charger, and Tim is still answering. Anything that stops gets started again.
- 🖥️ ships with a **native macOS app** (Swift/SwiftUI) whose onboarding installs Docker and your models for you
- 🔗 **plugs into Claude and ChatGPT** as a connector (MCP), so they can use your local models, agents, LTX and startups
- ☁️ and if you *want* the cloud, Claude, GPT and Gemini plug in too

<br clear="right">

## 🚀 Quick start

### The easy way: let Agent Tim set himself up

Open the Mac app and the onboarding does the rest:

1. **Docker:** if it isn't installed, agentim downloads Docker Desktop and installs it for you.
2. **Pick your models.** Every option shows its real download size and whether it fits in Docker's memory. The best fit is pre-selected.

   | | Options |
   |---|---|
   | 💬 **Chat** | Qwen3 1.7B · Llama 3.2 3B · **Qwen3 4B** · Gemma 3 12B · Qwen3 14B · Qwen3 30B |
   | 🧑‍💻 **Coding** | use the chat model · Qwen2.5 Coder 1.5B / **7B** / 14B · Qwen3 Coder 30B |
   | 🎙️ **Voice** | off · Whisper Base / **Small** / Large v3 Turbo, each + Kokoro |
   | 🎬 **Video & images** | **LTX Desktop** · skip |

3. **Install.** It sets up the Docker stack (shipped inside the app) and starts the containers. Then it downloads your models with live progress, installs the restart watchdog and connects everything.

<p align="center"><img src="docs/assets/screenshots/onboarding-models.png" alt="agentim onboarding: pick your models" width="85%"></p>

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # once; MLX needs it
xcodegen generate && open agentim.xcodeproj     # ⌘R. Onboarding opens on first launch
```

### The terminal way

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

<p align="center"><img src="docs/assets/screenshots/chat.png" alt="agentim for macOS: a chat with Agent Tim, the big message box and the routing note under each reply" width="90%"></p>
<p align="center"><b>Chats</b>: a roomy message box (Enter sends, Shift+Enter for a new line), drag in files, and every reply says which model answered and why</p>

<table>
  <tr>
    <td><img src="docs/assets/screenshots/agents.png" alt="Agents with their cartoon avatars, including QA Engineer and Data Analyst"></td>
    <td><img src="docs/assets/screenshots/skills.png" alt="Built-in skills including Web QA, Mobile QA, API Testing and Data Analytics"></td>
  </tr>
  <tr>
    <td align="center"><b>Agents</b>: each with its own avatar, skills and model preference</td>
    <td align="center"><b>Skills</b>: QA, data analytics, startup, product, video and more</td>
  </tr>
  <tr>
    <td><img src="docs/assets/screenshots/host.png" alt="This Mac control center"></td>
    <td><img src="docs/assets/screenshots/models.png" alt="Models: Hugging Face in Docker and LTX"></td>
  </tr>
  <tr>
    <td align="center"><b>This Mac</b>: start the stack, keep it awake, connect Claude and ChatGPT</td>
    <td align="center"><b>Models</b>: Hugging Face in Docker, LTX, on-Mac MLX, cloud</td>
  </tr>
</table>

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # once; MLX needs it
xcodegen generate && open agentim.xcodeproj     # ⌘R
```

The app can also run Hugging Face **MLX** models directly on your Mac's GPU, after the same memory check. Use **Models → Browse Hugging Face**.

**Chatting:** a roomy message box that grows as you type; press **Enter** to send (**Shift+Enter** for a new line). **Drag files** into a chat, or click 📎: text, code and PDFs are read into the prompt (up to 10 files, 20 MB and 100k characters each); images and other files are passed by name, since the chat models only read text.

**Found a bug?** **Help → Report an Issue on GitHub…** (also in Settings and the menu bar) opens a new GitHub issue with your app version, macOS, chip and memory filled in. Nothing is sent until you submit it.

## 🔗 Use agentim from Claude & ChatGPT

agentim is also an [MCP](https://modelcontextprotocol.io) server, so Claude and ChatGPT can add it as a connector. They get 11 tools:

| Tool | What it does |
|---|---|
| `ask_agentim` | Answer with your local models (auto-routed), an agent, `@model` or a `/skill` |
| `generate_image`, `generate_video` | Make media with LTX on your Mac (opens LTX Desktop if needed) |
| `list_agents`, `list_skills`, `list_models` | See what's available |
| `list_startups`, `get_startup`, `create_startup`, `answer_startup_questions`, `run_startup_meeting` | Run Startup Mode from the chat |

**Claude Desktop and Claude Code** (stays on your Mac): **This Mac → Add to Claude** in the app, or

```sh
~/Library/Application\ Support/agentim/stack/deploy/macos/connect-claude.sh   # then restart Claude
```

It adds a local server (`deploy/mcp/agentim_mcp.py`) that talks to the gateway on localhost with your token.

**ChatGPT** needs an HTTPS address it can reach, so agentim opens a temporary [Cloudflare quick tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/): **This Mac → Connect ChatGPT**, or

```sh
~/Library/Application\ Support/agentim/stack/deploy/macos/connect-chatgpt.sh        # prints the connector URL
~/Library/Application\ Support/agentim/stack/deploy/macos/connect-chatgpt.sh stop   # closes it
```

In ChatGPT: **Settings → Apps & Connectors → Advanced → Developer mode**, then **Create**, paste the URL and pick **No authentication**. The URL ends in a long random secret (`AGENTIM_MCP_SECRET`) and is the key to your agentim, so keep it private. A quick tunnel gets a new address each time it starts.

Any other MCP client can use `POST http://localhost:8780/mcp` with `Authorization: Bearer <AGENTIM_API_TOKEN or RUNNER_TOKEN>`.

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
| 🌐 **Web QA**: risk-based test plans, Playwright tests, accessibility, flaky-test hygiene, bug reports | `/web-qa test the checkout on staging.example.com` |
| 📱 **Mobile QA**: device matrix, Maestro/XCUITest/Espresso flows, interruptions, offline, store readiness | `/mobile-qa test our iOS onboarding` |
| 🔌 **API Testing**: contract, negative and OWASP API Top 10 checks, pytest + httpx suites, k6 load tests | `/api-testing here's our openapi.yaml` |
| 📊 **Data Analytics**: north star, funnel, retention, tracking plan, dashboards, SQL, experiments | `/data-analytics what should we measure?` |

Adding your own is as easy as dropping a markdown file in that folder:

```markdown
---
name: Release Notes
description: Turn a changelog into release notes people read
triggers: release notes, changelog
---
Group changes by user benefit, lead with the biggest one, keep it under 200 words.
```

## 🚀 Startup Mode

Run **as many startups as you like**, each with its own team of agents who act like real employees.

1. **Pitch it.** Write the pitch in the Mac app (Startups → New startup) or in any chat: `/startup new <your pitch>`.
2. **Get interviewed.** Agent Tim asks **10 follow-up questions**: five as a 🟧 *YC partner* (who desperately needs it, how do you know, why now, what's the insight, how you make money) and five as a 🤝 *co-founder* (why you, commitment and runway, roles, the first 90 days, kill criteria). They come from the `yc-partner` and `co-founder` skills; swap in your own with `AGENTIM_STARTUP_SKILLS`. In the Mac app they come one at a time, with **Back**, **Skip** and **Next** (Return moves on), and a progress bar.
3. **The agents get to work.** Every 10–30 minutes, at a random time, the team of agents meets. You can watch the meeting live in the **Agents room**: who's in it, who's typing, and each message as it lands. Their standing goals: **launch fast, measure, improve**; sales and marketing grow revenue and weekly active users; design ships one improvement every meeting; and Nina (Data Analyst) reports the numbers. The people who spoke least recently report what they did, propose next moves in their own area, and ask colleagues for help by name ("@Leo, can you mock the ROI page?"). Tim (CEO) updates the living plan and sends you a two-line summary in your chat.

| | The team |
|---|---|
| 🧭 Maya Chen, Product Manager | 🎨 Leo Park, Designer · 🛠️ Noah Patel, Engineering Lead |
| 📣 Ava Brooks, Marketing & Social | ⚙️ Sam Rivera, Marketing Automation · 💼 Zoe Kim, Head of Sales |
| 🤝 Omar Haddad, Business Development | 💰 Grace Liu, Finance & Fundraising · 📊 Nina Shah, Data Analyst |
| 🐙 Agent Tim, CEO | |

```
/startup new Leafy: a monthly subscription that swaps office plants   ← pitch (then answer Tim's 10 questions)
/startup        ← your startups      /startup 2   ← plan of #2      /startup now 2   ← meet right away
/startup off 2  ← pause              /startup on 2                   /startup delete 2
```

**Make the team yours.** That's the default team: every startup can have its own (1–12 agents plus Tim). In the Mac app, click **Agents** to rename anyone, change their title, emoji or what they own, **Add agent** from presets (CTO, Customer Success, Growth, Data, Operations, Legal, Recruiter, Community, QA Engineer, Penetration Tester, Security Researcher, Compliance & GRC) or anyone you describe, and remove agents. Agents you remove keep their messages in the agents room, marked *former*; the current team stops seeing them. In chat:

```
/startup team 2                                                    ← who works on #2
/startup hire 2 Jordan Lee | Customer Success | onboarding pilots  ← name | title | what they own
/startup fire 2 Omar                                               ← let someone go
```

<p align="center"><img src="docs/assets/screenshots/startup-team.png" alt="agentim Startup Mode: editing a startup's agents, each with an avatar" width="80%"></p>

It runs in the always-on gateway, so the teams keep working with the app closed, and uses your local models (routed to the strongest reasoning model you have).

<table>
  <tr>
    <td><img src="docs/assets/screenshots/startup-interview.png" alt="Startup interview: one question at a time with Back, Skip and Next"></td>
    <td><img src="docs/assets/screenshots/startup-meeting.png" alt="A live meeting in the agents room: who's in the room and who's typing"></td>
  </tr>
  <tr>
    <td align="center"><b>The interview</b>: one question at a time, Back / Skip / Next</td>
    <td align="center"><b>A live meeting</b>: watch the agents talk as it happens</td>
  </tr>
</table>

<p align="center"><img src="docs/assets/screenshots/startup.png" alt="agentim Startup Mode: startups, the living plan and the agents room" width="85%"></p>
<p align="center"><b>Your startups</b>: the living plan (priorities, metrics, owners) next to the agents room</p>

## 🎙️ Voice

Pick a voice model during onboarding (or set `COMPOSE_PROFILES=voice` in `.env`). The `voice` container ([Speaches](https://github.com/speaches-ai/speaches): Whisper + Kokoro) runs entirely on your Mac.

- **Send a voice note** on Telegram or WhatsApp. Tim transcribes it locally (🎙️ "…"), answers, and **replies with a voice note**. Code and links stay in the text; they aren't read aloud.
- Strangers' audio is never transcribed: the allow-list is checked first.
- Turn spoken replies off with `AGENTIM_VOICE_REPLIES=false`, or change the voice with `AGENTIM_TTS_VOICE` (e.g. `af_heart`).

## 🎬 Making videos

With [LTX Desktop](https://ltx.studio) installed on the Mac, the native runner (installed by `install.sh`) adds `ltx/video` and `ltx/image`, and the router sends "make a video of…" and "an image of…" there, from the Mac app, your chat apps, Claude or ChatGPT. If LTX Desktop is closed, the runner opens it and waits for it to load. In any chat:

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
- [x] Voice notes in and out (Whisper + Kokoro)
- [x] One-click onboarding: Docker + model picker
- [ ] Discord and iMessage channels
- [ ] One-click Hugging Face model picker in the Mac app for the Docker stack

## 🤝 Contributing

PRs are welcome, especially new skills, channels and model backends. See [CONTRIBUTING.md](CONTRIBUTING.md).

Found a bug or want a feature? [Open an issue](https://github.com/doron2402/agentim/issues/new/choose), or use **Help → Report an Issue on GitHub…** in the app.

## 📄 License

[MIT](LICENSE). Agent Tim was drawn and animated locally with LTX Desktop. No octopuses were harmed. 🐙
