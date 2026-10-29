import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from agentim.launch import live_url_from, normalize_config, status_line, wait_for  # noqa: E402
from test_startup import PITCH, make_startup_mode  # noqa: E402
from test_team import TeamLLM  # noqa: E402


class LaunchTests(unittest.TestCase):
    def setUp(self):
        self.gateway, self.mode = make_startup_mode(llm=TeamLLM())
        self.calls, self.exit_codes = [], []

        def call(path, body=None, timeout=30):
            self.calls.append((path, body))
            if path == "/v1/projects/create":
                return {"folder": "/repos/startups/leafy"}
            if path == "/v1/projects/context":
                return {"context": "", "folders": []}
            if path == "/v1/projects/task":
                if body["mode"] == "edit":
                    return {"folder": "/f", "mode": "edit", "output": "Built it.\nTEST_COMMAND: `npm test`",
                            "changed": " index.html | 40 +"}
                return {"folder": "/f", "mode": "read", "output": "Design: one landing page and a signup form."}
            if path == "/v1/projects/run":
                code = self.exit_codes.pop(0) if self.exit_codes else 0
                out = "Production: https://leafy.vercel.app [2s]" if "vercel" in body["command"] else "3 passed"
                return {"folder": "/f", "exit_code": code, "output": out if code == 0 else "1 failed", "seconds": 2}
            if path == "/v1/projects/check":
                return {"ok": True, "status": 200, "ms": 120}
            if path == "/v1/projects/commit":
                self.version = f"v0.{getattr(self, 'version_n', 0) + 1}.0"
                self.version_n = getattr(self, "version_n", 0) + 1
                return {"committed": True, "version": self.version, "sha": "abc1234", "files": 7}
            if path == "/v1/projects/push":
                return {"pushed": True}
            if path == "/v1/projects/github":
                return {"url": "https://github.com/me/" + body["name"], "private": body["private"]}
            if path == "/v1/projects/history":
                return {"commits": [{"sha": "abc1234", "subject": "feat: build v1", "ts": 1, "version": "v0.1.0"}],
                        "version": "v0.1.0", "remote": ""}
            raise AssertionError(path)

        self.gateway.claude.call = call
        self.startup = self.mode.create(PITCH)
        self.mode.skip_questions(self.startup["id"])
        self.id = self.startup["id"]
        self.launch = self.mode.launch

    def run_stage(self, stage, confirmed=False):
        self.launch.start(self.id, stage, confirmed=confirmed)
        wait_for(self.launch, self.id)
        return {s["stage"]: s for s in self.mode.detail(self.id)["pipeline"]}

    def test_config_is_validated(self):
        config = self.launch.configure(self.id, {"stack": " Next.js + SQLite ", "deploy": "vercel", "bogus": 1})
        self.assertEqual((config["stack"], config["deploy"], config["folder"]), ("Next.js + SQLite", "vercel", ""))
        with self.assertRaisesRegex(ValueError, "Deploy to one of"):
            self.launch.configure(self.id, {"deploy": "mars"})
        with self.assertRaisesRegex(ValueError, "https"):
            self.launch.configure(self.id, {"live_url": "leafy.com"})
        self.assertEqual(normalize_config({}, {"team_reviews": 0})["team_reviews"], False)

    def test_design_to_live(self):
        self.launch.configure(self.id, {"deploy": "vercel", "team_reviews": False})
        stages = self.run_stage("design")
        self.assertEqual((stages["design"]["status"], stages["build"]["status"]), ("done", "waiting"))
        self.assertEqual(self.calls[0][0], "/v1/projects/create", "a startup without code gets its own folder")
        design_task = next(b for p, b in self.calls if p == "/v1/projects/task")
        self.assertEqual(design_task["mode"], "read", "the design never changes files")

        with self.assertRaisesRegex(ValueError, "confirm"):
            self.launch.start(self.id, "build")
        stages = self.run_stage("build", confirmed=True)
        self.assertEqual((stages["build"]["status"], stages["test"]["status"], stages["deploy"]["status"]),
                         ("done", "done", "waiting"))
        detail = self.mode.detail(self.id)
        self.assertEqual(detail["config"]["test_command"], "npm test", "the build reports how to test it")
        build = [b for p, b in self.calls if p == "/v1/projects/task"][-1]
        self.assertEqual((build["mode"], build["confirmed"]), ("edit", True))
        self.assertIn("one landing page", build["prompt"], "the build follows the design")

        stages = self.run_stage("deploy", confirmed=True)
        self.assertEqual((stages["deploy"]["status"], stages["live"]["status"]), ("done", "done"))
        self.assertEqual(self.mode.detail(self.id)["config"]["live_url"], "https://leafy.vercel.app")
        self.assertEqual(self.mode.summary(self.mode.store.get(self.id))["launch_stage"], "live")
        room = "\n".join(m["content"] for m in self.mode.detail(self.id)["messages"])
        for text in ("Design", "Built", "npm test` passed", "Deployed", "is **live**"):
            self.assertIn(text, room)
        self.assertIn("deploy done", status_line(self.mode.store.get(self.id)),
                      "the team brief knows where the launch stands")

    def test_launch_mode_runs_everyone_in_parallel_then_builds(self):
        import threading
        import time as t
        active, peak = [0], [0]
        lock = threading.Lock()
        original = self.mode._ask

        def slow_ask(prompt, label=""):
            if "LAUNCH MODE" in prompt:
                with lock:
                    active[0] += 1
                    peak[0] = max(peak[0], active[0])
                t.sleep(0.05)
                with lock:
                    active[0] -= 1
                return f"**Deliverable** for {label}"
            return original(prompt, label)

        self.mode._ask = slow_ask
        with self.assertRaisesRegex(ValueError, "confirm"):
            self.launch.start_sprint(self.id)
        self.launch.start_sprint(self.id, confirmed=True)
        wait_for(self.launch, self.id, timeout=10)
        detail = self.mode.detail(self.id)
        team = detail["team"]
        self.assertGreater(peak[0], 1, "the employees work at the same time")
        self.assertEqual(detail["sprint"]["status"], "done")
        stages = {s["stage"]: s["status"] for s in detail["pipeline"]}
        self.assertEqual((stages["design"], stages["build"], stages["deploy"]), ("done", "done", "waiting"),
                         "designed and built; deploying waits for the founder")
        build = [b for p, b in self.calls if p == "/v1/projects/task" and b["mode"] == "edit"][0]
        self.assertIn("launch kit", build["prompt"])
        self.assertIn("launch/", build["prompt"], "the marketing assets are saved in the project")
        room = "\n".join(m["content"] for m in detail["messages"])
        self.assertEqual(room.count("**Deliverable**"), len(team), "every employee delivered")
        self.assertIn("Launch mode done", room)
        self.assertFalse(any(p == "/v1/projects/run" and "vercel" in b["command"] for p, b in self.calls),
                         "never deploys on its own")

    def test_every_build_is_a_version_and_github_is_suggested(self):
        self.run_stage("build", confirmed=True)
        commit = next(b for p, b in self.calls if p == "/v1/projects/commit")
        self.assertEqual(commit["message"], f"feat: build v1 of {self.startup['name']}")
        self.assertIn("Tests: `npm test` done", commit["body"])
        detail = self.mode.detail(self.id)
        self.assertEqual(detail["config"]["version"], "v0.1.0")
        room = "\n".join(m["content"] for m in detail["messages"])
        self.assertIn("**v0.1.0** committed", room)
        self.assertIn("Create GitHub repo", room, "the first version suggests a repo")
        self.assertFalse(any(p == "/v1/projects/github" for p, _ in self.calls), "never creates one by itself")

        self.run_stage("build", confirmed=True)
        commits = [b for p, b in self.calls if p == "/v1/projects/commit"]
        self.assertEqual(commits[-1]["message"], f"feat: update {self.startup['name']}")
        self.assertEqual(self.mode.detail(self.id)["config"]["version"], "v0.2.0")
        self.assertEqual(room.count("Create GitHub repo"), 1)

        with self.assertRaisesRegex(ValueError, "confirmation"):
            self.launch.create_github(self.id, "leafy")
        config = self.launch.create_github(self.id, "leafy", auto_push=True, confirmed=True)
        self.assertEqual((config["github_repo"], config["auto_push"]), ("https://github.com/me/leafy", True))
        github = next(b for p, b in self.calls if p == "/v1/projects/github")
        self.assertTrue(github["private"], "private by default")
        self.run_stage("build", confirmed=True)
        self.assertTrue(any(p == "/v1/projects/push" for p, _ in self.calls), "auto-push after the founder turned it on")
        self.assertEqual(self.launch.versions(self.id)["version"], "v0.1.0")

    def test_no_versioning_in_your_own_folder_unless_asked(self):
        self.launch.configure(self.id, {"folder": "/Users/me/code/leafy"})
        self.run_stage("build", confirmed=True)
        self.assertFalse(any(p == "/v1/projects/commit" for p, _ in self.calls), "never commits your own WIP by default")
        self.launch.configure(self.id, {"versioning": "on"})
        self.run_stage("build", confirmed=True)
        self.assertTrue(any(p == "/v1/projects/commit" for p, _ in self.calls))
        with self.assertRaisesRegex(ValueError, "auto, on or off"):
            self.launch.configure(self.id, {"versioning": "sometimes"})

    def test_failing_tests_get_one_fix(self):
        self.exit_codes = [1, 0]
        stages = self.run_stage("build", confirmed=True)
        self.assertEqual(stages["test"]["status"], "done")
        tasks = [b for p, b in self.calls if p == "/v1/projects/task"]
        self.assertIn("fails with", tasks[-1]["prompt"])
        self.assertIn("Don't weaken", tasks[-1]["prompt"])

        self.exit_codes = [1, 1]
        stages = self.run_stage("build", confirmed=True)
        self.assertEqual((stages["test"]["status"], stages["deploy"]["status"]), ("failed", "waiting"),
                         "deploy stays waiting from before; nothing new is unlocked")

    def test_deploy_needs_a_target_and_confirmation(self):
        with self.assertRaisesRegex(ValueError, "confirm"):
            self.launch.start(self.id, "deploy")
        with self.assertRaisesRegex(ValueError, "Choose where to deploy"):
            self.launch.start(self.id, "deploy", confirmed=True)
        with self.assertRaisesRegex(ValueError, "no live URL"):
            self.launch.start(self.id, "live")
        self.launch.configure(self.id, {"deploy": "custom", "deploy_command": "./deploy.sh"})
        self.exit_codes = [2]
        stages = self.run_stage("deploy", confirmed=True)
        self.assertEqual(stages["deploy"]["status"], "failed")
        self.assertIn("exited with 2", stages["deploy"]["output"])

    def test_a_meeting_never_overwrites_launch_progress(self):
        stale = self.mode.store.get(self.id)
        self.launch.configure(self.id, {"stack": "Rails"})
        stale["plan"] = "new plan"
        self.mode.store.save(stale)
        fresh = self.mode.store.get(self.id)
        self.assertEqual((fresh["plan"], fresh["config"]["stack"]), ("new plan", "Rails"))

    def test_live_url_from_deploy_output(self):
        self.assertEqual(live_url_from("Inspect: https://vercel.com/acme/leafy/inspect/x\n"
                                       "Production: https://leafy.vercel.app [3s]"), "https://leafy.vercel.app")
        self.assertEqual(live_url_from("Website URL: https://leafy.netlify.app."), "https://leafy.netlify.app")
        self.assertEqual(live_url_from("done"), "")


class ActionItemTests(unittest.TestCase):
    MINUTES = ("## Summary\nWe picked landlords.\n## Decisions\n- Landlords first\n## Action items\n"
               "- **Zoe**: book 3 paid pilots (by Friday)\n- **Leo**: ROI page — ETA: Thu, Oct 29\n- set up analytics\n"
               "## Metrics\n- None mentioned")

    def test_every_action_item_has_an_owner_and_an_eta(self):
        from agentim.startup import parse_action_items, with_owners_and_etas
        items = parse_action_items(with_owners_and_etas(self.MINUTES, ["Zoe", "Leo"], 1_800_000_000))
        self.assertEqual([(i["owner"], i["eta"] != "") for i in items], [("Zoe", True), ("Leo", True), ("Tim", True)])
        self.assertEqual(items[0]["eta"], "Friday")
        self.assertFalse(items[1]["proposed"])
        self.assertTrue(items[2]["proposed"], "an ETA nobody said is marked proposed")

    def test_meetings_without_action_items_get_them(self):
        from agentim.startup import parse_action_items, with_owners_and_etas
        none = "## Summary\nChat.\n## Action items\n- None\n## Metrics\n- None"
        self.assertEqual([i["owner"] for i in parse_action_items(with_owners_and_etas(none, ["Zoe", "Ava"], 0))],
                         ["Zoe", "Ava"])
        missing = with_owners_and_etas("## Summary\nChat.", [], 0)
        self.assertEqual(parse_action_items(missing)[0]["owner"], "Tim")

    def test_meeting_notes_list_action_items(self):
        gateway, mode = make_startup_mode(llm=TeamLLM())
        startup = mode.create(PITCH)
        mode.skip_questions(startup["id"])
        mode.run_round(startup["id"])
        notes = mode.meeting(startup["id"], 1)
        self.assertTrue(notes["action_items"])
        self.assertTrue(all(i["owner"] and i["eta"] for i in notes["action_items"]))


class InterviewAutocompleteTests(unittest.TestCase):
    class AnswerLLM(TeamLLM):
        def complete(self, model, system, messages, *args, **kwargs):
            prompt = messages[-1]["content"]
            if "fill in a startup interview" in prompt:
                self.interview_prompt = prompt
                import re
                numbers = re.findall(r"^(\d+)\. ", prompt, re.MULTILINE)
                return "\n".join(f"{n}. AI answer {n}" for n in numbers)
            return super().complete(model, system, messages, *args, **kwargs)

    def test_ai_suggests_one_answer_or_completes_the_rest(self):
        llm = self.AnswerLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = mode.create(PITCH)
        n = len(startup["questions"])
        self.assertEqual(mode.suggest_answers(startup["id"], [2]), {2: "AI answer 3"})

        done = mode.autocomplete(startup["id"], ["Office managers at 50+ person companies"])
        self.assertEqual(done["status"], "running", "the team starts")
        self.assertEqual(done["answers"][0], "Office managers at 50+ person companies", "the founder's answer stays")
        self.assertEqual(len(done["answers"]), n)
        self.assertTrue(all(a.endswith("(suggested by AI)") for a in done["answers"][1:]))
        self.assertIn("Office managers", llm.interview_prompt, "the AI builds on what the founder said")

    def test_no_model_is_a_clear_error(self):
        _, mode = make_startup_mode(llm=TeamLLM())
        startup = mode.create(PITCH)
        mode._ask = lambda *a, **k: None
        with self.assertRaisesRegex(ValueError, "No model"):
            mode.autocomplete(startup["id"])


class TimelineTests(unittest.TestCase):
    def test_etas_are_times_or_dependencies(self):
        import time as t
        from agentim.startup import eta_due, open_items_text, parse_action_items
        base = t.mktime((2026, 10, 29, 14, 0, 0, 0, 0, -1))
        self.assertEqual(eta_due("in 45 min", base), (base + 45 * 60, None))
        self.assertEqual(eta_due("in 2 h", base), (base + 7200, None))
        self.assertEqual(eta_due("by 15:30", base), (base + 90 * 60, None))
        self.assertEqual(eta_due("right after Leo's ROI page", base), (None, "Leo's ROI page"))
        minutes = ("## Action items\n- **Zoe**: book 3 pilots — ETA: in 30 min\n"
                   "- **Sam**: wire the email sequence — ETA: after Leo's ROI page\n## Metrics\n- None")
        items = parse_action_items(minutes, base)
        self.assertEqual([(i["due"], i["after"]) for i in items], [(base + 1800, None), (None, "Leo's ROI page")])
        text = open_items_text(items, base + 40 * 60)
        self.assertIn("Zoe: book 3 pilots (due 14:30, OVERDUE by 10 min)", text)
        self.assertIn("Sam: wire the email sequence (after Leo's ROI page)", text)

    def test_meetings_plan_in_minutes_and_review_open_items(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = mode.create(PITCH)
        mode.skip_questions(startup["id"])
        mode.run_round(startup["id"])
        mode.store.save_minutes(startup["id"], 1, "## Action items\n- **Zoe**: book 3 pilots — ETA: in 30 min\n")
        llm.prompts.clear()
        mode.run_round(startup["id"])
        update = next(p for p in llm.prompts if "Post your update" in p)
        self.assertIn("never days", update)
        self.assertIn("Open action items", update)
        self.assertIn("Zoe: book 3 pilots (due", update)
        self.assertTrue(any("never days" in p for p in llm.prompts if p.startswith("You are the note-taker")))


class OneOnOneTests(unittest.TestCase):
    def test_chat_with_one_employee_privately(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = mode.create(PITCH)
        mode.skip_questions(startup["id"])
        key = mode.detail(startup["id"])["team"][0]["key"]
        sent = mode.send_dm(startup["id"], key, "Can you price the pilot?")
        self.assertEqual(sent["messages"][0]["content"], "Can you price the pilot?")
        import time as t
        end = t.time() + 5
        while (startup["id"], key) in mode.dm_typing and t.time() < end:
            t.sleep(0.01)
        chat = mode.dm(startup["id"], key)
        self.assertEqual([m["role"] for m in chat["messages"]], ["founder", key])
        self.assertFalse(chat["typing"])
        self.assertTrue(any("private 1:1 chat" in p for p in llm.prompts))
        self.assertEqual(mode.store.messages(startup["id"]), [], "the agents room doesn't see it")

        llm.prompts.clear()
        mode.speakers_per_round = len(mode.detail(startup["id"])["team"])
        mode.run_round(startup["id"])
        self.assertTrue(any("Your private chat with the founder" in p and "price the pilot" in p for p in llm.prompts),
                        "the employee brings the 1:1 into the next meeting")
        with self.assertRaisesRegex(ValueError, "Pick someone"):
            mode.send_dm(startup["id"], "nobody", "hi")
        self.assertEqual(mode.dm(startup["id"], "ceo")["person"]["name"], "Agent Tim", "you can DM the CEO too")


class GroupChatTests(unittest.TestCase):
    def wait(self, mode, key, sid):
        import time as t
        end = t.time() + 5
        while (sid, key) in mode.dm_typing and t.time() < end:
            t.sleep(0.01)

    def test_groups_and_the_conversation_list(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        startup = mode.create(PITCH)
        sid = startup["id"]
        mode.skip_questions(sid)
        team = mode.detail(sid)["team"]
        a, b, c = team[0], team[1], team[2]
        with self.assertRaisesRegex(ValueError, "at least two"):
            mode.create_group(sid, [a["key"]])
        group = mode.create_group(sid, [a["key"], b["key"], "nobody"])
        self.assertEqual(group["members"], [a["key"], b["key"]])
        self.assertEqual(group["name"], f"{a['name'].split()[0]}, {b['name'].split()[0]}")
        key = f"group-{group['id']}"

        mode.send_dm(sid, key, "What should we launch first?")
        self.wait(mode, key, sid)
        roles = [m["role"] for m in mode.dm(sid, key)["messages"]]
        self.assertEqual(roles, ["founder", a["key"], b["key"]], "everyone in the group answers in turn")
        self.assertTrue(any(f'group chat called "{group["name"]}"' in p for p in llm.prompts))

        first = a["name"].split()[0]
        mode.send_dm(sid, key, f"@{first} just you: the pricing?")
        self.wait(mode, key, sid)
        roles = [m["role"] for m in mode.dm(sid, key)["messages"]]
        self.assertEqual(roles[-2:], ["founder", a["key"]], "a tag asks only that person")

        threads = mode.threads(sid)["threads"]
        self.assertEqual(threads[0]["key"], "room")
        listed = {t["key"]: t for t in threads}
        self.assertEqual(listed[key]["last"]["role"], a["key"])
        self.assertIn(c["key"], listed)
        self.assertIn("ceo", listed, "Agent Tim has a thread too")
        self.assertIsNone(listed[c["key"]]["last"])
        self.assertIn(group["name"], mode.private_notes(sid, mode.chat_person(mode.store.get(sid), a["key"])),
                      "members bring the group chat into meetings")

        mode.delete_group(sid, group["id"])
        self.assertNotIn(key, {t["key"] for t in mode.threads(sid)["threads"]})


class DailyMeetingTests(unittest.TestCase):
    def test_rounds_fold_into_one_daily_meeting_with_one_summary(self):
        llm = TeamLLM()
        _, mode = make_startup_mode(llm=llm)
        sent = []
        mode.notify = lambda channel, chat, text: sent.append(text)
        mode.daily_hour = 24  # not yet: the meetings themselves don't send today's summary
        startup = mode.create(PITCH, channel="telegram", chat_id="42")
        sid = startup["id"]
        mode.skip_questions(sid)
        mode.run_round(sid)
        mode.run_round(sid)
        days = mode.days(sid)
        self.assertEqual(len(days), 1, "one rolling meeting for the day")
        self.assertEqual(days[0]["rounds"], [1, 2])
        self.assertIn("## Summary", days[0]["minutes"])
        self.assertTrue(all(i["owner"] and i["eta"] for i in days[0]["action_items"]))
        self.assertEqual(mode.detail(sid)["today"]["rounds"], [1, 2])
        full = mode.day(sid, days[0]["day"])
        self.assertEqual({m["round"] for m in full["messages"]}, {1, 2}, "the whole day's conversation")

        # One message a day, not one per meeting: nothing before the summary hour, then once.
        self.assertEqual(mode.send_daily(mode.store.get(sid), hour=24), [])
        self.assertEqual(mode.send_daily(mode.store.get(sid), hour=0), [days[0]["day"]])
        self.assertEqual(mode.send_daily(mode.store.get(sid), hour=0), [], "sent once")
        self.assertIn("meeting (2 rounds)", sent[-1])
        mode.notify_mode = "meeting"
        before = len(sent)
        mode.run_round(sid)
        self.assertEqual(len(sent), before + 1, "AGENTIM_STARTUP_NOTIFY=meeting: after every meeting")

    def test_merge_without_a_model(self):
        from agentim.startup import merge_minutes
        merged = merge_minutes(["## Summary\nMorning.\n## Action items\n- **Zoe**: pilots — ETA: in 1 h\n",
                                "## Summary\nAfternoon.\n## Action items\n- **Zoe**: pilots — ETA: in 1 h\n"
                                "- **Leo**: ROI page — ETA: in 2 h\n"])
        self.assertIn("Afternoon.", merged)
        self.assertNotIn("Morning.", merged)
        self.assertEqual(merged.count("**Zoe**"), 1, "duplicates merged")


class ClaudeAndChatGPTTests(unittest.TestCase):
    def test_local_claude_code_then_codex_answer_when_no_model_is_up(self):
        from agentim.router import CLOUD_MODELS, Router, model_from_runner
        url = "http://host.docker.internal:8766"
        agents = [model_from_runner({"id": "local/codex", "kind": "agent"}, url),
                  model_from_runner({"id": "local/claude-code", "kind": "agent"}, url)]
        decision = Router(agents).route("Write a tagline for my bakery")
        self.assertEqual([decision.model.id, decision.fallbacks[0].id], ["local/claude-code", "local/codex"])
        self.assertIn("no local model is running", decision.reason)
        cloud = Router(CLOUD_MODELS["anthropic"] + CLOUD_MODELS["openai"] + agents).route("Plan our pricing strategy step by step")
        self.assertFalse(cloud.model.id.startswith("local/"), "with Claude/ChatGPT keys, the API models answer")
        self.assertIn("opus", {m.alias for m in CLOUD_MODELS["anthropic"]})
        self.assertIn("gpt5", {m.alias for m in CLOUD_MODELS["openai"]})


class EventWorkTests(unittest.TestCase):
    def setUp(self):
        self.gateway, self.mode = make_startup_mode(llm=TeamLLM())
        startup = self.mode.create(PITCH)
        self.sid = startup["id"]
        self.mode.skip_questions(self.sid)
        team = self.mode.detail(self.sid)["team"]
        self.first = {p["key"]: p["name"].split()[0] for p in team}
        self.keys = [p["key"] for p in team]
        self.prompts = []
        original = self.mode._ask

        def ask(prompt, label=""):
            if "YOUR TASK" not in prompt:
                return original(prompt, label)
            self.prompts.append(prompt)
            me = prompt.split("You are ")[1].split(",")[0].split()[0]
            nxt = self.first[self.keys[1]] if me == self.first[self.keys[0]] else None
            return (f"**Result** by {me}\nThe ROI page copy." +
                    (f"\nHANDOFF: @{nxt}: put the ROI page in the welcome email — ETA: in 20 min" if nxt and "HANDOFF:" in prompt
                     else "\nHANDOFF: none"))

        self.mode._ask = ask

    def wait(self):
        import time as t
        end = t.time() + 5
        while self.sid in self.mode.work.running and t.time() < end:
            t.sleep(0.01)

    def test_an_agent_finishes_and_hands_off_to_the_next(self):
        a, b = self.keys[0], self.keys[1]
        self.mode.work.assign(self.sid, self.first[a], "Write the ROI page")
        self.wait()
        board = self.mode.work.board(self.sid)["tasks"]
        self.assertEqual([(t["owner"], t["status"], t["from_role"]) for t in board],
                         [(a, "done", "founder"), (b, "done", a)], "the handoff started the next agent right away")
        self.assertIn("The ROI page copy", board[1]["input"], "the next agent gets the result as input")
        self.assertIn("Input from", self.prompts[1])
        self.assertIn("Never invent traction", self.prompts[0])
        room = "\n".join(m["content"] for m in self.mode.store.messages(self.sid))
        self.assertIn("➡️ Handed off to @" + self.first[b], room)
        self.assertNotIn("HANDOFF:", room)
        self.assertIsNotNone(self.mode.store.get(self.sid)["next_run"], "board empty: the team meets after a break")

    def test_meeting_action_items_become_tasks_with_dependencies(self):
        a, b = self.keys[0], self.keys[1]
        minutes = (f"## Action items\n- **{self.first[a]}**: ROI page — ETA: in 30 min\n"
                   f"- **{self.first[b]}**: email sequence — ETA: after {self.first[a]}'s ROI page\n")
        self.mode.work.max_depth = 0  # no handoffs in this test
        created = self.mode.work.seed(self.sid, 1, __import__("agentim.startup").startup.parse_action_items(minutes, 0))
        self.assertEqual(created[1]["depends_on"], created[0]["id"])
        board = {t["owner"]: t for t in self.mode.work.board(self.sid)["tasks"]}
        self.assertTrue(board[a]["ready"])
        self.assertFalse(board[b]["ready"], "waits for the ROI page")
        self.mode.work.kick(self.sid)
        self.wait()
        self.assertEqual([t["status"] for t in self.mode.work.board(self.sid)["tasks"]], ["done", "done"],
                         "the second started as soon as the first finished")
        self.assertEqual(len(self.mode.work.seed(self.sid, 1, [])), 0)

    def test_budgets_and_pausing_stop_the_chain(self):
        self.mode.work.max_per_day = 1
        self.mode.work.assign(self.sid, self.first[self.keys[0]], "Write the ROI page")
        self.wait()
        statuses = [t["status"] for t in self.mode.work.board(self.sid)["tasks"]]
        self.assertEqual(statuses, ["done", "todo"], "over the daily budget: the handoff waits")
        self.mode.work.max_per_day = 40
        self.mode.set_enabled(self.sid, False)
        self.mode.work.kick(self.sid)
        self.wait()
        self.assertEqual([t["status"] for t in self.mode.work.board(self.sid)["tasks"]], ["done", "todo"], "paused")
        with self.assertRaisesRegex(ValueError, "Pick someone"):
            self.mode.work.assign(self.sid, "nobody", "x")

    def test_timer_rhythm_keeps_the_old_schedule(self):
        self.mode.set_rhythm(self.sid, "timer")
        self.assertEqual(self.mode.detail(self.sid)["rhythm"], "timer")
        self.assertEqual(self.mode.begin_work(self.sid, 1, "## Action items\n- **X**: y\n"), [])
        with self.assertRaisesRegex(ValueError, "events or timer"):
            self.mode.set_rhythm(self.sid, "sometimes")

    def test_parse_handoffs(self):
        from agentim.work import parse_handoffs
        text, handoffs = parse_handoffs("Done it.\nHANDOFF: @Sam: wire the emails — ETA: in 20 min\n**HANDOFF:** none")
        self.assertEqual(text, "Done it.")
        self.assertEqual(handoffs, [("Sam", "wire the emails", "in 20 min")])


if __name__ == "__main__":
    unittest.main()
