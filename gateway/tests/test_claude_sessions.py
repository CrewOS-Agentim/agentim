import io
import json
import os
import sys
import time
import unittest
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agentim.claude_sessions import ClaudeSessions  # noqa: E402

SESSIONS = [{"id": "aaaa-1111", "title": "Login fix", "cwd": "/Users/me/code/my-app", "updated": time.time() - 120,
             "messages": 4, "first_prompt": "Why does login fail?"}]


class Config:
    runner_urls = ["http://runner:8765", "http://host.docker.internal:8766"]
    runner_token = "tok"


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def fake_opener(calls):
    """Docker runner says 404 (no sessions there); the Mac's runner answers."""

    def opener(req, timeout=0):
        calls.append((req.get_method(), req.full_url, json.loads(req.data) if req.data else None))
        if req.full_url.startswith("http://runner:8765"):
            raise urllib.error.HTTPError(req.full_url, 404, "not here", {}, io.BytesIO(b'{"error":{"message":"no"}}'))
        if req.full_url.endswith("/v1/claude/sessions"):
            return FakeResponse(json.dumps({"sessions": SESSIONS}).encode())
        if req.full_url.endswith("/continue"):
            return FakeResponse(json.dumps({"id": "aaaa-1111", "cwd": "/Users/me/code/my-app",
                                            "reply": "Plan: refresh the token."}).encode())
        return FakeResponse(json.dumps({**SESSIONS[0], "messages_shown": [
            {"role": "user", "text": "Why does login fail?"}, {"role": "assistant", "text": "The token expires."}]}).encode())

    return opener


class ClaudeSessionsTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.claude = ClaudeSessions(Config(), opener=fake_opener(self.calls))

    def test_falls_through_to_the_mac_runner(self):
        self.assertEqual(self.claude.list()[0]["id"], "aaaa-1111")
        self.assertEqual([c[1].split("/v1")[0] for c in self.calls], ["http://runner:8765", "http://host.docker.internal:8766"])

    def test_chat_commands(self):
        listing = self.claude.command("")
        self.assertIn("1. *Login fix* · my-app · 2 min ago", listing)
        shown = self.claude.command("1")
        self.assertIn("🧑 Why does login fail?", shown)
        self.assertIn("🤖 The token expires.", shown)
        reply = self.claude.command("1 now write the fix")
        self.assertIn("Plan: refresh the token.", reply)
        self.assertEqual(self.calls[-1][2], {"prompt": "now write the fix"})
        self.assertIn("Which one", self.claude.command("7"))

    def test_runner_refusal_is_explained(self):
        def refusing(req, timeout=0):
            raise urllib.error.HTTPError(req.full_url, 400, "bad", {},
                                         io.BytesIO(b'{"error":{"message":"Enable Claude Code first"}}'))

        self.assertIn("Enable Claude Code first", ClaudeSessions(Config(), opener=refusing).command(""))

    def test_nobody_answers(self):
        def down(req, timeout=0):
            raise urllib.error.URLError("refused")

        self.assertIn("No runner on this Mac answered", ClaudeSessions(Config(), opener=down).command(""))


if __name__ == "__main__":
    unittest.main()
