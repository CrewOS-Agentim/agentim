import json
import os
import sqlite3
import sys
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from agentim.server import make_handler  # noqa: E402
from agentim.startup import (MAX_TEAM, ROLE_PRESETS, TEAM, StartupStore, normalize_team, people_of,  # noqa: E402
                             person_dict, team_of)
from test_gateway import QWEN  # noqa: E402
from test_startup import PITCH, CompanyLLM, make_startup_mode  # noqa: E402

JORDAN = {"name": "Jordan Lee", "title": "Customer Success", "emoji": "🫶", "owns": "onboarding and retention"}


class TeamLLM(CompanyLLM):
    """Like CompanyLLM, but answers as any person (including newly hired ones)."""

    def complete(self, model, system, messages):
        prompt = messages[-1]["content"]
        if prompt.startswith("You are ") and " at \"" in prompt and not prompt.startswith("You are Agent Tim"):
            self.prompts.append(prompt)
            first = prompt[len("You are "):].split()[0]
            return f"{first} here: did my part. @Maya, thoughts?"
        return super().complete(model, system, messages)


def running(mode, **kwargs):
    return mode.skip_questions(mode.create(PITCH, **kwargs)["id"])


class NormalizeTests(unittest.TestCase):
    def test_keys_are_unique_and_defaults_filled(self):
        team = normalize_team([{"name": "Ana Ruiz", "title": "Designer"}, {"name": "Ana Ruiz", "title": "Designer"}])
        self.assertEqual(len({m["key"] for m in team}), 2)
        self.assertEqual(team[0]["emoji"], "🧑‍💼")
        self.assertIn("Designer", team[0]["owns"])

    def test_validation(self):
        for bad in ([], [{"name": "", "title": "PM"}], [{"name": "Agent Tim", "title": "CEO"}],
                    [{"name": f"Person {i}", "title": "PM"} for i in range(MAX_TEAM + 1)]):
            with self.assertRaises(ValueError):
                normalize_team(bad)

    def test_old_startups_get_the_default_team(self):
        self.assertEqual([p.key for p in team_of({"team": []})], [p.key for p in TEAM])
        self.assertIn("ceo", people_of({}))

    def test_presets(self):
        self.assertTrue(all({"title", "emoji", "owns"} <= set(p) for p in ROLE_PRESETS))


class TeamTests(unittest.TestCase):
    def test_new_startups_start_with_the_default_team(self):
        _, mode = make_startup_mode()
        startup = mode.create(PITCH)
        self.assertEqual([m["name"] for m in startup["team"]], [p.name for p in TEAM])

    def test_create_with_a_custom_team(self):
        _, mode = make_startup_mode()
        startup = mode.create(PITCH, team=[JORDAN, {"name": "Kai Mori", "title": "CTO"}])
        self.assertEqual([m["name"] for m in startup["team"]], ["Jordan Lee", "Kai Mori"])
        self.assertIn("Customer Success (Jordan)", startup["plan"])

    def test_edit_hire_fire(self):
        _, mode = make_startup_mode()
        startup = running(mode)
        members = startup["team"]
        members[0] = {**members[0], "name": "Maya Gold", "owns": "pricing and packaging"}
        startup = mode.set_team(startup["id"], members)
        self.assertEqual(startup["team"][0]["name"], "Maya Gold")
        startup = mode.hire(startup["id"], "Jordan Lee", "Customer Success", "onboarding and retention")
        self.assertEqual(startup["team"][-1]["name"], "Jordan Lee")
        startup = mode.fire(startup["id"], "omar")
        self.assertNotIn("Omar Haddad", [m["name"] for m in startup["team"]])
        self.assertIn("Omar Haddad", [m["name"] for m in startup["alumni"]])
        with self.assertRaises(ValueError):
            mode.fire(startup["id"], "nobody")
        # Rehiring brings them back from the alumni list.
        startup = mode.hire(startup["id"], "Omar Haddad", "Business Development")
        self.assertNotIn("Omar Haddad", [m["name"] for m in startup["alumni"]])

    def test_meetings_use_only_the_current_team(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = running(mode)
        startup = mode.set_team(startup["id"], [JORDAN, {"name": "Kai Mori", "title": "CTO", "owns": "architecture"}])
        mode.run_round(startup["id"])
        speakers = {m["role"] for m in mode.store.messages(startup["id"]) if m["role"] != "ceo"}
        self.assertEqual(speakers, {m["key"] for m in startup["team"]}, "2 people → both speak, nobody else")
        jordan_prompt = next(p for p in llm.prompts if p.startswith("You are Jordan Lee"))
        self.assertIn("Kai (CTO)", jordan_prompt)
        self.assertNotIn("Maya", jordan_prompt.split("Your colleagues:")[1].split(".")[0])

    def test_former_employees_stay_in_history_not_in_context(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = running(mode)
        mode.run_round(startup["id"])
        spoke = [m["role"] for m in mode.store.messages(startup["id"]) if m["role"] != "ceo"]
        leaver = next(p for p in TEAM if p.key == spoke[0])
        startup = mode.fire(startup["id"], leaver.key)
        detail = mode.detail(startup["id"])
        self.assertTrue(detail["people"][leaver.key]["former"])
        self.assertFalse(detail["people"]["ceo"]["former"])
        llm.prompts.clear()
        mode.run_round(startup["id"])
        self.assertFalse(any(f"{leaver.name}:" in p for p in llm.prompts), "the leaver's old messages aren't in context")


class MigrationTests(unittest.TestCase):
    def test_old_database_gets_team_columns(self):
        db = sqlite3.connect(":memory:", check_same_thread=False)
        db.execute("""CREATE TABLE startups (id TEXT PRIMARY KEY, name TEXT, pitch TEXT, questions TEXT, answers TEXT,
            status TEXT, plan TEXT, min_minutes INTEGER, max_minutes INTEGER, next_run REAL, rounds INTEGER,
            notify_channel TEXT, notify_chat TEXT, created REAL, updated REAL)""")
        db.execute("INSERT INTO startups VALUES ('old', 'Old Co', 'p', '[]', '[]', 'running', '# Old', 10, 30, NULL, 2, NULL, NULL, 1, 1)")
        store = StartupStore(db, threading.Lock())
        old = store.get("old")
        self.assertEqual((old["team"], old["alumni"]), ([], []))
        self.assertEqual(len(team_of(old)), len(TEAM))


class ChatTests(unittest.TestCase):
    def test_team_hire_fire_commands(self):
        gateway, mode = make_startup_mode()
        running(mode)
        say = lambda text: gateway.handle("telegram", "c", "1", text)[0].text  # noqa: E731
        self.assertIn("Maya Chen", say("/startup team 1"))
        self.assertIn("Jordan Lee* joined", say("/startup hire 1 Jordan Lee | Customer Success | onboarding and retention"))
        self.assertIn("Use `/startup hire", say("/startup hire 1 Jordan Lee"))
        self.assertIn("has 8 people", say("/startup fire 1 Omar"))
        self.assertIn("No one called", say("/startup fire 1 Nobody"))
        self.assertIn("Which startup", say("/startup fire 9 Maya"))


class APITests(unittest.TestCase):
    def test_team_endpoint(self):
        gateway, mode = make_startup_mode()
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(gateway, {}, lambda: [QWEN]))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"

        def call(path, body=None):
            req = urllib.request.Request(base + path, data=json.dumps(body).encode() if body is not None else None,
                                         headers={"Authorization": "Bearer tok", "Content-Type": "application/json"},
                                         method="POST" if body is not None else "GET")
            try:
                with urllib.request.urlopen(req, timeout=5) as resp:
                    return resp.status, json.loads(resp.read())
            except urllib.error.HTTPError as e:
                return e.code, json.loads(e.read())

        try:
            status, created = call("/v1/startups", {"pitch": PITCH, "team": [JORDAN]})
            self.assertEqual([m["name"] for m in created["team"]], ["Jordan Lee"])
            self.assertTrue(created["presets"])
            team = created["team"] + [person_dict(TEAM[1])]
            status, body = call(f"/v1/startups/{created['id']}/team", {"team": team})
            self.assertEqual((status, [m["name"] for m in body["team"]]), (200, ["Jordan Lee", "Leo Park"]))
            self.assertEqual(call(f"/v1/startups/{created['id']}/team", {"team": []})[0], 400)
        finally:
            server.shutdown()


if __name__ == "__main__":
    unittest.main()
