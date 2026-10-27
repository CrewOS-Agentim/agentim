"""WhatsApp through WAHA (WhatsApp HTTP API), a self-hosted Docker container.

WAHA logs in with a QR code like WhatsApp Web and posts incoming messages to our
webhook. It isn't the official WhatsApp Business API; use a number you're
comfortable linking.
"""

import base64
import json
import logging
import urllib.parse
import urllib.request

from . import Channel

log = logging.getLogger("agentim.whatsapp")


def parse_webhook(payload, session="default"):
    """Returns (chat_id, user_id, text) for an incoming text message, else None."""
    if payload.get("event") not in ("message", "message.any") or payload.get("session", session) != session:
        return None
    message = payload.get("payload") or {}
    if message.get("fromMe") or not message.get("body"):
        return None
    chat = message.get("from", "")
    if chat.endswith("@g.us") or chat == "status@broadcast":
        return None  # private chats only
    return chat, chat, message["body"]


def parse_voice_webhook(payload, session="default"):
    """Returns (chat_id, media_url, mime) for an incoming voice note / audio, else None."""
    if payload.get("event") not in ("message", "message.any") or payload.get("session", session) != session:
        return None
    message = payload.get("payload") or {}
    media = message.get("media") or {}
    mime = media.get("mimetype") or ""
    chat = message.get("from", "")
    if message.get("fromMe") or not message.get("hasMedia") or not mime.startswith("audio") or not media.get("url"):
        return None
    if chat.endswith("@g.us") or chat == "status@broadcast":
        return None
    return chat, media["url"], mime.split(";")[0]


class WhatsApp(Channel):
    name = "whatsapp"

    def __init__(self, gateway, url, api_key="", session="default"):
        super().__init__(gateway)
        self.url, self.api_key, self.session = url, api_key, session

    def call(self, path, body, timeout=60):
        req = urllib.request.Request(f"{self.url}{path}", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json", "X-Api-Key": self.api_key})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None

    def send_text(self, chat_id, text):
        self.call("/api/sendText", {"session": self.session, "chatId": chat_id, "text": text})

    def send_media(self, chat_id, kind, data, filename):
        mime = "video/mp4" if kind == "video" else "image/png"
        path = "/api/sendVideo" if kind == "video" else "/api/sendImage"
        self.call(path, {"session": self.session, "chatId": chat_id,
                         "file": {"mimetype": mime, "filename": filename, "data": base64.b64encode(data).decode()}},
                  timeout=300)

    def working(self, chat_id):
        try:
            self.call("/api/startTyping", {"session": self.session, "chatId": chat_id}, timeout=10)
        except Exception:
            pass

    def run(self):
        """Starts the WAHA session; messages then arrive on the gateway's webhook."""
        try:
            self.call("/api/sessions/start", {"name": self.session})
        except Exception as e:
            # Already started, or WAHA still booting: it keeps its own session state.
            log.info("whatsapp: session start: %s", e)
        self.status = f"waiting for messages; scan the QR at {self.url}/dashboard if not linked"
        log.info("whatsapp: %s", self.status)

    def send_voice(self, chat_id, data):
        self.call("/api/sendVoice", {"session": self.session, "chatId": chat_id, "file": {
            "mimetype": "audio/ogg; codecs=opus", "filename": "agentim.ogg", "data": base64.b64encode(data).decode()}},
            timeout=120)

    def media_url(self, url):
        """WAHA reports media on its own hostname (e.g. localhost:3000); keep the path, use our address."""
        parts = urllib.parse.urlsplit(url)
        return f"{self.url}{parts.path}" + (f"?{parts.query}" if parts.query else "")

    def fetch_media(self, url):
        req = urllib.request.Request(self.media_url(url), headers={"X-Api-Key": self.api_key})
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read()

    def on_webhook(self, payload):
        parsed = parse_webhook(payload, self.session)
        if parsed:
            self.deliver_async(*parsed)
            return True
        voice = parse_voice_webhook(payload, self.session)
        if voice:
            chat, url, mime = voice
            self.deliver_voice_async(chat, chat, lambda u=url: self.fetch_media(u), mime)
            return True
        return False
