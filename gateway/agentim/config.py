"""Settings from environment variables plus the agents file."""

import json
import os
from dataclasses import dataclass, field

DEFAULT_MODELS = [
    # Hugging Face GGUF builds, served by Ollama in Docker. Checked against host memory before pulling.
    "hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M",
    "hf.co/bartowski/Llama-3.2-3B-Instruct-GGUF:Q4_K_M",
]


@dataclass
class Agent:
    name: str
    emoji: str = "🤖"
    summary: str = ""
    system_prompt: str = ""
    skills: list = field(default_factory=list)
    model: str = "auto"
    prefer_local: bool = True
    avatar: str = ""  # image path relative to the config folder (the Mac app shows it)

    @property
    def slug(self):
        return self.name.lower().replace(" ", "-")


@dataclass
class Config:
    runner_urls: list
    runner_token: str = ""
    anthropic_key: str = ""
    openai_key: str = ""
    telegram_token: str = ""
    slack_bot_token: str = ""
    slack_app_token: str = ""
    waha_url: str = ""
    waha_api_key: str = ""
    waha_session: str = "default"
    webhook_secret: str = ""
    mcp_secret: str = ""
    api_token: str = ""
    # {"telegram": {"123"}, "slack": {"U01"}, "whatsapp": {"15551234567@c.us"}}; "*" allows everyone.
    allowed: dict = field(default_factory=dict)
    default_models: list = field(default_factory=lambda: list(DEFAULT_MODELS))
    priority: str = "balanced"
    keep_sensitive_local: bool = True
    show_route: bool = True
    data_dir: str = "/data"
    skills_dir: str = ""
    agents: list = field(default_factory=list)
    port: int = 8780
    voice_url: str = ""
    stt_model: str = "Systran/faster-whisper-small"
    tts_model: str = "speaches-ai/Kokoro-82M-v1.0-ONNX"
    tts_voice: str = "af_heart"
    voice_replies: bool = True
    # Skills Tim interviews founders with, and how many follow-up questions he asks.
    startup_skills: list = field(default_factory=lambda: ["yc-partner", "co-founder"])
    startup_questions: int = 10


def parse_allowed(raw):
    """'telegram:123,slack:U01,whatsapp:*' -> {'telegram': {'123'}, 'slack': {'U01'}, 'whatsapp': {'*'}}."""
    allowed = {}
    for item in filter(None, (part.strip() for part in raw.split(","))):
        channel, _, user = item.partition(":")
        if user:
            allowed.setdefault(channel.strip().lower(), set()).add(user.strip())
    return allowed


def load_agents(path):
    with open(path) as f:
        return [Agent(**entry) for entry in json.load(f)]


def from_env(env=None):
    env = os.environ if env is None else env
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    agents_path = env.get("AGENTIM_AGENTS", os.path.join(here, "config", "agents.json"))
    flag = lambda key, default: env.get(key, str(default)).lower() in ("1", "true", "yes")
    models = env.get("AGENTIM_DEFAULT_MODELS")
    return Config(
        runner_urls=[u.strip().rstrip("/") for u in env.get("RUNNER_URLS", "http://runner:8765").split(",") if u.strip()],
        runner_token=env.get("RUNNER_TOKEN", ""),
        anthropic_key=env.get("ANTHROPIC_API_KEY", ""),
        openai_key=env.get("OPENAI_API_KEY", ""),
        telegram_token=env.get("TELEGRAM_BOT_TOKEN", ""),
        slack_bot_token=env.get("SLACK_BOT_TOKEN", ""),
        slack_app_token=env.get("SLACK_APP_TOKEN", ""),
        waha_url=env.get("WAHA_URL", "").rstrip("/"),
        waha_api_key=env.get("WAHA_API_KEY", ""),
        waha_session=env.get("WAHA_SESSION", "default"),
        webhook_secret=env.get("AGENTIM_WEBHOOK_SECRET", ""),
        mcp_secret=env.get("AGENTIM_MCP_SECRET", ""),
        api_token=env.get("AGENTIM_API_TOKEN", env.get("RUNNER_TOKEN", "")),
        allowed=parse_allowed(env.get("AGENTIM_ALLOWED_USERS", "")),
        default_models=[m.strip() for m in models.split(",") if m.strip()] if models is not None else list(DEFAULT_MODELS),
        priority=env.get("AGENTIM_PRIORITY", "balanced"),
        keep_sensitive_local=flag("AGENTIM_KEEP_SENSITIVE_LOCAL", True),
        show_route=flag("AGENTIM_SHOW_ROUTE", True),
        data_dir=env.get("AGENTIM_DATA_DIR", "/data"),
        skills_dir=env.get("AGENTIM_SKILLS_DIR", os.path.join(here, "skills")),
        agents=load_agents(agents_path),
        port=int(env.get("AGENTIM_PORT", "8780")),
        voice_url=env.get("VOICE_URL", "").rstrip("/"),
        stt_model=env.get("AGENTIM_STT_MODEL", "Systran/faster-whisper-small"),
        tts_model=env.get("AGENTIM_TTS_MODEL", "speaches-ai/Kokoro-82M-v1.0-ONNX"),
        tts_voice=env.get("AGENTIM_TTS_VOICE", "af_heart"),
        voice_replies=flag("AGENTIM_VOICE_REPLIES", True),
        startup_skills=[s.strip() for s in env.get("AGENTIM_STARTUP_SKILLS", "yc-partner,co-founder").split(",") if s.strip()],
        startup_questions=int(env.get("AGENTIM_STARTUP_QUESTIONS", "10")),
    )
