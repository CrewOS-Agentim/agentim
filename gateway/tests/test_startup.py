import json
import os
import random
import sys
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agentim.llm import LLMError  # noqa: E402
from agentim.server import make_handler  # noqa: E402
from agentim.startup import (CHIEF, ROLES, TEAM, StartupMode, StartupStore, initial_plan, pick_speakers,  # noqa: E402
                             split_chief)
from test_gateway import QWEN, make_gateway  # noqa: E402


class Clock:
    def __init__(self, now=1_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class TeamLLM:
    """Answers as whichever role the prompt addresses; the chief returns a PLAN/SUMMARY."""

    def __init__(self, fail=False):
        self.prompts = []
        self.fail = fail

    def complete(self, model, system, messages):
        prompt = messages[-1]["content"]
        self.prompts.append(prompt)
        if self.fail:
            raise LLMError("down")
        if prompt.startswith("You are the Chief of Staff"):
            return "PLAN:\n# Dog walking\n## Top 3 priorities\n1. Pre-sell 10 walks\nSUMMARY:\nPre-sell 10 walks this week."
        role = next(r for r in TEAM if prompt.startswith(f"You are the {r.name} lead"))
        return f"{role.name} idea. @Design please mock the booking screen."


def make_startup(llm=None, seed=7, clock=None):
    gateway = make_gateway(models=(QWEN,), llm=llm or TeamLLM())
    store = StartupStore(gateway.store.db, gateway.store.lock)
    startup = StartupMode(gateway, store, rng=random.Random(seed), clock=clock or Clock())
    gateway.startup = startup
    return gateway, startup


class SpeakerTests(unittest.TestCase):
    def test_everyone_gets_a_turn(self):
        rng = random.Random(1)
        last, spoken = {}, []
        for round_no in range(1, 4):
            picked = pick_speakers(last, 3, rng)
            spoken += [r.key for r in picked]
            last.update({r.key: round_no for r in picked})
        self.assertEqual(len(set(spoken)), 8, "8 roles covered in 3 rounds of 3")

    def test_least_recent_first(self):
        last = {r.key: 5 for r in TEAM}
        last["design"] = 1
        self.assertEqual(pick_speakers(last, 1, random.Random(0))[0].key, "design")

    def test_team_covers_the_asked_areas(self):
        names = " ".join(r.name for r in TEAM)
        for area in ("Sales", "Business Development", "Marketing & Social", "Marketing Automation",
                     "Engineering", "Product", "Design"):
            self.assertIn(area, names)


class RoundTests(unittest.TestCase):
    def test_start_schedules_first_round_soon(self):
        clock = Clock()
        _, startup = make_startup(clock=clock)
        state = startup.start("Uber for dog walking", "telegram", "42")
        self.assertTrue(state["enabled"])
        self.assertEqual(state["next_run"], clock.now + 60)
        self.assertIn("Uber for dog walking", state["plan"])
        self.assertFalse(startup.due())
        clock.now += 61
        self.assertTrue(startup.due())

    def test_round_updates_plan_messages_and_reschedules_10_to_30_min(self):
        clock = Clock()
        llm = TeamLLM()
        _, startup = make_startup(llm=llm, clock=clock)
        sent = []
        startup.notify = lambda channel, chat, text: sent.append((channel, chat, text))
        startup.start("Uber for dog walking", "telegram", "42")
        text = startup.run_round()
        state = startup.store.get()
        self.assertEqual(state["rounds"], 1)
        self.assertIn("Pre-sell 10 walks", state["plan"])
        self.assertTrue(clock.now + 10 * 60 <= state["next_run"] <= clock.now + 30 * 60)
        messages = startup.store.messages()
        self.assertEqual([m["role"] for m in messages][-1], CHIEF.key)
        self.assertEqual(len(messages), 4, "3 teammates + chief")
        self.assertIn("Startup round 1", text)
        self.assertEqual(sent[0][:2], ("telegram", "42"))
        # Teammates see each other's posts within the round.
        self.assertIn("idea. @Design", llm.prompts[1])

    def test_rounds_rotate_and_build_on_history(self):
        llm = TeamLLM()
        _, startup = make_startup(llm=llm)
        startup.start("Uber for dog walking")
        startup.run_round()
        first = {m["role"] for m in startup.store.messages() if m["role"] != CHIEF.key}
        startup.run_round()
        second = {m["round"]: m["role"] for m in startup.store.messages() if m["round"] == 2 and m["role"] != CHIEF.key}
        self.assertTrue(first.isdisjoint(set(second.values())), "new voices in round 2")
        self.assertIn("Recent team discussion", llm.prompts[-2])

    def test_models_down_still_reschedules(self):
        clock = Clock()
        _, startup = make_startup(llm=TeamLLM(fail=True), clock=clock)
        startup.start("x")
        self.assertIsNone(startup.run_round())
        state = startup.store.get()
        self.assertEqual(state["rounds"], 0)
        self.assertGreaterEqual(state["next_run"], clock.now + 10 * 60)

    def test_new_idea_resets_but_same_idea_keeps_history(self):
        _, startup = make_startup()
        startup.start("Idea A")
        startup.run_round()
        startup.start("Idea A")
        self.assertEqual(startup.store.get()["rounds"], 1)
        startup.start("Idea B")
        self.assertEqual((startup.store.get()["rounds"], startup.store.messages()), (0, []))

    def test_stop(self):
        _, startup = make_startup()
        startup.start("x")
        startup.stop()
        self.assertFalse(startup.due())
        self.assertFalse(startup.store.get()["enabled"])

    def test_split_chief(self):
        self.assertEqual(split_chief("PLAN:\nP\nSUMMARY:\nS", "old"), ("P", "S"))
        self.assertEqual(split_chief("", "old"), ("old", ""))
        self.assertIn("### 🎨 Design", initial_plan("An idea"))


class CommandTests(unittest.TestCase):
    def test_commands_through_the_gateway(self):
        gateway, startup = make_startup()
        handle = lambda text: gateway.handle("telegram", "c", "1", text)[0].text  # noqa: E731
        self.assertIn("Start it with", handle("/startup"))
        self.assertIn("Startup Mode is on", handle("/startup Uber for dog walking"))
        self.assertEqual(startup.store.get()["notify_chat"], "c")
        self.assertIn("0 rounds so far", handle("/startup"))
        self.assertIn("paused", handle("/startup off"))
        self.assertIn("back on", handle("/startup on"))
        self.assertIn("/startup", handle("/help"))

    def test_strangers_cannot_start_it(self):
        gateway, startup = make_startup()
        reply = gateway.handle("telegram", "c", "999", "/startup steal my mac")[0].text
        self.assertIn("doesn't know you", reply)
        self.assertIsNone(startup.store.get())


class StartupAPITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gateway, cls.startup = make_startup()
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(cls.gateway, {}, lambda: [QWEN]))
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def call(self, path, body=None, token="tok"):
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                                     method="POST" if body is not None else "GET")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_flow(self):
        self.assertEqual(self.call("/v1/startup", token="nope")[0], 401)
        status, body = self.call("/v1/startup", {"idea": ""})
        self.assertEqual(status, 400)
        status, body = self.call("/v1/startup", {"idea": "Uber for dog walking", "min_minutes": 15, "max_minutes": 20})
        self.assertEqual((status, body["enabled"], body["min_minutes"], body["max_minutes"]), (200, True, 15, 20))
        self.assertEqual(len(body["team"]), len(TEAM))
        self.assertEqual(self.call("/v1/startup/run", {})[0], 202)
        for _ in range(50):
            if self.startup.store.get()["rounds"] >= 1:
                break
            threading.Event().wait(0.05)
        status, body = self.call("/v1/startup")
        self.assertGreaterEqual(body["rounds"], 1)
        self.assertTrue(any(m["role"] == "chief" for m in body["messages"]))
        self.assertIn("chief", body["roles"])
        status, body = self.call("/v1/startup", {"enabled": False})
        self.assertFalse(body["enabled"])


class RolesTests(unittest.TestCase):
    def test_roles_table(self):
        self.assertEqual(set(ROLES), {r.key for r in TEAM} | {"chief"})


if __name__ == "__main__":
    unittest.main()
