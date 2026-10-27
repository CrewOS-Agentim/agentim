"""Voice notes in and out, through the local Speaches container (Whisper + Kokoro)."""

import json
import re
import urllib.error
import urllib.request

from .multipart import multipart

MAX_SPOKEN = 600


class VoiceError(Exception):
    pass


class Voice:
    def __init__(self, url, stt_model, tts_model, tts_voice="af_heart"):
        self.url = (url or "").rstrip("/")
        self.stt_model, self.tts_model, self.tts_voice = stt_model, tts_model, tts_voice

    @property
    def enabled(self):
        return bool(self.url and self.stt_model)

    def _post(self, path, data, content_type, timeout=300):
        req = urllib.request.Request(f"{self.url}{path}", data=data, method="POST", headers={"Content-Type": content_type})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as e:
            raise VoiceError(f"HTTP {e.code}: {e.read()[:200]!r}") from e
        except (urllib.error.URLError, TimeoutError) as e:
            raise VoiceError(str(e)) from e

    def transcribe(self, audio, filename="voice.ogg", mime="audio/ogg"):
        body, content_type = multipart({"model": self.stt_model, "response_format": "json"}, "file", filename, audio, mime)
        return json.loads(self._post("/v1/audio/transcriptions", body, content_type)).get("text", "").strip()

    def speak(self, text):
        """Returns an OGG/Opus voice note (what Telegram and WhatsApp play as a voice bubble)."""
        body = json.dumps({"model": self.tts_model, "voice": self.tts_voice, "input": text,
                           "response_format": "opus"}).encode()
        return self._post("/v1/audio/speech", body, "application/json")


def speakable(text, limit=MAX_SPOKEN):
    """Turns a chat reply into something pleasant to hear: no route footer, code, links or markdown."""
    text = "\n".join(line for line in text.splitlines() if not line.strip().startswith("_—"))
    text = re.sub(r"```.*?```", " I've put the code in the chat. ", text, flags=re.S)
    text = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[*_`#>|]+", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) <= limit:
        return text
    cut = max(text.rfind(". ", 0, limit), text.rfind("! ", 0, limit), text.rfind("? ", 0, limit))
    return text[: cut + 1 if cut > limit // 2 else limit].strip()
