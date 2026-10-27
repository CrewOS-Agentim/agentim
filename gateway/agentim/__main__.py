"""python -m agentim: start the gateway, its channels and the default-model bootstrap."""

import logging
import os
import threading

from . import __version__, config as config_lib, skills as skill_lib
from .core import Gateway
from .llm import LLM
from .models import Catalog, bootstrap
from .server import serve
from .store import Store

BANNER = r"""
     .-'''-.
    / o   o \     agentim {version}
   |  (___)  |    Agent Tim is on the switchboard.
    \ ~~~~~ /     channels: {channels}
   /|/|/|/|/|\    models:   {runners}
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
    gateway = Gateway(config, Store(os.path.join(config.data_dir, "agentim.db")), LLM(config), catalog,
                      skill_lib.load_dir(config.skills_dir))
    channels = build_channels(config, gateway)
    print(BANNER.format(
        version=__version__, channels=", ".join(channels) or "none configured (see .env)",
        runners=", ".join(config.runner_urls)), flush=True)
    if not any(config.allowed.values()):
        logging.warning("AGENTIM_ALLOWED_USERS is empty: Agent Tim will reply to strangers with their id only.")

    threading.Thread(target=bootstrap, args=(config, catalog), daemon=True).start()
    for channel in channels.values():
        channel.start()
    serve(gateway, channels, catalog, config.port)


if __name__ == "__main__":
    main()
