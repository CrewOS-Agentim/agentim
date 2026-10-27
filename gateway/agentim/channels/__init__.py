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

    def send_voice(self, chat_id, data):
        """Sends an OGG/Opus voice note. Channels without voice support skip it."""

    def working(self, chat_id):
        """Shows a typing/working indicator while the model thinks."""

    @property
    def voice(self):
        return getattr(self.gateway, "voice", None)

    def deliver(self, chat_id, user_id, text, speak=False):
        """Runs one message through the gateway and sends every reply back. Never raises."""
        try:
            self.working(chat_id)
            for reply in self.gateway.handle(self.name, chat_id, user_id, text):
                for part in chunks(reply.text):
                    self.send_text(chat_id, part)
                for kind, url in reply.media:
                    ext = url.rsplit(".", 1)[-1]
                    self.send_media(chat_id, kind, download(url), f"agentim.{ext}")
                if speak and self.voice and self.voice.enabled and not reply.media:
                    self.speak_reply(chat_id, reply.text)
        except Exception:
            log.exception("%s: failed to answer %s", self.name, chat_id)
            try:
                self.send_text(chat_id, "😵 Something went wrong on my side. Try again in a moment.")
            except Exception:
                pass

    def speak_reply(self, chat_id, text):
        from ..voice import speakable

        spoken = speakable(text)
        if not spoken:
            return
        try:
            self.send_voice(chat_id, self.voice.speak(spoken))
        except Exception:
            log.exception("%s: voice reply failed", self.name)

    def deliver_voice(self, chat_id, user_id, fetch_audio, mime="audio/ogg"):
        """A voice note: check the sender first, then transcribe locally and answer (out loud if enabled)."""
        try:
            if not self.gateway.allowed(self.name, user_id):
                return self.deliver(chat_id, user_id, "🎙️ (voice note)")
            if not (self.voice and self.voice.enabled):
                return self.send_text(chat_id, "🎙️ I can't listen yet. Pick a voice model in agentim's setup.")
            self.working(chat_id)
            ext = "ogg" if "ogg" in mime else mime.rsplit("/", 1)[-1]
            text = self.voice.transcribe(fetch_audio(), f"voice.{ext}", mime)
            if not text:
                return self.send_text(chat_id, "🎙️ I couldn't hear anything in that one.")
            self.send_text(chat_id, f"🎙️ “{text}”")
            self.deliver(chat_id, user_id, text, speak=self.gateway.config.voice_replies)
        except Exception:
            log.exception("%s: voice note failed", self.name)
            try:
                self.send_text(chat_id, "😵 I couldn't process that voice note.")
            except Exception:
                pass

    def deliver_async(self, chat_id, user_id, text):
        threading.Thread(target=self.deliver, args=(chat_id, user_id, text), daemon=True).start()

    def deliver_voice_async(self, chat_id, user_id, fetch_audio, mime="audio/ogg"):
        threading.Thread(target=self.deliver_voice, args=(chat_id, user_id, fetch_audio, mime), daemon=True).start()

    def start(self):
        threading.Thread(target=self.run, name=self.name, daemon=True).start()

    def run(self):
        raise NotImplementedError
