"""Messaging channels. Each one turns platform events into Gateway.handle calls and sends the replies back."""

import logging
import threading
import urllib.request

log = logging.getLogger("agentim.channels")

MAX_TEXT = 3500


def chunks(text, size=MAX_TEXT):
    """Splits long replies on paragraph or line breaks so each part fits a chat message."""
    parts = []
    while len(text) > size:
        cut = max(text.rfind("\n\n", 0, size), text.rfind("\n", 0, size))
        cut = cut if cut > size // 2 else size
        parts.append(text[:cut].rstrip())
        text = text[cut:].lstrip()
    if text:
        parts.append(text)
    return parts


def download(url, timeout=120):
    with urllib.request.urlopen(url, timeout=timeout) as resp:
        return resp.read()


class Channel:
    name = "channel"

    def __init__(self, gateway):
        self.gateway = gateway
        self.status = "starting"

    # Platform specifics
    def send_text(self, chat_id, text):
        raise NotImplementedError

    def send_media(self, chat_id, kind, data, filename):
        raise NotImplementedError

    def working(self, chat_id):
        """Shows a typing/working indicator while the model thinks."""

    def deliver(self, chat_id, user_id, text):
        """Runs one message through the gateway and sends every reply back. Never raises."""
        try:
            self.working(chat_id)
            for reply in self.gateway.handle(self.name, chat_id, user_id, text):
                for part in chunks(reply.text):
                    self.send_text(chat_id, part)
                for kind, url in reply.media:
                    ext = url.rsplit(".", 1)[-1]
                    self.send_media(chat_id, kind, download(url), f"agentim.{ext}")
        except Exception:
            log.exception("%s: failed to answer %s", self.name, chat_id)
            try:
                self.send_text(chat_id, "😵 Something went wrong on my side. Try again in a moment.")
            except Exception:
                pass

    def deliver_async(self, chat_id, user_id, text):
        threading.Thread(target=self.deliver, args=(chat_id, user_id, text), daemon=True).start()

    def start(self):
        threading.Thread(target=self.run, name=self.name, daemon=True).start()

    def run(self):
        raise NotImplementedError
