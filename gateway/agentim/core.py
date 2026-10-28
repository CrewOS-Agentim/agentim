"""What happens to every incoming chat message, whatever channel it came from."""

import re
import threading
from dataclasses import dataclass, field

from .claude_sessions import ClaudeSessions
from . import skills as skill_lib
from .llm import LLMError, labelled
from .router import NoModel, Router

MEDIA_LINK = re.compile(r"\[(video|image)\]\((https?://[^)\s]+)\)")

HELP = """🐙 *Agent Tim at your service.* Just talk to me; I route every message to the right model.

/agents: list agents · /agent <name>: switch
/skills: list skills · /<skill-name> in any message to use one
/models: list models · /model <alias>: pin · /model auto
/video <idea>: make a short video · /image <idea>: make a picture
/reset: forget this chat
/startup <your idea>: a team of agents meets every 10–30 min to improve your startup
Tip: start a message with @alias to pick a model just once."""


@dataclass
class Reply:
    text: str
    media: list = field(default_factory=list)  # [(kind, url)]


def split_media(text):
    media = [(kind, url) for kind, url in MEDIA_LINK.findall(text)]
    return MEDIA_LINK.sub("", text).strip(), media


class Gateway:
    def __init__(self, config, store, llm, models_provider, skills, voice=None):
        self.config = config
        self.voice = voice  # agentim.voice.Voice, or None when voice isn't set up
        self.startup = None  # agentim.startup.StartupMode, attached by __main__
        self.claude = ClaudeSessions(config)  # existing Claude Code sessions on the Mac (via the native runner)
        self.store = store
        self.llm = llm
        self.models_provider = models_provider  # () -> [Model]
        self.skills = skills
        self.agents = {a.slug: a for a in config.agents}
        self.locks = {}
        self.locks_guard = threading.Lock()

    # ---- access

    def allowed(self, channel, user_id):
        if channel == "api":
            return True  # the HTTP API already requires the gateway token (the Mac app, scripts)
        users = self.config.allowed.get(channel, set())
        return "*" in users or str(user_id) in users

    def default_agent(self):
        return self.config.agents[0]

    def agent_for(self, key):
        return self.agents.get(self.store.agent(key) or "", self.default_agent())

    def router(self):
        return Router(self.models_provider(), self.config.priority, self.config.keep_sensitive_local)

    # ---- entry point

    def handle(self, channel, chat_id, user_id, text):
        text = (text or "").strip()
        if not text:
            return []
        if not self.allowed(channel, user_id):
            return [Reply(f"🐙 Agent Tim doesn't know you yet. Ask the owner to add `{channel}:{user_id}` "
                          "to AGENTIM_ALLOWED_USERS.")]
        key = f"{channel}:{chat_id}"
        # One message at a time per chat keeps history in order.
        with self.locks_guard:
            lock = self.locks.setdefault(key, threading.Lock())
        with lock:
            # Answering Tim's follow-up questions about a new startup.
            answering = not text.startswith("/") or text.lower() == "/skip"
            if self.startup and answering:
                interview = self.startup.pending_interview(channel, chat_id)
                if interview:
                    return [Reply(self.startup.handle_answer(interview, text.lstrip("/")))]
            if text.lower().split(" ")[0].split("@")[0] == "/startup":
                if not self.startup:
                    return [Reply("🚀 Startup Mode isn't available on this gateway.")]
                return [Reply(self.startup.command(channel, chat_id, text.partition(" ")[2]))]
            if text.startswith("/"):
                reply = self.command(key, text)
                if reply is not None:
                    return [reply]
            return [self.answer(key, text)]

    # ---- commands

    def command(self, key, text):
        cmd, _, arg = text.partition(" ")
        cmd, arg = cmd.lower().split("@")[0], arg.strip()
        if cmd in ("/start", "/help"):
            return Reply(HELP)
        if cmd == "/reset":
            self.store.reset(key)
            return Reply("🧽 Fresh start! I forgot this chat.")
        if cmd == "/agents":
            current = self.agent_for(key)
            lines = [f"{'👉 ' if a is current else ''}{a.emoji} *{a.name}* (`/agent {a.slug}`): {a.summary}"
                     for a in self.config.agents]
            return Reply("\n".join(lines))
        if cmd == "/agent":
            agent = self.agents.get(arg.lower().replace(" ", "-"))
            if not agent:
                return Reply("🤔 No agent by that name. Try /agents.")
            self.store.set_agent(key, agent.slug)
            return Reply(f"{agent.emoji} You're now talking to *{agent.name}*. {agent.summary}")
        if cmd == "/skills":
            return Reply("\n".join(f"🪄 */{s.slug}*: {s.summary}" for s in self.skills) or "No skills installed.")
        if cmd == "/models":
            models = self.models_provider()
            if not models:
                return Reply("⏳ No models ready yet, I'm still pulling them.")
            pinned = self.store.pinned(key)
            return Reply("\n".join(
                f"{'📌 ' if m.alias == pinned else ''}{'🏠' if m.local else '☁️'} @{m.alias}: {m.id}" for m in models))
        if cmd == "/model":
            if not arg or arg == "auto":
                self.store.set_pinned(key, None)
                return Reply("🪄 Back to automatic routing.")
            model = self.router().find(arg.lstrip("@"))
            if not model:
                return Reply("🤔 Unknown model. Try /models.")
            self.store.set_pinned(key, model.alias)
            return Reply(f"📌 Pinned *@{model.alias}* for this chat. `/model auto` to undo.")
        if cmd == "/claude":
            return Reply(self.claude.command(arg))
        if cmd in ("/video", "/image"):
            if not arg:
                return Reply(f"🎬 Tell me what to make, e.g. `{cmd} a cat surfing at sunset`.")
            verb = "Make a video of" if cmd == "/video" else "Make an image of"
            return self.answer(key, f"{verb} {arg}")
        return None  # /skill-name and anything else go to the model

    # ---- answering

    @staticmethod
    def task_label(key):
        """How a chat shows on the Status page: "Telegram chat", "Claude/ChatGPT connector", …"""
        channel, _, chat_id = key.partition(":")
        if chat_id.startswith("mcp-"):
            return "Claude/ChatGPT connector"
        return {"api": "API chat", "whatsapp": "WhatsApp chat"}.get(channel, f"{channel.capitalize()} chat")

    def answer(self, key, text):
        agent = self.agent_for(key)
        history = self.store.history(key)
        try:
            decision = self.router().route(
                text, sum(len(m["content"]) for m in history), self.store.pinned(key), agent)
        except NoModel as e:
            return Reply(f"🙈 {e}")

        chosen = skill_lib.active(self.skills, set(agent.skills), decision.text)
        system = skill_lib.system_prompt(agent.system_prompt, chosen)
        messages = history + [{"role": "user", "content": decision.text}]

        last_error = None
        for model in [decision.model] + decision.fallbacks[:2]:
            try:
                with labelled(self.task_label(key)):
                    output = self.llm.complete(model, system, messages)
            except LLMError as e:
                last_error = e
                continue
            if not output:
                continue
            self.store.add(key, "user", decision.text)
            self.store.add(key, "assistant", output, model.id)
            body, media = split_media(output)
            if self.config.show_route:
                reason = decision.reason if model is decision.model else "fallback after an error"
                tags = "".join(f" · 🪄{s.name}" for s in chosen)
                body = f"{body}\n\n_— {agent.emoji} {agent.name} via @{model.alias} ({reason}){tags}_".strip()
            return Reply(body, media)
        return Reply(f"😵 All my tentacles are tangled: {last_error or 'no model answered'}")
