"""Picks a model per message. Same rules as the iOS app's ModelRouter."""

import os
import re
from dataclasses import dataclass, field

CODE = ["```", "func ", "def ", "const ", "=>", "();", "stack trace", "exception", "compile", "bug", "refactor",
        "regex", "sql", "swift", "python", "javascript", "typescript", "kotlin", "unit test", "error:"]
REASONING = ["prove", "step by step", "why does", "analyze", "analyse", "trade-off", "tradeoff", "compare",
             "calculate", "solve", "plan", "strategy", "estimate", "math", "validate"]
CREATIVE = ["story", "poem", "write a", "draft", "rewrite", "slogan", "lyrics", "blog post", "tone", "script"]
VIDEO = ["make a video", "generate a video", "create a video", "render a video", "video of", "video clip",
         "animate ", "animation of", "short film", "film of"]
IMAGE = ["make an image", "generate an image", "create an image", "image of", "picture of", "photo of",
         "draw ", "illustrate", "illustration of", "render an image", "poster of", "thumbnail of"]
SENSITIVE = ["password", "passcode", "ssn", "social security", "diagnosis", "medical", "my salary", "bank account",
             "private key", "api key", "secret", "confidential", "therapy"]
MEDIA = {"video", "image"}
# Never picked automatically: only when the message names them (@ltx-video, @claude-code, @codex).
EXPLICIT_ONLY = MEDIA | {"agent"}


@dataclass
class Model:
    id: str
    alias: str
    backend: str          # "runner" | "anthropic" | "openai"
    name: str             # what the backend calls it
    caps: set
    context: int = 32_768
    cost: int = 0         # 0 = free/local ... 4 = most expensive
    quality: int = 3      # 1..5
    local: bool = True
    runner_url: str = ""

    @property
    def is_media(self):
        return bool(self.caps) and self.caps <= MEDIA

    @property
    def explicit_only(self):
        return bool(self.caps) and self.caps <= EXPLICIT_ONLY


@dataclass
class Profile:
    primary: str
    tokens: int
    sensitive: bool


@dataclass
class Decision:
    model: Model
    fallbacks: list
    reason: str
    text: str
    profile: Profile = field(default=None)


class NoModel(Exception):
    pass


def classify(text, history_chars=0):
    lower = text.lower()
    tokens = max(1, (len(text) + history_chars) // 4)
    has = lambda words: any(w in lower for w in words)
    if has(VIDEO):
        primary = "video"
    elif has(IMAGE):
        primary = "image"
    elif tokens > 24_000:
        primary = "longContext"
    elif has(CODE):
        primary = "coding"
    elif has(REASONING):
        primary = "reasoning"
    elif has(CREATIVE):
        primary = "creative"
    elif len(text) < 160:
        primary = "fast"
    else:
        primary = "general"
    sensitive = has(SENSITIVE) or re.search(r"\b(?:\d[ -]?){9,19}\b", lower) is not None
    return Profile(primary, tokens, sensitive)


def extract_override(text):
    """'@qwen3 hi' -> ('qwen3', 'hi'). Email addresses are left alone."""
    match = re.search(r"(?:^|\s)@([A-Za-z0-9._\-/:]+)", text)
    if not match:
        return None, text
    cleaned = (text[:match.start()] + " " + text[match.end():]).strip()
    return match.group(1), cleaned


def billions(text):
    matches = re.findall(r"(\d+(?:\.\d+)?)\s*([bBmM])\b", text or "")
    if not matches:
        return None
    value, unit = matches[-1]
    return float(value) / (1000 if unit.lower() == "m" else 1)


def model_from_runner(info, runner_url):
    """Router metadata for a runner model, guessed from its name and size."""
    mid = info["id"]
    short = mid.split("/")[-1]
    if info.get("kind") == "claude":
        # Claude through the founder's Claude login (claude -p on the Mac): a real chat model, no API key.
        # AGENTIM_CLAUDE_LOGIN=explicit: only when picked (an agent's model, @sonnet), so background work stays local.
        tier = {"opus": (5, 4), "sonnet": (4, 3), "haiku": (3, 1)}.get(short, (4, 3))
        explicit = os.environ.get("AGENTIM_CLAUDE_LOGIN", "auto") == "explicit"
        return Model(id=mid, alias=short, backend="runner", name=mid,
                     caps=({"agent"} if explicit else set()) | {"coding", "reasoning", "creative", "longContext", "general"}
                     | ({"fast"} if short == "haiku" else set()),
                     context=200_000, cost=tier[1], quality=tier[0], local=False, runner_url=runner_url)
    if info.get("kind") == "agent":
        # A local coding agent (Claude Code, Codex…): @claude-code / @codex.
        return Model(id=mid, alias=short, backend="runner", name=mid, caps={"agent"}, context=10_000_000,
                     quality=5, runner_url=runner_url)
    if info.get("kind") in MEDIA:
        kind = info["kind"]
        return Model(id=mid, alias=f"ltx-{kind}", backend="runner", name=mid, caps={kind},
                     context=10_000_000, quality=4, runner_url=runner_url)
    lower = mid.lower()
    size = billions(info.get("parameter_size") or mid)
    caps = {"general"}
    if any(w in lower for w in ("coder", "code", "devstral")):
        caps.add("coding")
    if any(w in lower for w in ("r1", "qwq", "think", "reason", "magistral")):
        caps.add("reasoning")
    if size is not None and size <= 4:
        caps.add("fast")
    if size is not None and size >= 14:
        caps |= {"reasoning", "creative"}
    if size is None:
        quality = 3
    else:
        quality = 1 if size < 2 else 2 if size < 6 else 3 if size < 15 else 4 if size < 40 else 5
    alias = short.lower().split(":")[0].replace("-gguf", "")
    return Model(id=mid, alias=alias, backend="runner", name=mid, caps=caps, quality=quality, runner_url=runner_url)


CLOUD_MODELS = {
    "anthropic": [
        Model("anthropic/claude-opus-5-5", "opus", "anthropic", "claude-opus-5-5",
              {"coding", "reasoning", "creative", "longContext", "general"}, 200_000, 4, 5, False),
        Model("anthropic/claude-sonnet-5-5", "sonnet", "anthropic", "claude-sonnet-5-5",
              {"coding", "reasoning", "creative", "longContext", "general"}, 200_000, 3, 4, False),
        Model("anthropic/claude-haiku-5-5", "haiku", "anthropic", "claude-haiku-5-5",
              {"fast", "general", "coding"}, 200_000, 1, 3, False),
    ],
    "openai": [
        Model("openai/gpt-5", "gpt5", "openai", "gpt-5", {"coding", "reasoning", "creative", "general"}, 400_000, 3, 5, False),
        Model("openai/gpt-5-mini", "gpt5mini", "openai", "gpt-5-mini", {"fast", "general", "coding"}, 400_000, 1, 3, False),
    ],
}


class Router:
    def __init__(self, models, priority="balanced", keep_sensitive_local=True, prefer_local=True):
        self.models = models
        self.priority = priority
        self.keep_sensitive_local = keep_sensitive_local
        self.prefer_local = prefer_local

    def find(self, alias):
        alias = alias.lower()
        return next((m for m in self.models if m.alias.lower() == alias or m.id.lower() == alias), None)

    def score(self, model, profile):
        score = float(model.quality)
        if profile.primary in model.caps:
            score += 4
        if "general" in model.caps:
            score += 0.5
        if self.priority == "economy":
            score -= model.cost * 1.5
        elif self.priority == "balanced":
            score -= model.cost * 0.75
        else:
            score += model.quality * 0.75
        if profile.primary == "fast":
            score -= max(0, model.quality - 3) * 1.5
        if profile.primary in ("reasoning", "coding", "longContext"):
            score -= max(0, 3 - model.quality) * 2
        if self.prefer_local and model.local:
            score += 3
        return score

    def candidates(self, profile):
        if profile.primary in MEDIA:
            return [m for m in self.models if profile.primary in m.caps]
        return [m for m in self.models if not m.explicit_only]

    def local_agents(self):
        """Coding agents on the Mac: Claude Code first, then Codex (ChatGPT), then any other."""
        rank = {"claude-code": 0, "codex": 1}
        return sorted((m for m in self.models if "agent" in m.caps),
                      key=lambda m: rank.get(m.id.rsplit("/", 1)[-1], 2))

    def ranked(self, profile):
        fitting = [m for m in self.candidates(profile) if m.context >= profile.tokens + 1024]
        return sorted(fitting, key=lambda m: (-self.score(m, profile), m.alias))

    def route(self, text, history_chars=0, pinned=None, agent=None):
        alias, cleaned = extract_override(text)
        profile = classify(cleaned, history_chars)
        if profile.primary in MEDIA and not any(profile.primary in m.caps for m in self.models):
            profile.primary = "creative"

        def decide(model, reason):
            return Decision(model, [m for m in self.ranked(profile) if m.id != model.id], reason, cleaned, profile)

        if alias:
            model = self.find(alias)
            if not model:
                raise NoModel(f"No model called @{alias}. Send /models to see them.")
            return decide(model, f"you asked for @{model.alias}")
        if pinned and (model := self.find(pinned)):
            return decide(model, "pinned for this chat")
        if agent and agent.model != "auto" and (model := self.find(agent.model)):
            return decide(model, f"{agent.name} is pinned to it")

        ranking = self.ranked(profile)
        if not ranking and profile.primary not in MEDIA and (agents := self.local_agents()):
            # No chat model is up: Claude Code (then Codex, i.e. ChatGPT) on the Mac answers instead.
            return Decision(agents[0], agents[1:], f"no local model is running, so {agents[0].alias} answers",
                            cleaned, profile)
        if not ranking:
            raise NoModel("No models are ready yet. Agent Tim is still pulling them, try again in a minute.")
        if profile.sensitive and self.keep_sensitive_local:
            local = [m for m in ranking if m.local]
            if local:
                return decide(local[0], "looks sensitive, kept on your machine")
        best = ranking[0]
        task = "quick question" if profile.primary == "fast" else f"{profile.primary} task"
        return Decision(best, ranking[1:], f"{task}, {self.priority} mode", cleaned, profile)
