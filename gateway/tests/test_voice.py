import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agentim import config as config_lib  # noqa: E402
from agentim.channels import Channel  # noqa: E402
from agentim.channels.telegram import parse_voice  # noqa: E402
from agentim.channels.whatsapp import WhatsApp, parse_voice_webhook, parse_webhook  # noqa: E402
from agentim.voice import Voice, VoiceError, speakable  # noqa: E402
from test_gateway import QWEN, FakeLLM, make_gateway  # noqa: E402


class FakeSpeaches(BaseHTTPRequestHandler):
    """Records requests; transcribes everything as 'hello tim' and speaks b'OGG'."""
    seen = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        FakeSpeaches.seen.append((self.path, self.headers["Content-Type"], body))
        if self.path == "/v1/audio/transcriptions":
            payload, content_type = json.dumps({"text": " hello tim "}).encode(), "application/json"
        elif self.path == "/v1/audio/speech":
            payload, content_type = b"OGG", "audio/ogg"
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


class VoiceClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeSpeaches)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.voice = Voice(f"http://127.0.0.1:{cls.server.server_port}", "Systran/faster-whisper-small",
                          "speaches-ai/Kokoro-82M-v1.0-ONNX")

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def test_transcribe_sends_multipart_with_model(self):
        self.assertEqual(self.voice.transcribe(b"AUDIO"), "hello tim")
        path, content_type, body = FakeSpeaches.seen[-1]
        self.assertEqual(path, "/v1/audio/transcriptions")
        self.assertTrue(content_type.startswith("multipart/form-data"))
        self.assertIn(b"Systran/faster-whisper-small", body)
        self.assertIn(b"AUDIO", body)

    def test_speak_asks_for_opus(self):
        self.assertEqual(self.voice.speak("hi"), b"OGG")
        path, _, body = FakeSpeaches.seen[-1]
        request = json.loads(body)
        self.assertEqual((path, request["response_format"], request["voice"]), ("/v1/audio/speech", "opus", "af_heart"))

    def test_unreachable_is_a_voice_error(self):
        with self.assertRaises(VoiceError):
            Voice("http://127.0.0.1:9", "m", "t").transcribe(b"x")

    def test_enabled(self):
        self.assertTrue(self.voice.enabled)
        self.assertFalse(Voice("", "m", "t").enabled)


class SpeakableTests(unittest.TestCase):
    def test_strips_footer_markdown_links_and_code(self):
        text = "**Great idea!** See [the docs](http://x.y).\n```swift\nlet a = 1\n```\n_— 🐙 Agent Tim via @qwen3_"
        spoken = speakable(text)
        self.assertNotIn("**", spoken)
        self.assertNotIn("http", spoken)
        self.assertNotIn("let a", spoken)
        self.assertNotIn("Agent Tim via", spoken)
        self.assertIn("the docs", spoken)
        self.assertIn("code in the chat", spoken)

    def test_long_replies_end_on_a_sentence(self):
        spoken = speakable("This is a sentence. " * 60, limit=100)
        self.assertLessEqual(len(spoken), 100)
        self.assertTrue(spoken.endswith("."))


class ParseTests(unittest.TestCase):
    def test_telegram_voice(self):
        update = {"update_id": 1, "message": {"chat": {"id": 5}, "from": {"id": 7},
                                              "voice": {"file_id": "F1", "mime_type": "audio/ogg"}}}
        self.assertEqual(parse_voice(update), ("5", "7", "F1", "audio/ogg"))
        self.assertIsNone(parse_voice({"update_id": 2, "message": {"chat": {"id": 5}, "text": "hi"}}))

    def test_whatsapp_voice(self):
        payload = {"event": "message", "session": "default", "payload": {
            "from": "1555@c.us", "fromMe": False, "hasMedia": True, "body": "",
            "media": {"url": "http://localhost:3000/api/files/default/a.oga", "mimetype": "audio/ogg; codecs=opus"}}}
        self.assertEqual(parse_voice_webhook(payload), ("1555@c.us", "http://localhost:3000/api/files/default/a.oga", "audio/ogg"))
        self.assertIsNone(parse_webhook(payload))  # not treated as a text message
        image = json.loads(json.dumps(payload))
        image["payload"]["media"]["mimetype"] = "image/jpeg"
        self.assertIsNone(parse_voice_webhook(image))

    def test_waha_media_url_uses_our_address(self):
        whatsapp = WhatsApp(make_gateway(), "http://whatsapp:3000")
        self.assertEqual(whatsapp.media_url("http://localhost:3000/api/files/default/a.oga?x=1"),
                         "http://whatsapp:3000/api/files/default/a.oga?x=1")


class FakeVoice:
    enabled = True

    def __init__(self, heard="what's the plan today"):
        self.heard = heard
        self.spoken = []

    def transcribe(self, audio, filename="voice.ogg", mime="audio/ogg"):
        return self.heard

    def speak(self, text):
        self.spoken.append(text)
        return b"OGG"


class Recorder(Channel):
    name = "telegram"

    def __init__(self, gateway):
        super().__init__(gateway)
        self.texts, self.voices = [], []

    def send_text(self, chat_id, text):
        self.texts.append(text)

    def send_voice(self, chat_id, data):
        self.voices.append(data)


class VoiceFlowTests(unittest.TestCase):
    def gateway(self, voice):
        gateway = make_gateway(models=(QWEN,), llm=FakeLLM({QWEN.id: "Ship the onboarding first."}))
        gateway.voice = voice
        return gateway

    def test_voice_note_is_transcribed_answered_and_spoken(self):
        voice = FakeVoice()
        channel = Recorder(self.gateway(voice))
        channel.deliver_voice("c", "1", lambda: b"AUDIO")
        self.assertEqual(channel.texts[0], "🎙️ “what's the plan today”")
        self.assertIn("Ship the onboarding first.", channel.texts[1])
        self.assertEqual(channel.voices, [b"OGG"])
        self.assertEqual(voice.spoken, ["Ship the onboarding first."])  # footer not read aloud

    def test_strangers_are_not_transcribed(self):
        voice = FakeVoice()
        channel = Recorder(self.gateway(voice))
        channel.deliver_voice("c", "999", lambda: self.fail("audio fetched for a stranger"))
        self.assertIn("doesn't know you", channel.texts[0])
        self.assertEqual(voice.spoken, [])

    def test_voice_not_set_up(self):
        channel = Recorder(self.gateway(None))
        channel.deliver_voice("c", "1", lambda: b"AUDIO")
        self.assertIn("can't listen yet", channel.texts[0])

    def test_silence(self):
        channel = Recorder(self.gateway(FakeVoice(heard="")))
        channel.deliver_voice("c", "1", lambda: b"AUDIO")
        self.assertIn("couldn't hear", channel.texts[0])

    def test_text_messages_are_not_spoken(self):
        voice = FakeVoice()
        channel = Recorder(self.gateway(voice))
        channel.deliver("c", "1", "hello")
        self.assertEqual(channel.voices, [])

    def test_config(self):
        config = config_lib.from_env({"VOICE_URL": "http://voice:8000/", "AGENTIM_STT_MODEL": "Systran/faster-whisper-base",
                                      "AGENTIM_VOICE_REPLIES": "false", "AGENTIM_DATA_DIR": "/tmp"})
        self.assertEqual((config.voice_url, config.stt_model, config.voice_replies),
                         ("http://voice:8000", "Systran/faster-whisper-base", False))


if __name__ == "__main__":
    unittest.main()
