import json
import os
import re
import tempfile
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


class LocalAgentsTests(unittest.TestCase):
    def agents(self, **env):
        calls = []

        class Done:
            returncode, stdout, stderr = 0, "All tests pass. 3 files reviewed.", ""

        def run(cmd, **kwargs):
            calls.append((cmd, kwargs))
            return Done()

        which = lambda name, path=None: f"/fake/bin/{name}" if name in ("claude", "codex") else None  # noqa: E731
        return runner.LocalAgents(env=env, which=which, run=run), calls

    def test_off_by_default(self):
        agents, _ = self.agents()
        self.assertEqual(agents.available(), [])
        with self.assertRaisesRegex(RuntimeError, "isn't enabled"):
            agents.run_task("claude-code", "review the repo")

    def test_only_installed_and_allowed(self):
        agents, _ = self.agents(AGENTIM_LOCAL_AGENTS="on")
        self.assertEqual(agents.available(), ["claude-code", "codex"], "gemini isn't installed")
        agents, _ = self.agents(AGENTIM_LOCAL_AGENTS="codex")
        self.assertEqual(agents.available(), ["codex"])

    def test_read_only_by_default_in_the_workspace(self):
        with tempfile.TemporaryDirectory() as ws:
            agents, calls = self.agents(AGENTIM_LOCAL_AGENTS="claude-code,codex", AGENTIM_WORKSPACES=ws)
            output, cwd = agents.run_task("claude-code", "review the auth module")
            self.assertEqual(output, "All tests pass. 3 files reviewed.")
            cmd, kwargs = calls[-1]
            self.assertEqual(cmd[:3], ["/fake/bin/claude", "-p", "review the auth module"])
            self.assertIn("plan", cmd, "Claude Code plans, doesn't edit")
            self.assertNotIn("bypassPermissions", cmd)
            self.assertEqual(kwargs["cwd"], os.path.realpath(ws))
            agents.run_task("codex", "explain the build")
            self.assertEqual(calls[-1][0][:4], ["/fake/bin/codex", "exec", "--sandbox", "read-only"])

    def test_edit_mode_is_opt_in(self):
        with tempfile.TemporaryDirectory() as ws:
            agents, calls = self.agents(AGENTIM_LOCAL_AGENTS="on", AGENTIM_WORKSPACES=ws, AGENTIM_LOCAL_AGENTS_MODE="edit")
            agents.run_task("codex", "fix the failing test")
            self.assertIn("workspace-write", calls[-1][0])
            agents.run_task("claude-code", "fix the failing test")
            self.assertIn("acceptEdits", calls[-1][0])

    def test_needs_a_workspace_and_picks_the_named_one(self):
        agents, _ = self.agents(AGENTIM_LOCAL_AGENTS="on")
        with self.assertRaisesRegex(RuntimeError, "AGENTIM_WORKSPACES"):
            agents.run_task("claude-code", "hi")
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            agents, calls = self.agents(AGENTIM_LOCAL_AGENTS="on", AGENTIM_WORKSPACES=f"{a}:{b}")
            agents.run_task("claude-code", f"look at {os.path.basename(b)} please")
            self.assertEqual(calls[-1][1]["cwd"], os.path.realpath(b))

    def test_failures_are_reported(self):
        class Failed:
            returncode, stdout, stderr = 1, "", "not logged in"

        with tempfile.TemporaryDirectory() as ws:
            agents = runner.LocalAgents(env={"AGENTIM_LOCAL_AGENTS": "on", "AGENTIM_WORKSPACES": ws},
                                        which=lambda n, path=None: f"/fake/{n}", run=lambda *a, **k: Failed())
            with self.assertRaisesRegex(RuntimeError, "not logged in"):
                agents.run_task("claude-code", "hi")


class MemoryControlTests(unittest.TestCase):
    """Free memory: list what Ollama has loaded, unload it, quit LTX Desktop."""

    def setUp(self):
        self.calls = []
        self.originals = (runner.http_json, runner.urllib.request.urlopen, dict(runner.BACKENDS))
        runner.BACKENDS["ollama"] = "http://ollama:11434"
        runner.http_json = lambda url, **kw: {"models": [
            {"name": "qwen3:4b", "size": 3_000_000_000, "size_vram": 0, "expires_at": "soon"},
            {"name": "coder:7b", "size": 5_000_000_000, "size_vram": 0, "expires_at": "soon"}]}

        class Done:
            def read(self):
                return b"{}"

        def urlopen(req, timeout=0):
            self.calls.append((req.full_url, json.loads(req.data)))
            return Done()

        runner.urllib.request.urlopen = urlopen

    def tearDown(self):
        runner.http_json, runner.urllib.request.urlopen, backends = self.originals
        runner.BACKENDS.clear()
        runner.BACKENDS.update(backends)

    def test_lists_loaded_models(self):
        models = runner.loaded_models()
        self.assertEqual([m["id"] for m in models], ["ollama/qwen3:4b", "ollama/coder:7b"])
        self.assertEqual(models[1]["size_bytes"], 5_000_000_000)

    def test_unload_all_or_one(self):
        self.assertEqual(runner.unload_models(), ["ollama/qwen3:4b", "ollama/coder:7b"])
        self.assertEqual(self.calls[0], ("http://ollama:11434/api/generate", {"model": "qwen3:4b", "keep_alive": 0}))
        self.calls.clear()
        self.assertEqual(runner.unload_models("coder:7b"), ["ollama/coder:7b"])
        self.assertEqual(len(self.calls), 1)

    def test_no_ollama_nothing_loaded(self):
        runner.BACKENDS.pop("ollama", None)
        self.assertEqual(runner.loaded_models(), [])

    def test_stop_ltx_quits_the_app(self):
        ran = []
        original = runner.IN_CONTAINER
        runner.IN_CONTAINER = False
        try:
            runner.stop_ltx(run=lambda cmd, **kw: ran.append(cmd))
        finally:
            runner.IN_CONTAINER = original
        if runner.platform.system() == "Darwin":
            self.assertEqual(ran[0][:2], ["osascript", "-e"])
            self.assertIn('"LTX Desktop" to quit', ran[0][2])


class ClaudeSessionsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = os.path.join(self.tmp.name, "projects")
        self.ws = os.path.realpath(os.path.join(self.tmp.name, "my-app"))
        self.other = os.path.realpath(os.path.join(self.tmp.name, "secret"))
        os.makedirs(self.ws)

        def session(name, cwd, records):
            # Claude Code keeps each project's sessions in a folder named after the path.
            folder = os.path.join(root, runner.ClaudeSessions.encoded(cwd))
            os.makedirs(folder, exist_ok=True)
            with open(os.path.join(folder, f"{name}.jsonl"), "w") as f:
                for r in records:
                    f.write(json.dumps({**r, "cwd": cwd}) + "\n")

        session("aaaaaaaa-1111", self.ws, [
            {"type": "ai-title", "aiTitle": "Fix login bug"},
            {"type": "user", "message": {"role": "user", "content": "Why does login fail?"}, "timestamp": "t1"},
            {"type": "assistant", "message": {"content": [{"type": "thinking", "thinking": "hidden"},
                                                          {"type": "text", "text": "The token expires early."},
                                                          {"type": "tool_use", "name": "Read"}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "file contents"}]}},
            {"type": "user", "message": {"content": "<system-reminder>x</system-reminder>"}},
            {"type": "custom-title", "customTitle": "Login fix"},
        ])
        session("bbbbbbbb-2222", self.other, [
            {"type": "user", "message": {"content": "my private notes"}}])
        self.calls = []

        class Done:
            returncode, stdout, stderr = 0, "Plan: refresh the token on wake.", ""

        def run(cmd, **kwargs):
            self.calls.append((cmd, kwargs))
            return Done()

        self.agents = runner.LocalAgents(env={"AGENTIM_LOCAL_AGENTS": "claude-code", "AGENTIM_WORKSPACES": self.ws},
                                         which=lambda n, path=None: f"/fake/{n}", run=run)
        self.sessions = runner.ClaudeSessions(agents=self.agents, root=root)

    def tearDown(self):
        self.tmp.cleanup()

    def test_lists_only_workspace_sessions_with_titles(self):
        listed = self.sessions.list()
        self.assertEqual([s["id"] for s in listed], ["aaaaaaaa-1111"], "sessions outside the workspaces stay hidden")
        self.assertEqual(listed[0]["title"], "Login fix", "a custom title wins")
        self.assertEqual(listed[0]["messages"], 2, "tool results and reminders aren't messages")
        self.assertEqual(listed[0]["first_prompt"], "Why does login fail?")

    def test_reads_text_only(self):
        session = self.sessions.read("aaaaaaaa-1111")
        self.assertEqual([m["text"] for m in session["messages_shown"]], ["Why does login fail?", "The token expires early."])
        with self.assertRaisesRegex(RuntimeError, "outside AGENTIM_WORKSPACES"):
            self.sessions.read("bbbbbbbb-2222")
        with self.assertRaisesRegex(RuntimeError, "isn't a session id"):
            self.sessions.read("../../etc/passwd")

    def test_continue_resumes_in_plan_mode_in_its_folder(self):
        result = self.sessions.continue_session("aaaaaaaa-1111", "Now write the fix")
        self.assertEqual(result["reply"], "Plan: refresh the token on wake.")
        cmd, kwargs = self.calls[-1]
        self.assertEqual(cmd[:5], ["/fake/claude", "-p", "Now write the fix", "--resume", "aaaaaaaa-1111"])
        self.assertIn("plan", cmd)
        self.assertEqual(kwargs["cwd"], self.ws)

    def test_session_that_started_elsewhere_belongs_to_its_project(self):
        folder = os.path.join(self.sessions.root, runner.ClaudeSessions.encoded(self.ws))
        with open(os.path.join(folder, "cccccccc-3333.jsonl"), "w") as f:
            f.write(json.dumps({"type": "mode", "cwd": os.path.expanduser("~")}) + "\n")  # started in ~
            for _ in range(2):
                f.write(json.dumps({"type": "user", "cwd": self.ws, "message": {"content": "Ship it"}}) + "\n")
        listed = {s["id"]: s for s in self.sessions.list()}
        self.assertEqual(listed["cccccccc-3333"]["cwd"], self.ws)

    def test_folder_names_match_claude_code(self):
        self.assertEqual(runner.ClaudeSessions.encoded("/Users/me/github/AgentHub"), "-Users-me-github-AgentHub")
        self.assertEqual(runner.ClaudeSessions.encoded("/Users/me/code/my.app"), "-Users-me-code-my-app")

    def test_off_unless_claude_code_is_enabled(self):
        off = runner.ClaudeSessions(agents=runner.LocalAgents(env={}), root=self.sessions.root)
        with self.assertRaisesRegex(RuntimeError, "Enable Claude Code"):
            off.list()


if __name__ == "__main__":
    unittest.main()
