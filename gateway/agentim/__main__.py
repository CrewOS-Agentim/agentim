"""python -m agentim: start the gateway, its channels and the default-model bootstrap."""

import logging
import os
import threading

from . import __version__, config as config_lib, skills as skill_lib
from .core import Gateway
from .llm import LLM
from .models import Catalog, bootstrap
from .server import serve
from .startup import StartupMode, StartupStore
from .store import Store
from .voice import Voice

BANNER = r"""
     .-'''-.
    / o   o \     agentim {version}
   |  (___)  |    Agent Tim is on the switchboard.
    \ ~~~~~ /     channels: {channels}
   /|/|/|/|/|\    models:   {runners}
                  voice:    {voice}
"""


def build_channels(config, gateway):
    channels = {}
    if config.telegram_token:
        from .channels.telegram import Telegram
        channels["telegram"] = Telegram(gateway, config.telegram_token)
    if config.slack_bot_token and config.slack_app_token:
        from .channels.slack import Slack
        channels["slack"] = Slack(gateway, config.slack_bot_token, config.slack_app_token)
    if config.waha_url:
        from .channels.whatsapp import WhatsApp
        channels["whatsapp"] = WhatsApp(gateway, config.waha_url, config.waha_api_key, config.waha_session)
    return channels


def main():
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(name)s %(message)s")
    config = config_lib.from_env()
    catalog = Catalog(config)
    voice = Voice(config.voice_url, config.stt_model, config.tts_model, config.tts_voice)
    store = Store(os.path.join(config.data_dir, "agentim.db"))
    gateway = Gateway(config, store, LLM(config), catalog, skill_lib.load_dir(config.skills_dir),
                      voice if voice.enabled else None)
    channels = build_channels(config, gateway)

    # Startup Mode: the team meets on its own schedule and reports to the chat that started it.
    gateway.startup = StartupMode(gateway, StartupStore(store.db, store.lock))
    gateway.startup.notify = lambda channel, chat_id, text: channels[channel].send_text(chat_id, text) \
        if channel in channels else None
    threading.Thread(target=gateway.startup.loop, name="startup", daemon=True).start()
    print(BANNER.format(
        version=__version__, channels=", ".join(channels) or "none configured (see .env)",
        runners=", ".join(config.runner_urls),
        voice=f"{config.stt_model} + {config.tts_model}" if voice.enabled else "off"), flush=True)
    if not any(config.allowed.values()):
        logging.warning("AGENTIM_ALLOWED_USERS is empty: Agent Tim will reply to strangers with their id only.")

    threading.Thread(target=bootstrap, args=(config, catalog), daemon=True).start()
    for channel in channels.values():
        channel.start()
    serve(gateway, channels, catalog, config.port)


if __name__ == "__main__":
    main()
