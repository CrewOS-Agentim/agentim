"""Telegram via the Bot API with long polling: no public URL needed."""

import json
import logging
import time
import urllib.error
import urllib.request
import uuid

from . import Channel

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


def multipart(fields, file_field, filename, data, content_type):
    boundary = uuid.uuid4().hex
    body = bytearray()
    for key, value in fields.items():
        body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n{value}\r\n".encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; filename=\"{filename}\"\r\n"
             f"Content-Type: {content_type}\r\n\r\n").encode()
    body += data + f"\r\n--{boundary}--\r\n".encode()
    return bytes(body), f"multipart/form-data; boundary={boundary}"


class Telegram(Channel):
    name = "telegram"

    def __init__(self, gateway, token, api="https://api.telegram.org"):
        super().__init__(gateway)
        self.base = f"{api}/bot{token}"

    def call(self, method, payload=None, timeout=40):
        req = urllib.request.Request(f"{self.base}/{method}", data=json.dumps(payload or {}).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())["result"]

    def send_text(self, chat_id, text):
        try:
            self.call("sendMessage", {"chat_id": chat_id, "text": text, "parse_mode": "Markdown"})
        except urllib.error.HTTPError:
            # Model output isn't always valid Telegram Markdown; resend as plain text.
            self.call("sendMessage", {"chat_id": chat_id, "text": text})

    def send_media(self, chat_id, kind, data, filename):
        method, field, mime = ("sendVideo", "video", "video/mp4") if kind == "video" else ("sendPhoto", "photo", "image/png")
        body, content_type = multipart({"chat_id": chat_id}, field, filename, data, mime)
        req = urllib.request.Request(f"{self.base}/{method}", data=body, headers={"Content-Type": content_type})
        urllib.request.urlopen(req, timeout=300).read()

    def working(self, chat_id):
        try:
            self.call("sendChatAction", {"chat_id": chat_id, "action": "typing"}, timeout=10)
        except Exception:
            pass

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
                    parsed = parse_update(update)
                    if parsed:
                        self.deliver_async(*parsed)
            except Exception as e:
                self.status = f"reconnecting: {e}"
                log.warning("telegram: %s", e)
                time.sleep(5)
