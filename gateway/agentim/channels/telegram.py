"""Telegram via the Bot API with long polling: no public URL needed."""

import json
import logging
import time
import urllib.error
import urllib.request

from ..multipart import multipart
from . import Channel, download

log = logging.getLogger("agentim.telegram")


def parse_update(update):
    """Returns (chat_id, user_id, text) for a text message, else None."""
    message = update.get("message") or update.get("edited_message")
    if not message:
        return None
    text = message.get("text") or message.get("caption")
    if not text:
        return None
    return str(message["chat"]["id"]), str(message.get("from", {}).get("id", "")), text


def parse_voice(update):
    """Returns (chat_id, user_id, file_id, mime) for a voice note or audio file, else None."""
    message = update.get("message") or {}
    audio = message.get("voice") or message.get("audio")
    if not audio or not audio.get("file_id"):
        return None
    return (str(message["chat"]["id"]), str(message.get("from", {}).get("id", "")), audio["file_id"],
            audio.get("mime_type", "audio/ogg"))


class Telegram(Channel):
    name = "telegram"

    def __init__(self, gateway, token, api="https://api.telegram.org"):
        super().__init__(gateway)
        self.api, self.token = api, token
        self.base = f"{api}/bot{token}"

    def call(self, method, payload=None, timeout=40):
        req = urllib.request.Request(f"{self.base}/{method}", data=json.dumps(payload or {}).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())["result"]

    def upload(self, method, chat_id, field, filename, data, mime):
        body, content_type = multipart({"chat_id": chat_id}, field, filename, data, mime)
        req = urllib.request.Request(f"{self.base}/{method}", data=body, headers={"Content-Type": content_type})
        urllib.request.urlopen(req, timeout=300).read()

    def send_text(self, chat_id, text):
        try:
            self.call("sendMessage", {"chat_id": chat_id, "text": text, "parse_mode": "Markdown"})
        except urllib.error.HTTPError:
            # Model output isn't always valid Telegram Markdown; resend as plain text.
            self.call("sendMessage", {"chat_id": chat_id, "text": text})

    def send_media(self, chat_id, kind, data, filename):
        if kind == "video":
            self.upload("sendVideo", chat_id, "video", filename, data, "video/mp4")
        else:
            self.upload("sendPhoto", chat_id, "photo", filename, data, "image/png")

    def send_voice(self, chat_id, data):
        self.upload("sendVoice", chat_id, "voice", "agentim.ogg", data, "audio/ogg")

    def working(self, chat_id):
        try:
            self.call("sendChatAction", {"chat_id": chat_id, "action": "typing"}, timeout=10)
        except Exception:
            pass

    def fetch_file(self, file_id):
        path = self.call("getFile", {"file_id": file_id})["file_path"]
        return download(f"{self.api}/file/bot{self.token}/{path}")

    def run(self):
        offset = 0
        try:
            me = self.call("getMe")
            log.info("telegram: connected as @%s", me.get("username"))
            self.status = f"connected as @{me.get('username')}"
        except Exception as e:
            self.status = f"error: {e}"
            log.error("telegram: bad token? %s", e)
        while True:
            try:
                updates = self.call("getUpdates", {"offset": offset, "timeout": 30}, timeout=40)
                self.status = self.status if self.status.startswith("connected") else "connected"
                for update in updates:
                    offset = update["update_id"] + 1
                    if parsed := parse_update(update):
                        self.deliver_async(*parsed)
                    elif voice := parse_voice(update):
                        chat_id, user_id, file_id, mime = voice
                        self.deliver_voice_async(chat_id, user_id, lambda f=file_id: self.fetch_file(f), mime)
            except Exception as e:
                self.status = f"reconnecting: {e}"
                log.warning("telegram: %s", e)
                time.sleep(5)
