import json
import os
import sys
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agentim import config as config_lib, skills as skill_lib  # noqa: E402
from agentim.channels import Channel, chunks  # noqa: E402
from agentim.channels.slack import parse_event  # noqa: E402
from agentim.channels.telegram import multipart, parse_update  # noqa: E402
from agentim.channels.whatsapp import parse_webhook  # noqa: E402
from agentim.core import Gateway, Reply, split_media  # noqa: E402
from agentim.llm import LLMError, strip_thinking  # noqa: E402
from agentim.models import Catalog, ensure_defaults  # noqa: E402
from agentim.router import Model, NoModel, Router, billions, classify, extract_override, model_from_runner  # noqa: E402
from agentim.server import make_handler  # noqa: E402
from agentim.store import Store  # noqa: E402

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILLS = skill_lib.load_dir(os.path.join(HERE, "skills"))

QWEN = model_from_runner({"id": "ollama/hf.co/unsloth/Qwen3-4B-Instruct-2507-GGUF:Q4_K_M"}, "http://runner:8765")
LLAMA = model_from_runner({"id": "ollama/llama3.1:8b", "parameter_size": "8.0B"}, "http://runner:8765")
LTX_VIDEO = model_from_runner({"id": "ltx/video", "kind": "video"}, "http://mac:8766")
SONNET = Model("anthropic/claude-sonnet-5-5", "sonnet", "anthropic", "claude-sonnet-5-5",
               {"coding", "reasoning", "creative", "longContext", "general"}, 200_000, 3, 4, False)


def make_config(**overrides):
    env = {"AGENTIM_ALLOWED_USERS": "telegram:1,api:*,whatsapp:*", "AGENTIM_DATA_DIR": "/tmp",
           "AGENTIM_API_TOKEN": "tok", "AGENTIM_WEBHOOK_SECRET": "hook"}
    env.update(overrides)
    return config_lib.from_env(env)


class FakeLLM:
    def __init__(self, replies=None, fail=()):
        self.calls = []
        self.replies = replies or {}
        self.fail = set(fail)

    def complete(self, model, system, messages):
        self.calls.append((model.id, system, messages))
        if model.id in self.fail:
            raise LLMError("boom")
        return self.replies.get(model.id, f"answer from {model.alias}")


def make_gateway(models=(QWEN, LLAMA), llm=None, **config):
    return Gateway(make_config(**config), Store(":memory:"), llm or FakeLLM(), lambda: list(models), SKILLS)


class ConfigTests(unittest.TestCase):
    def test_allowed_users(self):
        self.assertEqual(config_lib.parse_allowed("telegram:1, telegram:2,slack:U9,bad"),
                         {"telegram": {"1", "2"}, "slack": {"U9"}})

    def test_defaults_are_local_hugging_face(self):
        config = make_config()
        self.assertTrue(all(m.startswith("hf.co/") for m in config.default_models))
        self.assertEqual(config.agents[0].name, "Agent Tim")

    def test_default_models_can_be_disabled(self):
        self.assertEqual(make_config(AGENTIM_DEFAULT_MODELS="").default_models, [])


class RouterTests(unittest.TestCase):
    def test_classify(self):
        self.assertEqual(classify("make a video of a cat").primary, "video")
        self.assertEqual(classify("draw a dragon").primary, "image")
        self.assertEqual(classify("fix this python bug").primary, "coding")
        self.assertEqual(classify("hi!").primary, "fast")
        self.assertTrue(classify("my password is hunter2").sensitive)

    def test_override(self):
        self.assertEqual(extract_override("@sonnet hi there"), ("sonnet", "hi there"))
        self.assertEqual(extract_override("mail bob@example.com"), (None, "mail bob@example.com"))

    def test_billions(self):
        self.assertEqual(billions("8.0B"), 8)
        self.assertAlmostEqual(billions("751.63M"), 0.75163)
        self.assertIsNone(billions("llama3.2"))

    def test_runner_model_heuristics(self):
        self.assertEqual(LLAMA.quality, 3)
        self.assertEqual(QWEN.alias, "qwen3-4b-instruct-2507")
        self.assertIn("fast", QWEN.caps)
        self.assertTrue(LTX_VIDEO.is_media)

    def test_local_preferred_by_default(self):
        decision = Router([QWEN, SONNET]).route("tell me something about octopuses please")
        self.assertTrue(decision.model.local)

    def test_hard_task_can_go_to_cloud_when_local_is_not_preferred(self):
        decision = Router([QWEN, SONNET], prefer_local=False).route("Analyze the trade-offs step by step")
        self.assertEqual(decision.model.id, SONNET.id)

    def test_sensitive_stays_local(self):
        decision = Router([QWEN, SONNET], prefer_local=False).route("analyze my bank account step by step")
        self.assertTrue(decision.model.local)

    def test_video_goes_to_ltx_and_text_never_does(self):
        router = Router([QWEN, LTX_VIDEO])
        self.assertEqual(router.route("make a video of a fox").model.id, LTX_VIDEO.id)
        self.assertEqual(router.route("hello").model.id, QWEN.id)

    def test_video_without_media_model_falls_back_to_text(self):
        self.assertEqual(Router([QWEN]).route("make a video of a fox").model.id, QWEN.id)

    def test_no_models(self):
        with self.assertRaises(NoModel):
            Router([]).route("hi")

    def test_unknown_alias(self):
        with self.assertRaises(NoModel):
            Router([QWEN]).route("@nope hi")


class SkillTests(unittest.TestCase):
    def test_builtin_skills_present(self):
        slugs = {s.slug for s in SKILLS}
        for expected in ("validate-your-startup", "youtube-channel-creator", "software-engineer",
                         "product-manager", "project-manager", "video-director"):
            self.assertIn(expected, slugs)
        self.assertTrue(all(s.instructions and s.summary and s.triggers for s in SKILLS))

    def test_parse(self):
        skill = skill_lib.parse("---\nname: Release Notes\ndescription: x\ntriggers: changelog, notes\n---\nBody")
        self.assertEqual((skill.slug, skill.triggers, skill.instructions), ("release-notes", ["changelog", "notes"], "Body"))
        self.assertIsNone(skill_lib.parse("no front matter"))

    def test_active_rules(self):
        startup = next(s for s in SKILLS if s.slug == "validate-your-startup")
        # Trigger words only for attached skills, slash commands for any.
        self.assertEqual(skill_lib.active([startup], set(), "my startup idea"), [])
        self.assertEqual(skill_lib.active([startup], {"validate-your-startup"}, "my startup idea"), [startup])
        self.assertEqual(skill_lib.active([startup], set(), "/validate-your-startup now"), [startup])

    def test_every_agent_skill_exists(self):
        slugs = {s.slug for s in SKILLS}
        for agent in make_config().agents:
            self.assertTrue(set(agent.skills) <= slugs, agent.name)


class StoreTests(unittest.TestCase):
    def test_history_order_limit_and_reset(self):
        store = Store(":memory:")
        for i in range(5):
            store.add("k", "user", f"m{i}")
        self.assertEqual([m["content"] for m in store.history("k", limit=3)], ["m2", "m3", "m4"])
        store.reset("k")
        self.assertEqual(store.history("k"), [])

    def test_settings(self):
        store = Store(":memory:")
        store.set_agent("k", "product-manager")
        store.set_pinned("k", "qwen")
        self.assertEqual((store.agent("k"), store.pinned("k")), ("product-manager", "qwen"))


class GatewayTests(unittest.TestCase):
    def test_token_authenticated_api_needs_no_allow_list_entry(self):
        gateway = make_gateway(AGENTIM_ALLOWED_USERS="telegram:1")
        self.assertIn("answer from", gateway.handle("api", "c", "api", "hi")[0].text)

    def test_strangers_get_their_id_only(self):
        llm = FakeLLM()
        replies = make_gateway(llm=llm).handle("telegram", "c", "999", "hello")
        self.assertIn("telegram:999", replies[0].text)
        self.assertEqual(llm.calls, [])

    def test_answer_records_history_and_route(self):
        gateway = make_gateway()
        reply = gateway.handle("telegram", "c", "1", "hi there")[0]
        self.assertIn("answer from", reply.text)
        self.assertIn("Agent Tim", reply.text)
        self.assertEqual(len(gateway.store.history("telegram:c")), 2)

    def test_skill_injected_into_system_prompt(self):
        llm = FakeLLM()
        reply = make_gateway(llm=llm).handle("telegram", "c", "1", "Please validate my startup idea: Uber for dogs")[0]
        self.assertIn("Skill: Validate Your Startup", llm.calls[0][1])
        self.assertIn("🪄Validate Your Startup", reply.text)

    def test_fallback_after_error(self):
        llm = FakeLLM(fail={QWEN.id})
        reply = make_gateway(llm=llm).handle("telegram", "c", "1", "hi")[0]
        self.assertIn("fallback", reply.text)
        self.assertEqual(len(llm.calls), 2)

    def test_all_models_fail(self):
        reply = make_gateway(llm=FakeLLM(fail={QWEN.id, LLAMA.id})).handle("telegram", "c", "1", "hi")[0]
        self.assertIn("tangled", reply.text)

    def test_commands(self):
        gateway = make_gateway()
        self.assertIn("/agents", gateway.handle("telegram", "c", "1", "/help")[0].text)
        self.assertIn("Product Manager", gateway.handle("telegram", "c", "1", "/agent product-manager")[0].text)
        self.assertEqual(gateway.agent_for("telegram:c").name, "Product Manager")
        self.assertIn("📌", gateway.handle("telegram", "c", "1", "/model @" + LLAMA.alias)[0].text)
        self.assertEqual(gateway.store.pinned("telegram:c"), LLAMA.alias)
        self.assertIn("automatic", gateway.handle("telegram", "c", "1", "/model auto")[0].text)
        self.assertIn("/validate-your-startup", gateway.handle("telegram", "c", "1", "/skills")[0].text)
        self.assertIn("@" + QWEN.alias, gateway.handle("telegram", "c", "1", "/models")[0].text)
        gateway.handle("telegram", "c", "1", "hello")
        gateway.handle("telegram", "c", "1", "/reset")
        self.assertEqual(gateway.store.history("telegram:c"), [])

    def test_pinned_model_is_used(self):
        llm = FakeLLM()
        gateway = make_gateway(llm=llm)
        gateway.handle("telegram", "c", "1", f"/model {LLAMA.alias}")
        gateway.handle("telegram", "c", "1", "hi")
        self.assertEqual(llm.calls[-1][0], LLAMA.id)

    def test_video_command_returns_media(self):
        llm = FakeLLM({LTX_VIDEO.id: "Rendering video… done.\n\n[video](http://mac:8766/files/abc.mp4)"})
        reply = make_gateway(models=(QWEN, LTX_VIDEO), llm=llm).handle("api", "c", "api", "/video a fox in snow")[0]
        self.assertEqual(reply.media, [("video", "http://mac:8766/files/abc.mp4")])
        self.assertEqual(llm.calls[0][0], LTX_VIDEO.id)
        self.assertIn("Make a video of a fox in snow", llm.calls[0][2][-1]["content"])

    def test_video_command_needs_a_prompt(self):
        self.assertIn("Tell me what to make", make_gateway().handle("api", "c", "api", "/video")[0].text)

    def test_no_models_yet(self):
        self.assertIn("still pulling", make_gateway(models=()).handle("api", "c", "api", "hello")[0].text)

    def test_split_media(self):
        self.assertEqual(split_media("ok [image](http://x/a.png) done"), ("ok  done", [("image", "http://x/a.png")]))


class ChannelTests(unittest.TestCase):
    def test_chunks(self):
        text = "\n\n".join(["x" * 2000] * 3)
        parts = chunks(text, size=3500)
        self.assertEqual(len(parts), 3)
        self.assertTrue(all(len(p) <= 3500 for p in parts))
        self.assertEqual(chunks("short"), ["short"])

    def test_telegram_parse(self):
        update = {"update_id": 5, "message": {"chat": {"id": 42}, "from": {"id": 7}, "text": "hi"}}
        self.assertEqual(parse_update(update), ("42", "7", "hi"))
        self.assertIsNone(parse_update({"update_id": 6, "message": {"chat": {"id": 1}, "sticker": {}}}))

    def test_telegram_multipart(self):
        body, content_type = multipart({"chat_id": "1"}, "video", "a.mp4", b"DATA", "video/mp4")
        self.assertIn(b'name="video"; filename="a.mp4"', body)
        self.assertIn(b"DATA", body)
        self.assertTrue(content_type.startswith("multipart/form-data; boundary="))

    def test_slack_parse(self):
        dm = {"type": "message", "channel_type": "im", "channel": "D1", "user": "U1", "text": "hi", "ts": "1.0"}
        self.assertEqual(parse_event(dm), ("D1|", "U1", "hi"))
        mention = {"type": "app_mention", "channel": "C1", "user": "U1", "text": "<@B0> plan it", "ts": "2.0"}
        self.assertEqual(parse_event(mention, "B0"), ("C1|2.0", "U1", "plan it"))
        self.assertIsNone(parse_event({**dm, "bot_id": "B0"}))
        self.assertIsNone(parse_event({**dm, "channel_type": "channel"}))

    def test_whatsapp_parse(self):
        payload = {"event": "message", "session": "default",
                   "payload": {"from": "15551234567@c.us", "fromMe": False, "body": "hello"}}
        self.assertEqual(parse_webhook(payload), ("15551234567@c.us", "15551234567@c.us", "hello"))
        self.assertIsNone(parse_webhook({**payload, "payload": {**payload["payload"], "fromMe": True}}))
        self.assertIsNone(parse_webhook({**payload, "payload": {**payload["payload"], "from": "123@g.us"}}))
        self.assertIsNone(parse_webhook({**payload, "event": "session.status"}))

    def test_deliver_sends_text_and_survives_errors(self):
        sent = []

        class Fake(Channel):
            name = "telegram"

            def send_text(self, chat_id, text):
                sent.append(text)

        Fake(make_gateway()).deliver("c", "1", "hello")
        self.assertIn("answer from", sent[0])

        class Broken:
            def handle(self, *args):
                raise RuntimeError("nope")

        sent.clear()
        Fake(Broken()).deliver("c", "1", "hello")
        self.assertIn("went wrong", sent[0])


class FakeRunnerAPI:
    def __init__(self, checks):
        self.checks = checks
        self.pulled = []
        self.url = "http://runner:8765"

    def models(self):
        return [{"id": "ollama/llama3.1:8b"}]

    def check(self, ref):
        return self.checks[ref]

    def pull(self, ref):
        self.pulled.append(ref)
        return {"status": "success"}


class ModelBootstrapTests(unittest.TestCase):
    def test_pulls_only_what_fits_and_is_missing(self):
        api = FakeRunnerAPI({"small": {"can_pull": True, "verdict": "fits", "weight_bytes": 1},
                             "huge": {"can_pull": False, "verdict": "too_large"}})
        results = ensure_defaults(api, ["small", "huge", "llama3.1:8b"], {"ollama/llama3.1:8b"})
        self.assertEqual(api.pulled, ["small"])
        self.assertEqual(results, {"small": "pulled", "huge": "skipped: too_large", "llama3.1:8b": "installed"})

    def test_catalog_adds_cloud_only_with_keys(self):
        config = make_config(RUNNER_URLS="http://runner:8765")
        catalog = Catalog(config, api_factory=lambda url, token: FakeRunnerAPI({}))
        self.assertEqual([m.id for m in catalog()], ["ollama/llama3.1:8b"])
        keyed = Catalog(make_config(ANTHROPIC_API_KEY="k"), api_factory=lambda url, token: FakeRunnerAPI({}))
        self.assertNotIn("anthropic/claude-sonnet-5-5", [m.id for m in keyed()], "Claude via tmux by default")
        api = Catalog(make_config(ANTHROPIC_API_KEY="k", AGENTIM_CLAUDE_VIA="api"), api_factory=lambda url, token: FakeRunnerAPI({}))
        self.assertIn("anthropic/claude-sonnet-5-5", [m.id for m in api()])

    def test_catalog_ignores_speech_models(self):
        class Mixed(FakeRunnerAPI):
            def models(self):
                return [{"id": "ollama/llama3.1:8b"}, {"id": "vllm/faster-whisper-medium"},
                        {"id": "vllm/whisper-large-v3-arabic-ct2-int8"}, {"id": "ltx/video", "kind": "video"}]

        catalog = Catalog(make_config(), api_factory=lambda url, token: Mixed({}))
        self.assertEqual(sorted(m.id for m in catalog()), ["ltx/video", "ollama/llama3.1:8b"])

    def test_strip_thinking(self):
        self.assertEqual(strip_thinking("<think>hmm\nlong</think>\nHello"), "Hello")

    def test_streamed_reply_to_non_streaming_request_is_a_clean_error(self):
        from http.server import BaseHTTPRequestHandler

        from agentim.llm import LLM

        class Streams(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                body = b'data: {"choices": []}\n\ndata: [DONE]\n\n'
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Streams)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            model = model_from_runner({"id": "ollama/x:1b"}, f"http://127.0.0.1:{server.server_port}")
            with self.assertRaises(LLMError):
                LLM(make_config()).complete(model, "", [{"role": "user", "content": "hi"}])
        finally:
            server.shutdown()


class ServerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gateway = make_gateway()
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(cls.gateway, {}, lambda: [QWEN]))
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def request(self, path, body=None, token="tok"):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None,
                                     headers=headers, method="POST" if body is not None else "GET")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_health_is_public(self):
        self.assertEqual(self.request("/health", token=None)[0], 200)

    def test_status_requires_token(self):
        self.assertEqual(self.request("/v1/status", token="wrong")[0], 401)
        status, body = self.request("/v1/status")
        self.assertEqual(status, 200)
        self.assertEqual(body["models"][0]["id"], QWEN.id)
        self.assertEqual(len(body["skills"]), len(SKILLS))

    def test_messages(self):
        status, body = self.request("/v1/messages", {"text": "hi"})
        self.assertEqual(status, 200)
        self.assertIn("answer from", body["replies"][0]["text"])

    def test_webhook_needs_secret(self):
        self.assertEqual(self.request("/webhooks/whatsapp?secret=nope", {"event": "message"}, token=None)[0], 401)
        self.assertEqual(self.request("/webhooks/whatsapp?secret=hook", {"event": "message"}, token=None)[0], 200)

    def test_unknown_paths(self):
        self.assertEqual(self.request("/nope")[0], 404)
        self.assertEqual(self.request("/nope", {})[0], 404)


if __name__ == "__main__":
    unittest.main()
