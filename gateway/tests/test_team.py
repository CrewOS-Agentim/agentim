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


class GoalsAndLiveMeetingTests(unittest.TestCase):
    def test_prompts_carry_the_operating_principles_and_role_goals(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = running(mode)
        startup = mode.set_team(startup["id"], [person_dict(p) for p in TEAM if p.key in ("sales", "design", "data")])
        mode.run_round(startup["id"])
        people = [p for p in llm.prompts if p.startswith("You are ") and ' at "' in p]
        by_person = {p.split()[2]: p for p in people}  # "You are Zoe Kim, …"
        self.assertEqual(len(people), 3)
        for prompt in people:
            self.assertIn("Launch fast", prompt)
            self.assertIn("Measure everything", prompt)
        self.assertIn("revenue", by_person["Zoe"])
        self.assertIn("design improvement", by_person["Leo"])
        self.assertIn("set up the metrics", by_person["Nina"])

    def test_data_analyst_is_on_the_default_team(self):
        self.assertIn("data", [p.key for p in TEAM])

    def test_live_meeting_state(self):
        seen, ids = [], []

        class Watching(TeamLLM):
            def complete(inner, model, system, messages):
                if ids:
                    seen.append(dict(mode.detail(ids[0])["meeting"] or {}))
                return super().complete(model, system, messages)

        _, mode = make_startup_mode(llm=Watching())
        startup = running(mode)
        ids.append(startup["id"])
        self.assertIsNone(mode.detail(startup["id"])["meeting"], "no meeting yet")
        mode.run_round(startup["id"])
        speaking = [s.get("speaking") for s in seen if s]
        self.assertEqual(speaking[-1], "ceo", "Tim speaks last")
        self.assertEqual(len(set(speaking[:-1])), 4, "four agents take turns")
        self.assertEqual(seen[0]["round"], 1)
        self.assertIsNone(mode.detail(startup["id"])["meeting"], "cleared after the meeting")


class FounderMessageTests(unittest.TestCase):
    def test_message_mid_meeting_reaches_the_next_speakers_and_tim(self):
        posted = []

        class Founder(TeamLLM):
            def complete(inner, model, system, messages):
                prompt = messages[-1]["content"]
                # The founder jumps in while the first agent is talking.
                if not posted and prompt.startswith("You are ") and ' at "' in prompt and not prompt.startswith("You are Agent Tim"):
                    posted.append(mode.post_founder(ids[0], "Focus on enterprise pilots this week."))
                return super().complete(model, system, messages)

        ids = []
        llm = Founder()
        _, mode = make_startup_mode(llm=llm)
        startup = running(mode)
        ids.append(startup["id"])
        mode.run_round(startup["id"])
        self.assertTrue(posted[0]["live"], "posted during the meeting")
        self.assertEqual(posted[0]["round"], 1)
        people = [p for p in llm.prompts if p.startswith("You are ") and ' at "' in p]
        self.assertNotIn("enterprise pilots", people[0], "the first speaker started before it was posted")
        self.assertIn("Founder: Focus on enterprise pilots", people[1], "the next speaker sees it")
        self.assertIn("answering it or acting on it", people[1])
        ceo = next(p for p in llm.prompts if p.startswith("You are Agent Tim"))
        self.assertIn("The founder told the team", ceo)
        self.assertIn("enterprise pilots", ceo)
        roles = [m["role"] for m in mode.store.messages(startup["id"])]
        self.assertIn("founder", roles)
        self.assertEqual(mode.detail(startup["id"])["people"]["founder"]["name"], "Founder")

    def test_message_between_meetings_goes_to_the_next_one(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = running(mode)
        result = mode.post_founder(startup["id"], "Raise prices 20%.")
        self.assertEqual((result["live"], result["round"]), (False, 1))
        mode.run_round(startup["id"])
        ceo = next(p for p in llm.prompts if p.startswith("You are Agent Tim"))
        self.assertIn("Raise prices 20%", ceo)
        llm.prompts.clear()
        mode.run_round(startup["id"])
        ceo = next(p for p in llm.prompts if p.startswith("You are Agent Tim"))
        self.assertNotIn("The founder told the team", ceo, "only new notes reach Tim")

    def test_validation_chat_and_api(self):
        gateway, mode = make_startup_mode()
        startup = running(mode)
        for bad in ("", "   ", "x" * 2001):
            with self.assertRaises(ValueError):
                mode.post_founder(startup["id"], bad)
        say = lambda text: gateway.handle("telegram", "c", "1", text)[0].text  # noqa: E731
        self.assertIn("next meeting", say("/startup say 1 Ship the landing page today"))
        self.assertIn("Use `/startup say", say("/startup say 1"))
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(gateway, {}, lambda: [QWEN]))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/startups/{startup['id']}/messages",
                                         data=json.dumps({"text": "Hello agents"}).encode(), method="POST",
                                         headers={"Authorization": "Bearer tok", "Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = json.loads(resp.read())
            self.assertEqual(body["messages"][-1]["content"], "Hello agents")
            self.assertEqual(body["messages"][-1]["role"], "founder")
        finally:
            server.shutdown()


class PersonaAndPlaybookTests(unittest.TestCase):
    def test_persona_is_saved_trimmed_and_used(self):
        llm = TeamLLM()
        gateway, mode = make_startup_mode(llm=llm)
        startup = running(mode)
        team = [{"name": "Kai Mori", "title": "CTO", "owns": "architecture",
                 "persona": "Ex-Google SRE, dry humour, talks in short bullet points."},
                {"name": "Ana Ruiz", "title": "CMO", "persona": "x" * 900}]
        startup = mode.set_team(startup["id"], team)
        self.assertEqual(len(startup["team"][1]["persona"]), 600, "personas are capped")
        mode.run_round(startup["id"])
        kai = next(p for p in llm.prompts if p.startswith("You are Kai Mori"))
        self.assertIn("Your persona (stay in character", kai)
        self.assertIn("dry humour", kai)

    def test_c_level_titles_get_their_playbook(self):
        from agentim.startup import playbook_slug
        self.assertEqual(playbook_slug("CTO"), "cto")
        self.assertEqual(playbook_slug("Chief Marketing Officer"), "cmo")
        self.assertEqual(playbook_slug("CISO"), "ciso")
        self.assertEqual(playbook_slug("Head of Product (CPO)"), "cpo")
        self.assertEqual(playbook_slug("Designer"), "ui-ux-designer")
        self.assertIsNone(playbook_slug("Director"), "no accidental match inside words")

    def test_playbook_text_reaches_the_prompt(self):
        llm = TeamLLM()
        gateway, mode = make_startup_mode(llm=llm)
        from agentim import skills as skill_lib
        gateway.skills = skill_lib.load_dir(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "skills"))
        startup = running(mode)
        mode.set_team(startup["id"], [{"name": "Kai Mori", "title": "CTO"}])
        mode.run_round(startup["id"])
        kai = next(p for p in llm.prompts if p.startswith("You are Kai Mori"))
        self.assertIn("Your playbook as CTO", kai)
        self.assertIn("DORA", kai)

    def test_old_members_without_persona_still_load(self):
        self.assertEqual(team_of({"team": [{"key": "a", "name": "Ana", "title": "PM", "emoji": "🙂", "owns": "x"}]})[0].persona, "")


class MentionAndNotesTests(unittest.TestCase):
    def test_mentions_are_found_by_first_name_or_key(self):
        from agentim.startup import mentioned
        team = [p for p in TEAM]
        self.assertEqual([p.key for p in mentioned("@Sam come up with 2 designs, @leo help", team)], ["automation", "design"])
        self.assertEqual([p.key for p in mentioned("@data what's the funnel?", team)], ["data"])
        self.assertEqual(mentioned("email me at a@b.com, @nobody", team), [])
        self.assertEqual(len(mentioned("@maya @leo @noah @ava", team)), 3, "at most three")

    def test_tagged_agent_answers_directly(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = running(mode)
        threads_before = threading.active_count()
        result = mode.post_founder(startup["id"], "@Sam come up with 2 designs for the onboarding email")
        self.assertEqual(result["mentioned"], ["automation"])
        for thread in threading.enumerate():
            if thread is not threading.current_thread() and thread.daemon:
                thread.join(timeout=5)
        self.assertGreaterEqual(threads_before, 1)
        prompt = next(p for p in llm.prompts if p.startswith("You are Sam Rivera"))
        self.assertIn('The founder just tagged you directly: "@Sam come up with 2 designs', prompt)
        roles = [m["role"] for m in mode.store.messages(startup["id"])]
        self.assertEqual(roles[-2:], ["founder", "automation"], "Sam answers right after the founder")
        self.assertIsNone(mode.detail(startup["id"])["meeting"], "the direct reply doesn't leave a meeting open")

    def test_meeting_notes(self):
        gateway, mode = make_startup_mode(llm=TeamLLM())
        startup = running(mode)
        mode.run_round(startup["id"])
        mode.post_founder(startup["id"], "Great work, focus on retention")
        mode.run_round(startup["id"])
        meetings = mode.meetings(startup["id"])
        self.assertEqual([m["round"] for m in meetings], [2, 1], "newest first")
        first = meetings[1]
        self.assertLessEqual(first["started"], first["ended"])
        self.assertIn("ceo", first["attendees"])
        self.assertTrue(first["summary"])
        notes = mode.meeting(startup["id"], 2)
        self.assertEqual(notes["messages"][0]["role"], "founder", "the founder's note opens meeting 2")
        self.assertEqual(notes["summary"], next(m["content"] for m in reversed(notes["messages"]) if m["role"] == "ceo"),
                         "Tim's wrap-up (agents' finished work can follow it)")
        self.assertIsNone(mode.meeting(startup["id"], 99))

        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(gateway, {}, lambda: [QWEN]))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}/v1/startups/{startup['id']}/meetings"
        get = lambda url: json.loads(urllib.request.urlopen(urllib.request.Request(  # noqa: E731
            url, headers={"Authorization": "Bearer tok"}), timeout=5).read())
        try:
            self.assertEqual(len(get(base)["meetings"]), 2)
            self.assertEqual(get(base + "/1")["round"], 1)
            with self.assertRaises(urllib.error.HTTPError):
                get(base + "/42")
        finally:
            server.shutdown()


class MinutesTests(unittest.TestCase):
    MINUTES = ("## Summary\nWe chose coworking landlords.\n## Decisions\n- Per-floor pricing (Grace)\n"
               "## Action items\n- **Zoe**: book 3 pilots (by Friday)\n## Metrics\n- 62% margin\n## Open questions\n- None")

    def mode_with_minutes(self, minutes_reply):
        class NoteTaker(TeamLLM):
            def complete(inner, model, system, messages):
                if messages[-1]["content"].startswith("You are the note-taker"):
                    inner.prompts.append(messages[-1]["content"])
                    return minutes_reply
                return super().complete(model, system, messages)

        llm = NoteTaker()
        gateway, mode = make_startup_mode(llm=llm)
        return gateway, mode, llm

    def test_minutes_are_written_after_every_meeting(self):
        _, mode, llm = self.mode_with_minutes(self.MINUTES)
        startup = running(mode)
        mode.run_round(startup["id"])
        notes = mode.meeting(startup["id"], 1)
        self.assertTrue(notes["minutes"].startswith("## Summary"))
        self.assertIn("**Zoe**: book 3 pilots", notes["minutes"])
        self.assertEqual(mode.meetings(startup["id"])[0]["minutes"], notes["minutes"], "the list carries them too")
        prompt = next(p for p in llm.prompts if p.startswith("You are the note-taker"))
        self.assertIn("never invent numbers", prompt)
        self.assertIn("Transcript:", prompt)

    def test_headings_are_normalised_and_junk_falls_back(self):
        from agentim.startup import clean_minutes
        messy = "```\n### summary:\nok\n**Decisions**\n# DECISIONS\n- x\n### Action Items\n- y\n```"
        cleaned = clean_minutes(messy)
        self.assertTrue(cleaned.startswith("## Summary"))
        self.assertIn("## Decisions", cleaned)
        self.assertIn("## Action items", cleaned)
        self.assertIsNone(clean_minutes("Sure! Here are some thoughts."))

        _, mode, _ = self.mode_with_minutes("I can't help with that.")
        startup = running(mode)
        mode.run_round(startup["id"])
        minutes = mode.meeting(startup["id"], 1)["minutes"]
        self.assertTrue(minutes.startswith("## Summary"), "a usable fallback when the model rambles")
        self.assertIn("## Action items", minutes)

    def test_older_meetings_get_minutes_on_request(self):
        gateway, mode, _ = self.mode_with_minutes(self.MINUTES)
        startup = running(mode)
        mode.run_round(startup["id"])
        mode.store.db.execute("DELETE FROM startup_meeting_minutes")  # as if it predates minutes
        self.assertIsNone(mode.meeting(startup["id"], 1)["minutes"])
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(gateway, {}, lambda: [QWEN]))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{server.server_port}/v1/startups/{startup['id']}/meetings/1/minutes",
                data=b"{}", method="POST", headers={"Authorization": "Bearer tok", "Content-Type": "application/json"})
            body = json.loads(urllib.request.urlopen(req, timeout=10).read())
            self.assertTrue(body["minutes"].startswith("## Summary"))
            missing = urllib.request.Request(req.full_url.replace("/1/", "/9/"), data=b"{}", method="POST",
                                             headers=req.headers)
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(missing, timeout=10)
            self.assertEqual(caught.exception.code, 404)
        finally:
            server.shutdown()

    def test_the_founder_gets_the_summary_and_action_items_when_it_ends(self):
        _, mode, _ = self.mode_with_minutes(self.MINUTES)
        startup = running(mode)
        text = mode.run_round(startup["id"])
        self.assertIn("meeting 1 is over", text)
        self.assertIn("✅ *Action items*", text)
        self.assertIn("**Zoe**: book 3 pilots — ETA: Friday", text)

    def test_deleting_a_startup_deletes_its_minutes(self):
        _, mode, _ = self.mode_with_minutes(self.MINUTES)
        startup = running(mode)
        mode.run_round(startup["id"])
        mode.delete(startup["id"])
        self.assertEqual(mode.store.all_minutes(startup["id"]), {})


class LeadershipTests(unittest.TestCase):
    def test_c_level_agents_follow_their_playbooks(self):
        from agentim import skills as skill_lib
        llm = TeamLLM()
        gateway, mode = make_startup_mode(llm=llm)
        gateway.skills = skill_lib.load_dir(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "skills"))
        startup = running(mode)
        leaders = [person_dict(p) for p in TEAM if p.title in ("CRO", "CFO", "COO", "CISO")]
        mode.set_team(startup["id"], leaders)
        mode.run_round(startup["id"])
        for first, marker in (("Zoe", "Your playbook as CRO"), ("Grace", "Your playbook as CFO"),
                              ("Marcus", "Your playbook as COO"), ("Dana", "Your playbook as CISO")):
            prompt = next(p for p in llm.prompts if p.startswith(f"You are {first} "))
            self.assertIn(marker, prompt)

    def test_presets_include_the_c_suite(self):
        titles = {p["title"] for p in ROLE_PRESETS}
        self.assertTrue({"CTO", "CPO", "CMO", "CRO", "CISO", "CFO", "COO", "CHRO", "CDO", "CCO", "CLO", "CAIO"} <= titles)

    def test_every_c_level_title_has_a_playbook(self):
        from agentim.startup import playbook_slug
        for title, slug in (("CHRO", "chro"), ("Chief People Officer", "chro"), ("CDO", "cdo"), ("CCO", "cco"),
                            ("General Counsel", "clo"), ("CAIO", "caio"), ("Chief AI Officer", "caio")):
            self.assertEqual(playbook_slug(title), slug, title)


class IdeasTests(unittest.TestCase):
    SOURCES = [{"type": "dir", "path": "/Users/me/code/orders-service"}, {"type": "github", "repo": "acme/web"},
               {"type": "github", "repo": "acme/web"}, {"type": "bogus"}]

    def mode_with_code(self):
        llm = TeamLLM()
        gateway, mode = make_startup_mode(llm=llm)
        calls = []

        def call(path, body=None, timeout=30):
            calls.append((path, body))
            if path == "/v1/projects/context":
                return {"context": "## orders-service\nStack files: package.json\nsrc/api/orders.ts", "folders": []}
            return {"folder": "/x", "mode": body["mode"], "output": f"Plan for {body['source']}", "changed": " a.ts | 3 +"}

        gateway.claude.call = call
        return gateway, mode, llm, calls

    def test_ideas_skip_the_interview_and_need_code(self):
        _, mode, _, _ = self.mode_with_code()
        idea = mode.create("Add refunds across the order and web services", kind="idea", sources=self.SOURCES)
        self.assertEqual((idea["kind"], idea["status"], idea["questions"]), ("idea", "running", []))
        self.assertEqual(idea["sources"], self.SOURCES[:2], "deduped and cleaned")
        self.assertIsNotNone(idea["next_run"])
        with self.assertRaisesRegex(ValueError, "Pick at least one folder"):
            mode.create("Add refunds across services", kind="idea", sources=[])
        startup = mode.create(PITCH, sources=[{"type": "github", "repo": "acme/web"}])
        self.assertEqual(startup["status"], "interview", "startups still get the interview")
        self.assertEqual(mode.summary(startup)["sources"], [{"type": "github", "repo": "acme/web"}])

    def test_meetings_see_the_code(self):
        _, mode, llm, calls = self.mode_with_code()
        idea = mode.create("Add refunds across the order and web services", kind="idea", sources=self.SOURCES[:1])
        mode.run_round(idea["id"])
        prompt = next(p for p in llm.prompts if p.startswith("You are ") and ' at "' in p)
        self.assertIn("The feature to add", prompt)
        self.assertIn("src/api/orders.ts", prompt, "the codebase brief reaches the agents")
        self.assertEqual(calls[0][0], "/v1/projects/context")

    def test_plan_then_build_with_confirmation(self):
        _, mode, _, calls = self.mode_with_code()
        idea = mode.create("Add refunds across the order and web services", kind="idea", sources=self.SOURCES[:2])
        mode.work_on_code(idea["id"], "plan")
        tasks = [body for path, body in calls if path == "/v1/projects/task"]
        self.assertEqual([t["mode"] for t in tasks], ["read", "read"], "one read-only plan per project")
        self.assertIn("without changing any files", tasks[0]["prompt"])
        coder = [m for m in mode.store.messages(idea["id"]) if m["role"] == "claude-code"]
        self.assertEqual(len(coder), 2)
        self.assertTrue(coder[0]["content"].startswith("**orders-service**: plan"))
        self.assertTrue(any(m["role"] == "ceo" for m in mode.store.messages(idea["id"])), "then the team meets")
        with self.assertRaisesRegex(ValueError, "confirm it first"):
            mode.work_on_code(idea["id"], "build")
        calls.clear()
        mode.work_on_code(idea["id"], "build", confirmed=True)
        builds = [body for path, body in calls if path == "/v1/projects/task"]
        self.assertTrue(all(b["mode"] == "edit" and b["confirmed"] for b in builds))
        last = [m for m in mode.store.messages(idea["id"]) if m["role"] == "claude-code"][-1]
        self.assertIn("Changed:", last["content"])

    def test_api(self):
        gateway, mode, _, _ = self.mode_with_code()
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(gateway, {}, lambda: [QWEN]))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}/v1/startups"

        def post(path, body):
            req = urllib.request.Request(base + path, data=json.dumps(body).encode(), method="POST",
                                         headers={"Authorization": "Bearer tok", "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=10) as resp:
                    return resp.status, json.loads(resp.read())
            except urllib.error.HTTPError as e:
                return e.code, json.loads(e.read())

        try:
            status, idea = post("", {"pitch": "Add refunds across the order and web services", "kind": "idea",
                                     "sources": self.SOURCES[:1]})
            self.assertEqual((status, idea["kind"]), (201, "idea"))
            self.assertEqual(post(f"/{idea['id']}/build", {})[0], 400, "build needs confirmed: true")
            self.assertEqual(post(f"/{idea['id']}/plan", {})[0], 202)
        finally:
            server.shutdown()


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
        self.assertIn(f"has {len(TEAM)} people", say("/startup fire 1 Omar"), "one hired, one fired")
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
