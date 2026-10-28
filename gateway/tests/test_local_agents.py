import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agentim.router import Router, model_from_runner  # noqa: E402
from test_gateway import QWEN  # noqa: E402

CLAUDE_CODE = model_from_runner({"id": "local/claude-code", "kind": "agent", "name": "Claude Code"}, "http://host:8766")


class LocalAgentRoutingTests(unittest.TestCase):
    def test_agent_models_are_explicit_only(self):
        self.assertEqual(CLAUDE_CODE.alias, "claude-code")
        self.assertTrue(CLAUDE_CODE.explicit_only)
        router = Router([CLAUDE_CODE, QWEN], "balanced", True)
        for text in ("Refactor this function", "Write a poem", "Review my pull request"):
            decision = router.route(text)
            self.assertEqual(decision.model.id, QWEN.id, text)
            self.assertNotIn(CLAUDE_CODE, decision.fallbacks, "never a silent fallback either")

    def test_called_by_name(self):
        decision = Router([CLAUDE_CODE, QWEN], "balanced", True).route("@claude-code review the auth module")
        self.assertEqual(decision.model.id, "local/claude-code")
        self.assertEqual(decision.text, "review the auth module")

    def test_alone_it_still_isnt_picked_automatically(self):
        from agentim.router import NoModel
        with self.assertRaises(NoModel):
            Router([CLAUDE_CODE], "balanced", True).route("hello")


class TaskLabelTests(unittest.TestCase):
    def test_runner_calls_carry_the_task_label(self):
        from agentim import llm as llm_mod
        from agentim.core import Gateway
        sent = []
        original = llm_mod.post
        llm_mod.post = lambda url, body, headers, timeout: sent.append(headers) or {"choices": [{"message": {"content": "hi"}}]}

        class Config:
            runner_token = "tok"

        try:
            client = llm_mod.LLM(Config())
            client.complete(QWEN, "", [{"role": "user", "content": "hi"}])
            self.assertNotIn("X-Agentim-Task", sent[-1], "unlabelled calls send nothing")
            with llm_mod.labelled("Startup meeting · Leafy · Maya"):
                client.complete(QWEN, "", [{"role": "user", "content": "hi"}])
            from urllib.parse import unquote
            self.assertEqual(unquote(sent[-1]["X-Agentim-Task"]), "Startup meeting · Leafy · Maya", "survives as ASCII")
            self.assertIsNone(llm_mod.task_label.get(), "reset after the block")
        finally:
            llm_mod.post = original
        self.assertEqual(Gateway.task_label("telegram:123"), "Telegram chat")
        self.assertEqual(Gateway.task_label("api:mcp-abc"), "Claude/ChatGPT connector")


if __name__ == "__main__":
    unittest.main()
