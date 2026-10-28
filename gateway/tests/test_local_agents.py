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


if __name__ == "__main__":
    unittest.main()
