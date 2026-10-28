import json
import os
import re
import unittest
import urllib.request

import runner

GB = 1024 ** 3


class AssessTests(unittest.TestCase):
    def check(self, weights, available, ceiling=20 * GB, disk=100 * GB):
        return runner.assess(weights, total=24 * GB, available=available, ceiling=ceiling, free_disk=disk)

    def test_fits(self):
        self.assertEqual(self.check(4 * GB, 16 * GB)["verdict"], "fits")

    def test_tight(self):
        result = self.check(8 * GB, 6 * GB)
        self.assertEqual(result["verdict"], "tight")
        self.assertTrue(result["can_pull"])

    def test_too_large(self):
        result = self.check(40 * GB, 16 * GB)
        self.assertEqual(result["verdict"], "too_large")
        self.assertFalse(result["can_pull"])

    def test_not_enough_disk(self):
        self.assertEqual(self.check(4 * GB, 16 * GB, disk=2 * GB)["verdict"], "not_enough_disk")


class RefTests(unittest.TestCase):
    def test_library(self):
        self.assertEqual(runner.parse_ollama_ref("qwen3:0.6b"), ("registry.ollama.ai", "library/qwen3", "0.6b"))
        self.assertEqual(runner.parse_ollama_ref("llama3.2"), ("registry.ollama.ai", "library/llama3.2", "latest"))

    def test_user_namespace(self):
        self.assertEqual(runner.parse_ollama_ref("someone/model:7b"), ("registry.ollama.ai", "someone/model", "7b"))

    def test_hugging_face(self):
        self.assertEqual(runner.parse_ollama_ref("hf.co/bartowski/X-GGUF:Q8_0"), ("hf.co", "bartowski/X-GGUF", "Q8_0"))
        self.assertEqual(runner.parse_ollama_ref("hf.co/bartowski/X-GGUF")[2], "Q4_K_M")

    def test_gguf_size_sums_split_files(self):
        files = [
            {"path": "m-Q4_K_M-00001-of-00002.gguf", "size": 10},
            {"path": "m-Q4_K_M-00002-of-00002.gguf", "size": 5},
            {"path": "m-Q8_0.gguf", "size": 99},
            {"path": "README.md", "size": 1},
        ]
        self.assertEqual(runner.gguf_size(files, "Q4_K_M"), 15)
        with self.assertRaises(ValueError):
            runner.gguf_size(files, "Q2_K")


class MemoryTests(unittest.TestCase):
    def test_host_memory_is_sane(self):
        total, available, ceiling = runner.host_memory()
        self.assertGreater(total, 0)
        self.assertLessEqual(available, total)
        self.assertLessEqual(ceiling, total)


class ChatModelFilterTests(unittest.TestCase):
    def test_speech_and_embedding_models_are_not_chat(self):
        for model in ("faster-whisper-medium", "Systran/faster-whisper-small", "speaches-ai/Kokoro-82M-v1.0-ONNX",
                      "openai/tts-1", "nomic-embed-text", "bge-reranker-v2"):
            self.assertFalse(runner.is_chat_model(model), model)
        for model in ("hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M", "llama3.1:8b", "qwen2.5-coder:7b"):
            self.assertTrue(runner.is_chat_model(model), model)


class LTXChatTests(unittest.TestCase):
    """LTX through the chat API, with a fake LTX so nothing renders."""

    @classmethod
    def setUpClass(cls):
        import tempfile
        import threading
        from http.server import ThreadingHTTPServer

        cls.tmp = tempfile.mkdtemp()
        cls.video = os.path.join(cls.tmp, "clip.mp4")
        with open(cls.video, "wb") as f:
            f.write(b"0123456789")
        runner.FILES_DIR = os.path.join(cls.tmp, "files")
        runner.TOKEN = "t"
        runner.LTX.generate = lambda kind, prompt: cls.video
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), runner.Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def post(self, body):
        req = urllib.request.Request(f"{self.base}/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Authorization": "Bearer t", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.headers.get("Content-Type"), resp.read().decode()

    def test_non_streaming_returns_json_with_link(self):
        content_type, raw = self.post({"model": "ltx/video", "stream": False,
                                       "messages": [{"role": "user", "content": "a fox"}]})
        self.assertEqual(content_type, "application/json")
        text = json.loads(raw)["choices"][0]["message"]["content"]
        url = re.search(r"\[video\]\((http://[^)]+)\)", text).group(1)
        with urllib.request.urlopen(url, timeout=5) as resp:  # the file is served back
            self.assertEqual(resp.read(), b"0123456789")

    def test_streaming_returns_sse(self):
        content_type, raw = self.post({"model": "ltx/video", "stream": True,
                                       "messages": [{"role": "user", "content": "a fox"}]})
        self.assertEqual(content_type, "text/event-stream")
        self.assertIn("[video](", raw)
        self.assertTrue(raw.rstrip().endswith("data: [DONE]"))

    def test_range_requests_for_video_players(self):
        _, raw = self.post({"model": "ltx/video", "messages": [{"role": "user", "content": "x"}]})
        url = re.search(r"\((http://[^)]+)\)", raw).group(1)
        req = urllib.request.Request(url, headers={"Range": "bytes=2-4"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            self.assertEqual(resp.status, 206)
            self.assertEqual(resp.read(), b"234")


class LTXLaunchTests(unittest.TestCase):
    """LTX Desktop is opened on demand when it's installed but closed."""

    def bridge(self, installed=True, starts_after=2):
        bridge = runner.LTXBridge()
        checks = {"n": 0}
        opened = []

        def available():
            checks["n"] += 1
            return bool(opened) and checks["n"] > starts_after

        bridge.available = available
        bridge.installed = lambda: installed
        bridge.endpoint = lambda: ("http://127.0.0.1:1", "t")
        bridge.APP_PATHS = [os.path.dirname(os.path.abspath(__file__))]  # any existing directory
        return bridge, opened

    def test_opens_ltx_and_waits(self):
        bridge, opened = self.bridge()
        original = runner.subprocess.run
        runner.subprocess.run = lambda cmd, check=False: opened.append(cmd)
        try:
            self.assertEqual(bridge.ensure_running(wait=5, sleep=lambda s: None), ("http://127.0.0.1:1", "t"))
        finally:
            runner.subprocess.run = original
        self.assertEqual(opened[0][:2], ["open", "-g"])

    def test_not_installed(self):
        bridge, _ = self.bridge(installed=False)
        with self.assertRaisesRegex(RuntimeError, "isn't installed"):
            bridge.ensure_running(wait=1, sleep=lambda s: None)

    def test_timeout(self):
        bridge, _ = self.bridge(starts_after=10**9)
        original = runner.subprocess.run
        runner.subprocess.run = lambda cmd, check=False: None  # opening does nothing
        try:
            with self.assertRaisesRegex(RuntimeError, "didn't start"):
                bridge.ensure_running(wait=0, sleep=lambda s: None)
        finally:
            runner.subprocess.run = original


if __name__ == "__main__":
    unittest.main()
