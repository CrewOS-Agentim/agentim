import io
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(HERE)), "deploy", "mcp"))

import agentim_mcp  # noqa: E402
from agentim.core import Reply  # noqa: E402
from agentim.mcp import TOOLS, MCPServer  # noqa: E402
from agentim.server import make_handler  # noqa: E402
from test_gateway import QWEN  # noqa: E402
from test_startup import PITCH, make_startup_mode  # noqa: E402


def rpc(method, params=None, msg_id=1):
    message = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if msg_id is not None:
        message["id"] = msg_id
    return message


class FakeGateway:
    """Records what the MCP tools send to the gateway."""

    def __init__(self, real):
        self.real, self.sent = real, []

    def __getattr__(self, name):
        return getattr(self.real, name)

    def handle(self, channel, chat_id, user_id, text):
        self.sent.append((channel, chat_id, text))
        if text.startswith("/image"):
            return [Reply("Here you go.", [("image", "http://localhost:8766/files/x.png")])]
        return [Reply(f"echo: {text}")]


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        gateway, _ = make_startup_mode()
        self.gateway = FakeGateway(gateway)
        self.server = MCPServer(self.gateway, lambda: [QWEN], fetch=lambda url: (b"\x89PNG", "image/png"))

    def call(self, tool, **args):
        return self.server.handle(rpc("tools/call", {"name": tool, "arguments": args}))["result"]

    def test_initialize_and_list(self):
        init = self.server.handle(rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}}))["result"]
        self.assertEqual(init["protocolVersion"], "2025-03-26")
        self.assertIn("tools", init["capabilities"])
        self.assertEqual(self.server.handle(rpc("initialize", {"protocolVersion": "1999"}))["result"]["protocolVersion"],
                         "2025-06-18")
        tools = self.server.handle(rpc("tools/list"))["result"]["tools"]
        self.assertEqual({t["name"] for t in tools}, {t["name"] for t in TOOLS})
        self.assertTrue(all(t["inputSchema"]["type"] == "object" for t in tools))

    def test_notifications_and_errors(self):
        self.assertIsNone(self.server.handle(rpc("notifications/initialized", msg_id=None)))
        self.assertEqual(self.server.handle_body(rpc("notifications/initialized", msg_id=None)), (202, None))
        self.assertEqual(self.server.handle(rpc("nope"))["error"]["code"], -32601)
        self.assertEqual(self.server.handle({"method": "x"})["error"]["code"], -32600)
        status, batch = self.server.handle_body([rpc("ping", msg_id=1), rpc("ping", msg_id=2)])
        self.assertEqual((status, [r["id"] for r in batch]), (200, [1, 2]))
        unknown = self.call("rm_rf")
        self.assertTrue(unknown["isError"])

    def test_ask_agentim(self):
        result = self.call("ask_agentim", message="hello", conversation="c1", agent="startup-validator")
        self.assertEqual(result["content"][0]["text"], "echo: hello")
        self.assertEqual(self.gateway.sent[-1][:2], ("api", "mcp-c1"))
        self.assertEqual(self.gateway.store.agent("api:mcp-c1"), "startup-validator")
        self.assertTrue(self.call("ask_agentim", message="hi", agent="nobody")["isError"])
        self.assertTrue(self.call("ask_agentim", message="  ")["isError"])
        self.assertTrue(self.call("ask_agentim")["isError"], "missing argument")

    def test_media(self):
        image = self.call("generate_image", prompt="an octopus")["content"]
        self.assertEqual(self.gateway.sent[-1][2], "/image an octopus")
        self.assertIn("image: http://localhost:8766/files/x.png", image[0]["text"])
        self.assertEqual(image[1], {"type": "image", "data": "iVBORw==", "mimeType": "image/png"})
        self.call("generate_video", prompt="a cat surfing")
        self.assertEqual(self.gateway.sent[-1][2], "/video a cat surfing")

    def test_catalog_tools(self):
        self.assertIn("startup-validator", self.call("list_agents")["content"][0]["text"])
        self.assertIn(QWEN.alias, self.call("list_models")["content"][0]["text"])
        self.assertFalse(self.call("list_skills")["isError"])

    def test_startup_flow(self):
        self.assertIn("No startups", self.call("list_startups")["content"][0]["text"])
        created = self.call("create_startup", pitch=PITCH, name="Leafy")["content"][0]["text"]
        self.assertIn("Created Leafy", created)
        self.assertIn("1. ", created)
        partial = self.call("answer_startup_questions", startup="1", answers=["Office managers"])["content"][0]["text"]
        self.assertIn("questions left", partial)
        self.assertTrue(self.call("run_startup_meeting", startup="leafy")["isError"], "interview first")
        done = self.call("answer_startup_questions", startup="Leafy", skip=True)["content"][0]["text"]
        self.assertIn("is running", done)
        detail = json.loads(self.call("get_startup", startup="1")["content"][0]["text"])
        self.assertEqual(detail["interview"][0]["answer"], "Office managers")
        self.assertIn("🐙 Agent Tim, CEO", detail["team"])
        self.assertTrue(self.call("get_startup", startup="99")["isError"])


class HTTPTests(unittest.TestCase):
    def setUp(self):
        gateway, _ = make_startup_mode()
        gateway.config.mcp_secret = "s" * 24
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(gateway, {}, lambda: [QWEN]))
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_port}"

    def tearDown(self):
        self.httpd.shutdown()

    def post(self, path, body, token=None):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = f"Bearer {token}"
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode(), headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                raw = resp.read()
                return resp.status, json.loads(raw) if raw else None
        except urllib.error.HTTPError as e:
            return e.code, None

    def test_auth(self):
        self.assertEqual(self.post("/mcp", rpc("ping"))[0], 401)
        self.assertEqual(self.post("/mcp", rpc("ping"), token="tok"), (200, {"jsonrpc": "2.0", "id": 1, "result": {}}))
        self.assertEqual(self.post("/mcp/" + "s" * 24, rpc("ping"))[0], 200, "secret path for ChatGPT")
        self.assertEqual(self.post("/mcp/wrong", rpc("ping"))[0], 401)
        self.assertEqual(self.post("/mcp", rpc("notifications/initialized", msg_id=None), token="tok"), (202, None))

    def test_empty_secret_never_matches(self):
        self.assertEqual(self.post("/mcp/", rpc("ping"))[0], 401, "empty secret never matches")

    def test_get_is_not_allowed(self):
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(self.base + "/mcp", timeout=5)
        self.assertEqual(caught.exception.code, 405)

    def test_stdio_bridge(self):
        lines = "\n".join(json.dumps(m) for m in [
            rpc("initialize", {"protocolVersion": "2025-06-18"}), rpc("notifications/initialized", msg_id=None),
            rpc("tools/list", msg_id=2)]) + "\nnot json\n"
        out = io.StringIO()
        os.environ["AGENTIM_URL"], os.environ["AGENTIM_TOKEN"] = self.base + "/mcp", "tok"
        try:
            agentim_mcp.main(io.StringIO(lines), out)
        finally:
            del os.environ["AGENTIM_URL"], os.environ["AGENTIM_TOKEN"]
        responses = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([r.get("id") for r in responses], [1, 2, None])
        self.assertEqual(responses[0]["result"]["serverInfo"]["name"], "agentim")
        self.assertEqual(responses[2]["error"]["code"], -32700)

    def test_bridge_reports_a_stopped_gateway(self):
        response = agentim_mcp.forward(rpc("ping"), "http://127.0.0.1:9/mcp", "tok")
        self.assertIn("isn't running", response["error"]["message"])

    def test_bridge_reads_the_env_file(self):
        with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as f:
            f.write("RUNNER_TOKEN=runner\nAGENTIM_API_TOKEN=\"api\"\nAGENTIM_PORT=9999\n")
        try:
            self.assertEqual(agentim_mcp.settings({}, f.name), ("http://localhost:9999/mcp", "api"))
            self.assertEqual(agentim_mcp.settings({"AGENTIM_TOKEN": "t", "AGENTIM_URL": "http://x/mcp"}, f.name),
                             ("http://x/mcp", "t"))
        finally:
            os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
