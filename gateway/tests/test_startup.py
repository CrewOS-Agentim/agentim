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
from agentim.startup import (CEO, FALLBACK_QUESTIONS, PEOPLE, TEAM, StartupMode, StartupStore, name_from_pitch,  # noqa: E402
                             parse_questions, pick_speakers, split_ceo)
from test_gateway import QWEN, make_gateway  # noqa: E402

PITCH = "A monthly subscription that delivers and swaps office plants. Offices always look alive."


class Clock:
    def __init__(self, now=1_000_000.0):
        self.now = now

    def __call__(self):
        return self.now


class CompanyLLM:
    """Plays every part: asks questions in interviews, answers as the person addressed, runs the CEO."""

    def __init__(self, fail=False):
        self.prompts = []
        self.fail = fail

    def complete(self, model, system, messages):
        prompt = messages[-1]["content"]
        self.prompts.append(prompt)
        if self.fail:
            raise LLMError("down")
        if "follow-up questions" in prompt.lower():
            return "1. Who manages plants at your target offices today?\n" + "\n".join(
                f"{i}. Follow-up question number {i} about this pitch?" for i in range(2, 11))
        if prompt.startswith("You are Agent Tim, CEO"):
            return "PLAN:\n# Plants\n## Top 3 priorities\n1. Pre-sell 3 pilots (Zoe)\nSUMMARY:\nPre-sell 3 pilots; Zoe owns it."
        person = next((p for p in TEAM if prompt.startswith(f"You are {p.name}")), None)
        if person is None:
            return f"answer from {model.alias}"  # ordinary chat
        return f"I'm {person.first}. Shipped a draft. @Leo, can you mock the booking screen?"


def make_startup_mode(llm=None, seed=7, clock=None):
    gateway = make_gateway(models=(QWEN,), llm=llm or CompanyLLM())
    mode = StartupMode(gateway, StartupStore(gateway.store.db, gateway.store.lock), rng=random.Random(seed),
                       clock=clock or Clock())
    gateway.startup = mode
    return gateway, mode


class HelperTests(unittest.TestCase):
    def test_team_are_people_in_the_asked_roles(self):
        titles = " ".join(p.title for p in TEAM)
        for role in ("CPO", "Designer", "CTO", "CMO", "Marketing Automation", "CRO", "Business Development",
                     "CFO", "Data Analyst", "CISO", "COO"):
            self.assertIn(role, titles)
        self.assertLessEqual(len(TEAM), 12, "fits the team cap")
        self.assertTrue(all(len(p.name.split()) == 2 for p in TEAM), "everyone has a first and last name")
        self.assertEqual(CEO.name, "Agent Tim")

    def test_rotation_covers_everyone(self):
        rng, last, spoken = random.Random(1), {}, []
        for round_no in range(1, 4):
            picked = pick_speakers(last, 4, rng)
            spoken += [p.key for p in picked]
            last.update({p.key: round_no for p in picked})
        self.assertEqual(len(set(spoken)), len(TEAM))

    def test_parse_questions(self):
        text = "Sure! Here are questions:\n1. Who pays for it today?\n2) How much?? really\n- Which offices first?\nThanks"
        self.assertEqual(parse_questions(text), ["Who pays for it today?", "How much?", "Which offices first?"])

    def test_parse_questions_drops_made_up_answers(self):
        text = ("1. **What are you making?** Leafy is a subscription service.\n"
                "2. Who desperately needs it? A specific employee who is tired.\n"
                "3. A statement without a question mark")
        self.assertEqual(parse_questions(text), ["What are you making?", "Who desperately needs it?"])

    def test_parse_questions_strips_lens_labels(self):
        text = ("1. YC Partner**: What's the biggest pain point you solve?\n"
                "2. **Co-founder:** Who decides when you disagree?\n"
                "3. (YC) Why now?\n"
                "4. Who pays for it today?")
        self.assertEqual(parse_questions(text), ["What's the biggest pain point you solve?",
                                                 "Who decides when you disagree?", "Why now?", "Who pays for it today?"])

    def test_name_from_pitch(self):
        self.assertEqual(name_from_pitch("Uber for dog walking. With GPS."), "Uber for dog walking")
        self.assertTrue(name_from_pitch("one two three four five six seven eight").endswith("…"))

    def test_split_ceo(self):
        self.assertEqual(split_ceo("PLAN:\nP\nSUMMARY:\nS", "old"), ("P", "S"))
        self.assertEqual(split_ceo("", "old"), ("old", ""))
        self.assertEqual(split_ceo("**PLAN**\n# Leafy\n\n**Summary**\nShip pilots.", "old"), ("# Leafy", "Ship pilots."))
        self.assertEqual(split_ceo("# Leafy\n### Summary\nZoe sells.", "old"), ("# Leafy", "Zoe sells."))
        self.assertEqual(split_ceo("PLAN:\nP\n**Summary:** Do it.", "old"), ("P", "Do it."))


class InterviewTests(unittest.TestCase):
    def test_pitch_gets_follow_up_questions_from_the_skill(self):
        llm = CompanyLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = mode.create(PITCH)
        self.assertEqual(startup["status"], "interview")
        self.assertEqual(len(startup["questions"]), 10)
        prompt = llm.prompts[0]
        self.assertIn("YC Partner", prompt)
        self.assertIn("What's the insight?", prompt, "uses the YC Partner skill")
        self.assertIn("Co-founder", prompt)
        self.assertIn("Kill criteria", prompt, "uses the Co-founder skill")
        self.assertIn("exactly 10", prompt)
        self.assertIn(PITCH, prompt)

    def test_falls_back_to_standard_questions(self):
        _, mode = make_startup_mode(llm=CompanyLLM(fail=True))
        self.assertEqual(mode.create(PITCH)["questions"], FALLBACK_QUESTIONS)
        self.assertEqual(len(FALLBACK_QUESTIONS), 10)

    def test_answers_launch_the_team(self):
        clock = Clock()
        _, mode = make_startup_mode(clock=clock)
        startup = mode.create(PITCH)
        startup = mode.answer(startup["id"], ["Office managers", "$300", "Austin coworkings"])
        self.assertEqual(startup["status"], "interview", "7 questions still open")
        startup = mode.answer(startup["id"], [f"answer {i}" for i in range(10)])
        self.assertEqual(startup["status"], "running")
        self.assertEqual(startup["next_run"], clock.now + 60)

    def test_short_pitch_is_rejected(self):
        _, mode = make_startup_mode()
        with self.assertRaises(ValueError):
            mode.create("plants")


class MeetingTests(unittest.TestCase):
    def running(self, mode, pitch=PITCH):
        return mode.skip_questions(mode.create(pitch)["id"])

    def test_meeting_updates_plan_rotates_and_reschedules(self):
        clock, llm = Clock(), CompanyLLM()
        _, mode = make_startup_mode(llm=llm, clock=clock)
        sent = []
        mode.notify = lambda channel, chat, text: sent.append((channel, chat, text))
        mode.notify_mode = "meeting"  # AGENTIM_STARTUP_NOTIFY=meeting: a message after every meeting
        startup = mode.create(PITCH, channel="telegram", chat_id="42")
        mode.set_rhythm(startup["id"], "timer")  # this test covers the every-10–30-minutes rhythm
        mode.answer(startup["id"], ["Office managers", "$300", "Austin"] + ["more"] * 7)
        text = mode.run_round(startup["id"])
        after = mode.store.get(startup["id"])
        self.assertEqual(after["rounds"], 1)
        self.assertIn("Pre-sell 3 pilots", after["plan"])
        self.assertTrue(clock.now + 10 * 60 <= after["next_run"] <= clock.now + 30 * 60)
        roles = [m["role"] for m in mode.store.messages(startup["id"])]
        self.assertEqual((len(roles), roles[-1]), (5, "ceo"), "four agents speak, then Tim")
        self.assertIn("meeting 1", text)
        self.assertEqual(sent[0][:2], ("telegram", "42"))
        person_prompt = next(p for p in llm.prompts if p.startswith("You are Maya") or p.startswith("You are Leo")
                             or p.startswith("You are Noah") or p.startswith("You are Ava") or p.startswith("You are Sam")
                             or p.startswith("You are Zoe") or p.startswith("You are Omar") or p.startswith("You are Grace"))
        self.assertIn("Founder's answers", person_prompt)
        self.assertIn("Office managers", person_prompt)
        mode.run_round(startup["id"])
        first = {m["role"] for m in mode.store.messages(startup["id"]) if m["round"] == 1 and m["role"] != "ceo"}
        second = {m["role"] for m in mode.store.messages(startup["id"]) if m["round"] == 2 and m["role"] != "ceo"}
        self.assertTrue(first.isdisjoint(second), "new people speak in meeting 2")

    def test_many_startups_are_independent(self):
        clock = Clock()
        _, mode = make_startup_mode(clock=clock)
        a = self.running(mode, PITCH)
        b = self.running(mode, "Uber for dog walking in big cities, with GPS tracking.")
        clock.now += 61
        self.assertEqual({s["id"] for s in mode.due()}, {a["id"], b["id"]})
        mode.run_round(a["id"])
        self.assertEqual([s["id"] for s in mode.due()], [b["id"]])
        self.assertEqual(mode.store.messages(b["id"]), [])
        mode.set_enabled(b["id"], False)
        self.assertEqual(mode.due(), [])

    def test_interviewing_startups_dont_meet(self):
        _, mode = make_startup_mode()
        startup = mode.create(PITCH)
        self.assertIsNone(mode.run_round(startup["id"]))

    def test_models_down_still_reschedules(self):
        clock = Clock()
        _, mode = make_startup_mode(llm=CompanyLLM(fail=True), clock=clock)
        startup = self.running(mode)
        self.assertIsNone(mode.run_round(startup["id"]))
        self.assertGreaterEqual(mode.store.get(startup["id"])["next_run"], clock.now + 10 * 60)

    def test_delete(self):
        _, mode = make_startup_mode()
        startup = self.running(mode)
        mode.run_round(startup["id"])
        mode.delete(startup["id"])
        self.assertEqual((mode.store.all(), mode.store.messages(startup["id"])), ([], []))


class ChatTests(unittest.TestCase):
    def test_pitch_interview_and_list_in_chat(self):
        gateway, mode = make_startup_mode()
        say = lambda text: gateway.handle("telegram", "c", "1", text)[0].text  # noqa: E731
        self.assertIn("/startup new", say("/startup"))
        reply = say(f"/startup new {PITCH}")
        self.assertIn("1/10", reply)
        self.assertIn("Who manages plants", reply)
        self.assertIn("2/10", say("Office managers, they hate watering"))
        for n in range(3, 11):
            self.assertIn(f"{n}/10", say(f"answer {n - 1}"))
        self.assertIn("has a team now", say("10 coworkings in Austin"))
        startup = mode.store.all()[0]
        self.assertEqual(len(startup["answers"]), 10)
        self.assertEqual(startup["answers"][0], "Office managers, they hate watering")
        self.assertIn("1. *", say("/startup"))
        self.assertIn("paused", say("/startup off 1"))
        self.assertIn("back on", say("/startup on 1"))
        self.assertIn("# ", say("/startup 1"))
        # After the interview, normal chat goes to the model again.
        self.assertIn("answer from", say("hello"))

    def test_skip(self):
        gateway, mode = make_startup_mode()
        gateway.handle("telegram", "c", "1", f"/startup new {PITCH}")
        self.assertIn("Skipping", gateway.handle("telegram", "c", "1", "skip")[0].text)
        self.assertEqual(mode.store.all()[0]["status"], "running")

    def test_interview_is_per_chat(self):
        gateway, _ = make_startup_mode()
        gateway.handle("telegram", "c", "1", f"/startup new {PITCH}")
        self.assertIn("answer from", gateway.handle("telegram", "other", "1", "hello")[0].text)

    def test_strangers_cannot_create_startups(self):
        gateway, mode = make_startup_mode()
        self.assertIn("doesn't know you", gateway.handle("telegram", "c", "999", f"/startup new {PITCH}")[0].text)
        self.assertEqual(mode.store.all(), [])


class APITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gateway, cls.mode = make_startup_mode()
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(cls.gateway, {}, lambda: [QWEN]))
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def call(self, path, body=None, method=None, token="tok"):
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                                     method=method or ("POST" if body is not None else "GET"))
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, json.loads(resp.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def test_flow(self):
        self.assertEqual(self.call("/v1/startups", token="nope")[0], 401)
        self.assertEqual(self.call("/v1/startups", {"pitch": "x"})[0], 400)
        status, created = self.call("/v1/startups", {"pitch": PITCH, "name": "Leafy", "min_minutes": 15, "max_minutes": 20})
        self.assertEqual((status, created["name"], created["status"], len(created["questions"])), (201, "Leafy", "interview", 10))
        sid = created["id"]
        answers = [f"a{i}" for i in range(10)]
        status, body = self.call(f"/v1/startups/{sid}/answers", {"answers": answers})
        self.assertEqual((status, body["status"], body["answers"]), (200, "running", answers))
        self.assertEqual(self.call(f"/v1/startups/{sid}/run", {})[0], 202)
        for _ in range(60):
            if self.mode.store.get(sid)["rounds"] >= 1:
                break
            threading.Event().wait(0.05)
        status, detail = self.call(f"/v1/startups/{sid}")
        self.assertGreaterEqual(detail["rounds"], 1)
        self.assertIn("ceo", detail["people"])
        self.assertEqual(detail["people"]["product"]["name"], "Maya Chen")
        status, listing = self.call("/v1/startups")
        self.assertEqual([s["name"] for s in listing["startups"]], ["Leafy"])
        self.assertEqual(len(listing["team"]), len(TEAM))
        status, body = self.call(f"/v1/startups/{sid}", {"enabled": False})
        self.assertEqual(body["status"], "paused")
        self.assertEqual(self.call("/v1/startups/nope")[0], 404)
        self.assertEqual(self.call(f"/v1/startups/{sid}", method="DELETE")[0], 200)
        self.assertEqual(self.call("/v1/startups")[1]["startups"], [])


class SkillConfigTests(unittest.TestCase):
    def test_interview_skills_are_configurable(self):
        from agentim import config as config_lib
        default = config_lib.from_env({"AGENTIM_DATA_DIR": "/tmp"})
        self.assertEqual((default.startup_skills, default.startup_questions), (["yc-partner", "co-founder"], 10))
        custom = config_lib.from_env({"AGENTIM_DATA_DIR": "/tmp", "AGENTIM_STARTUP_SKILLS": "grill-me",
                                      "AGENTIM_STARTUP_QUESTIONS": "5"})
        self.assertEqual((custom.startup_skills, custom.startup_questions), (["grill-me"], 5))

    def test_yc_and_cofounder_skills_ship(self):
        gateway, _ = make_startup_mode()
        self.assertTrue({"yc-partner", "co-founder"} <= {s.slug for s in gateway.skills})


class PeopleTests(unittest.TestCase):
    def test_people_table(self):
        self.assertEqual(set(PEOPLE), {p.key for p in TEAM} | {"ceo"})


if __name__ == "__main__":
    unittest.main()
