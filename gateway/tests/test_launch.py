import json
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

        def slow_ask(prompt, label="", **kw):
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
    def test_no_daily_meeting_or_daily_message(self):
        _, mode = make_startup_mode(llm=TeamLLM())
        sent = []
        mode.notify = lambda channel, chat, text: sent.append(text)
        startup = mode.create(PITCH, channel="telegram", chat_id="42")
        mode.skip_questions(startup["id"])
        mode.run_round(startup["id"])
        self.assertEqual(mode.days(startup["id"]), [], "nothing is grouped by day")
        self.assertEqual(sent, [], "no message per meeting or per day: Tim sends summaries every N minutes")

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

        def ask(prompt, label="", **kw):
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
        self.mode.work.max_per_window = 1
        self.mode.work.assign(self.sid, self.first[self.keys[0]], "Write the ROI page")
        self.wait()
        statuses = [t["status"] for t in self.mode.work.board(self.sid)["tasks"]]
        self.assertEqual(statuses, ["done", "todo"], "over the daily budget: the handoff waits")
        self.mode.work.max_per_window = 40
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


class GraphTests(unittest.TestCase):
    def setUp(self):
        self.gateway, self.mode = make_startup_mode(llm=TeamLLM())
        self.mode.default_rhythm = "graph"
        startup = self.mode.create(PITCH)
        self.sid = startup["id"]
        self.mode.skip_questions(self.sid)
        self.mode.store.save({**self.mode.store.get(self.sid), "next_run": None})
        team = self.mode.detail(self.sid)["team"]
        self.first = [p["name"].split()[0] for p in team]
        self.keys = [p["key"] for p in team]
        self.calls, self.checks = [], []
        self.fail_first = set()

        def ask(prompt, label="", **kw):
            self.calls.append(label)
            if "Turn this goal into a work graph" in prompt:
                a, b, c = self.first[:3]
                return (f"T1 | {a} | Write the v1 scope | done when: lists 3 features | after: - | gate: review\n"
                        f"T2 | {b} | Draft the landing page copy | done when: has a headline | after: - | gate: auto\n"
                        f"T3 | {c} | Post the launch announcement on LinkedIn | done when: under 120 words | after: T1, T2 | gate: auto")
            if prompt.startswith("You are Agent Tim, CEO, checking"):
                task = prompt.split("Task: ")[1].split("\n")[0]
                self.checks.append(task)
                if task in self.fail_first:
                    self.fail_first.discard(task)
                    return "FAIL\nReason: only 2 features listed\nFix: add a third feature"
                return "PASS"
            if "YOUR TASK" in prompt:
                return "Result: feature A, feature B, feature C\nHANDOFF: none"
            if "asked for a summary" in prompt:
                return ("## Summary\nScope and copy are done.\n## Decisions\n- Price at $29/month\n"
                        "## Action items\n- **Ava**: post — ETA: in 30 min\n## Needs you\n- Approve the post\n## Open questions\n- None")
            return "ok"

        self.mode._ask = ask

    def wait(self):
        import time as t
        end = t.time() + 5
        while self.sid in self.mode.work.running and t.time() < end:
            t.sleep(0.01)

    def test_a_goal_becomes_a_graph_with_parallel_tasks_checks_and_a_founder_gate(self):
        self.fail_first.add("Write the v1 scope")
        created = self.mode.set_goal(self.sid, "Launch v1 this week")
        self.assertEqual(len(created), 3)
        self.assertEqual(created[2]["gate"], "founder", "posting publicly can't be undone: the founder approves")
        self.assertEqual(json.loads(created[2]["deps"]), [created[0]["id"], created[1]["id"]])
        self.wait()
        board = {t["task"]: t for t in self.mode.work.board(self.sid)["tasks"]}
        scope = board["Write the v1 scope"]
        self.assertEqual((scope["status"], scope["attempts"]), ("done", 1), "failed the check once, fixed, then passed")
        self.assertEqual(board["Draft the landing page copy"]["status"], "done")
        post = board["Post the launch announcement on LinkedIn"]
        self.assertEqual(post["status"], "approval", "waits for the founder")
        self.assertEqual(post["layer"], 1, "after the two parallel tasks")
        room = "\n".join(m["content"] for m in self.mode.store.messages(self.sid))
        for text in ("🗺️ **Plan**", "🔁 Not yet", "only 2 features listed", "checked ✓", "🙋 **Needs your approval**"):
            self.assertIn(text, room)
        self.mode.work.approve(self.sid, post["id"])
        self.wait()
        self.assertEqual(self.mode.work.store.get(post["id"])["status"], "done")
        self.assertIn("🏁 **Goal done**", "\n".join(m["content"] for m in self.mode.store.messages(self.sid)))

    def test_two_failed_checks_block_the_task_and_leave_a_lesson(self):
        orig = self.mode._ask
        self.mode._ask = lambda p, label="", **kw: ("FAIL\nReason: no numbers\nFix: add numbers"
                                              if p.startswith("You are Agent Tim, CEO, checking") else orig(p, label))
        created = self.mode.set_goal(self.sid, "Launch v1 this week")
        self.wait()
        scope = self.mode.work.store.get(created[0]["id"])
        self.assertEqual((scope["status"], scope["attempts"]), ("blocked", 3))
        lessons = [m for m in self.mode.memory.all(self.sid) if m["kind"] == "lesson"]
        self.assertTrue(any("no numbers" in l["text"] and l["role"] == self.keys[0] for l in lessons))
        self.assertIn("no numbers", self.mode.memory.brief(self.sid, self.keys[0]), "the owner sees the lesson next time")
        self.mode._ask = orig
        self.mode.work.retry(self.sid, scope["id"], "use our pricing: $29")
        self.wait()
        self.assertEqual(self.mode.work.store.get(scope["id"])["status"], "done")

    def test_memory_and_summary_on_demand(self):
        self.mode.memory.add(self.sid, "rule", "Never promise features we haven't built")
        self.assertIn("Never promise features", self.mode.memory.brief(self.sid))
        result = self.mode.work.summarize(self.sid)
        self.assertIn("## Summary", result["summary"])
        self.assertIn("Price at $29/month", [m["text"] for m in self.mode.memory.all(self.sid)], "decisions go into memory")
        self.assertEqual(self.mode.store.summaries(self.sid)[0]["at"], result["at"], "summaries are kept, by time")
        self.assertIn("📋 **Summary**", self.mode.store.messages(self.sid)[-1]["content"])

    def test_graph_mode_has_no_scheduled_meetings(self):
        self.assertEqual(self.mode.detail(self.sid)["rhythm"], "graph")
        self.mode.run_round(self.sid)  # what the scheduler or "Meet now" would do: plans the first goal instead
        self.wait()
        self.assertIsNone(self.mode.store.get(self.sid)["next_run"])
        self.assertEqual(self.mode.store.get(self.sid)["rounds"], 0, "no meeting rounds")
        self.assertTrue(self.mode.work.store.all(self.sid), "the first goal was planned")

    def test_tim_answers_and_new_goals_become_graphs(self):
        orig = self.mode._ask
        self.mode._ask = lambda p, label="", **kw: ("GOAL: Get 10 pilot customers\nOn it: Zoe leads, Ava supports."
                                              if "just wrote in the team room" in p else orig(p, label))
        self.mode.post_founder(self.sid, "let's focus on getting 10 pilot customers")
        import time as t
        end = t.time() + 5
        while "**Plan**: Get 10 pilot customers" not in "\n".join(m["content"] for m in self.mode.store.messages(self.sid)) \
                and t.time() < end:
            t.sleep(0.01)
        self.wait()
        room = "\n".join(m["content"] for m in self.mode.store.messages(self.sid))
        self.assertIn("On it: Zoe leads", room)
        self.assertIn("🗺️ **Plan**: Get 10 pilot customers", room)
        self.mode.post_founder(self.sid, "goal: Ship the pricing page")
        end = t.time() + 5
        while "**Plan**: Ship the pricing page" not in "\n".join(m["content"] for m in self.mode.store.messages(self.sid)) and t.time() < end:
            t.sleep(0.01)
        self.assertIn("🗺️ **Plan**: Ship the pricing page", "\n".join(m["content"] for m in self.mode.store.messages(self.sid)))

    def test_parse_plan_and_gates(self):
        from agentim.graph import gate_for, parse_plan
        nodes = parse_plan("T1 | Ava | Write copy | done when: 3 headlines | after: - | gate: auto\n"
                           "T2 | @Zoe | Email the customers the offer | done when: sent | after: T1 | gate: review\nnoise")
        self.assertEqual([(n["ref"], n["owner"], n["after"], n["gate"]) for n in nodes],
                         [("T1", "Ava", [], "auto"), ("T2", "Zoe", ["T1"], "founder")])
        self.assertEqual(gate_for("Deploy to production", "auto"), "founder")
        self.assertEqual(gate_for("Draft the FAQ", "auto"), "auto")
        self.assertEqual(gate_for("Draft a LinkedIn post", "auto"), "auto", "a draft can be redone")
        self.assertEqual(gate_for("Post the announcement on LinkedIn", "auto"), "founder")


class ProjectTests(unittest.TestCase):
    WORTH = ("VERDICT: buy\nWHY: Rover and Wag already do this well.\nEXISTING:\n- Rover: dog walkers, 20% fee\n"
             "- Wag: on-demand walks\nGAP: none\nRECOMMENDATION: Partner with Rover instead.")

    def setUp(self):
        self.gateway, self.mode = make_startup_mode(llm=TeamLLM())
        self.mode.default_rhythm = "graph"
        self.mode.auto_check = True
        self.labels, self.models = [], []
        self.verdict = self.WORTH
        orig = self.mode._ask

        def ask(prompt, label="", model=None, avoid=None):
            self.labels.append(label)
            self.models.append((label, model))
            if "check if it's worth building" in prompt:
                return self.verdict
            if "Turn this goal into a work graph" in prompt:
                return "T1 | Noah | Build the booking API | done when: tests pass | after: - | gate: code"
            if prompt.startswith("You are Agent Tim, CEO, checking"):
                return "PASS"
            if "on autopilot" in prompt:
                return "DONE: the booking flow works end to end"
            return orig(prompt, label)

        self.mode._ask = ask
        self.calls = []

        def call(path, body=None, timeout=30):
            self.calls.append((path, body))
            if path == "/v1/projects/create":
                return {"folder": "/repos/startups/walkies"}
            if path == "/v1/projects/task":
                return {"folder": "/f", "mode": body["mode"], "output": "Added POST /bookings and a test.",
                        "changed": " api.py | 30 +"}
            if path == "/v1/projects/run":
                return {"folder": "/f", "exit_code": 0, "output": "4 passed", "seconds": 1}
            if path == "/v1/projects/commit":
                return {"committed": True, "version": "v0.1.0", "sha": "abc1234", "files": 2}
            return {}

        self.gateway.claude.call = call

    def wait_check(self, sid):
        import time as t
        end = t.time() + 5
        while (sid in self.mode.checking or sid in self.mode.work.running) and t.time() < end:
            t.sleep(0.01)
        t.sleep(0.05)
        while sid in self.mode.work.running and t.time() < end:
            t.sleep(0.01)

    def test_worth_building_check_waits_for_the_founder_when_it_says_buy(self):
        project = self.mode.create("A booking app for dog walkers in my city", kind="project")
        sid = project["id"]
        self.mode.skip_questions(sid)
        self.wait_check(sid)
        config = self.mode.store.get(sid)["config"]
        self.assertEqual(config["check"]["verdict"], "buy")
        self.assertEqual([e["name"] for e in config["check"]["existing"]], ["Rover", "Wag"])
        self.assertNotIn("decision", config, "a 'buy' verdict waits for the founder")
        self.mode.run_round(sid)
        self.assertEqual(self.mode.work.store.all(sid), [], "no work before the founder decides")
        room = "\n".join(m["content"] for m in self.mode.store.messages(sid))
        self.assertIn("🔎 **Worth building?** 🛒", room)
        self.assertIn("**Rover**", room)
        self.mode.decide(sid, "build")
        self.wait_check(sid)
        self.assertTrue(self.mode.work.store.all(sid), "Build: the first goal is planned and worked")

    def test_a_build_verdict_starts_right_away_and_stop_pauses(self):
        self.verdict = "VERDICT: build\nWHY: Nothing local exists.\nEXISTING:\nGAP: local trust\nRECOMMENDATION: Build v1"
        project = self.mode.create("A booking app for dog walkers in my city", kind="project")
        self.wait_check(project["id"])
        self.assertEqual(self.mode.store.get(project["id"])["config"]["decision"], "build")
        other = self.mode.create("Another booking app for cat sitters in my city", kind="idea",
                                 sources=[{"type": "dir", "path": "/Users/me/code/app"}])
        self.wait_check(other["id"])
        self.mode.decide(other["id"], "stop")
        self.assertEqual(self.mode.store.get(other["id"])["status"], "paused")
        with self.assertRaisesRegex(ValueError, "Build or stop"):
            self.mode.decide(other["id"], "maybe")

    def test_code_tasks_plan_without_autopilot_and_build_with_it(self):
        self.verdict = "VERDICT: build\nWHY: ok\nEXISTING:\nGAP: x\nRECOMMENDATION: go"
        project = self.mode.create("A booking app for dog walkers in my city", kind="project")
        sid = project["id"]
        self.mode.skip_questions(sid)
        self.wait_check(sid)
        self.mode.set_goal(sid, "Build the booking API")
        self.wait_check(sid)
        task = self.mode.work.store.all(sid)[-1]
        self.assertEqual((task["gate"], task["status"]), ("code", "approval"), "without autopilot: a plan to approve")
        read = [b for p, b in self.calls if p == "/v1/projects/task"][-1]
        self.assertEqual((read["mode"], read["confirmed"]), ("read", False), "never edits code unless autopilot is on")

        self.mode.work.store.update(task["id"], status="cancelled")  # the founder set the plan aside
        self.mode.launch.configure(sid, {"autopilot": True, "test_command": "pytest"})
        self.mode.set_goal(sid, "Build the booking API")
        self.wait_check(sid)
        task = self.mode.work.store.all(sid)[-1]
        self.assertEqual(task["status"], "done")
        edit = [b for p, b in self.calls if p == "/v1/projects/task"][-1]
        self.assertEqual((edit["mode"], edit["confirmed"]), ("edit", True))
        self.assertIn("Tests (`pytest`): passed", task["output"], "the tests are the evidence")
        self.assertTrue(any(p == "/v1/projects/commit" for p, _ in self.calls), "a passed code task is a version")
        room = "\n".join(m["content"] for m in self.mode.store.messages(sid))
        self.assertIn("🏁 **The project is developed.**", room, "autopilot keeps going until Tim says it's developed")

    def test_each_agent_has_a_model_and_the_checker_uses_another(self):
        from agentim.startup import Person, normalize_member
        member = normalize_member({"name": "Jo Lee", "title": "CTO", "model": "claude-code"}, set())
        self.assertEqual(member["model"], "claude-code")
        self.assertEqual(normalize_member({"name": "Jo Lee", "title": "CTO", "model": "auto"}, set())["model"], "")
        self.assertEqual(self.mode.model_for(Person(**member)), "claude-code", "the agent's own model")
        self.assertTrue(self.mode.model_for(Person("x", "Al Bo", "Designer", "🎨", "design")), "auto: picked for the role")
        self.assertIsInstance(self.mode.model_choices(), list)

    def test_parse_worth(self):
        from agentim.startup import parse_worth
        check = parse_worth(self.WORTH)
        self.assertEqual((check["verdict"], check["gap"]), ("buy", "none"))
        self.assertEqual(check["existing"][0], {"name": "Rover", "what": "dog walkers, 20% fee"})
        self.assertEqual(parse_worth("VERDICT: Build-on-top\nWHY: y")["verdict"], "build-on-top")
        self.assertEqual(parse_worth("garbage")["verdict"], "build", "unreadable: don't block the founder")


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        self.gateway, self.mode = make_startup_mode(llm=TeamLLM())
        self.mode.default_rhythm = "graph"
        startup = self.mode.create(PITCH, channel="telegram", chat_id="42")
        self.sid = startup["id"]
        self.mode.skip_questions(self.sid)
        self.mode.store.save({**self.mode.store.get(self.sid), "next_run": None})
        team = self.mode.detail(self.sid)["team"]
        self.first = [p["name"].split()[0] for p in team]
        self.sent = []
        self.mode.notify = lambda channel, chat, text: self.sent.append(text)
        self.asked = []

        def ask(prompt, label="", **kw):
            if "How many minutes until it's done" in prompt or "How many more minutes" in prompt:
                self.asked.append(prompt)
                return "about 25 minutes" if "more minutes" not in prompt else "10"
            if "asked for a summary" in prompt:
                return "## Summary\nGood progress.\n## Action items\n- **Ava**: post — ETA: in 30 min"
            return "ok"

        self.mode._ask = ask
        self.mode.work.kick = lambda sid: False  # the supervisor's decisions, without running the work

    def add(self, **fields):
        task = self.mode.work.store.add(self.sid, self.mode.detail(self.sid)["team"][0]["key"], "Write the pricing page",
                                        from_role="graph", **{k: v for k, v in fields.items() if k in ("eta_minutes", "deps")})
        updates = {k: v for k, v in fields.items() if k not in ("eta_minutes", "deps")}
        if updates:
            self.mode.work.store.update(task["id"], **updates)
        return task

    def test_tim_asks_for_etas_in_minutes(self):
        task = self.add()
        did = self.mode.supervisor.check(self.sid)
        self.assertEqual(did["etas"][0][1], 25)
        self.assertEqual(self.mode.work.store.get(task["id"])["eta"], "in 25 min")
        self.assertIn("never days", self.asked[0])
        self.assertIn("⏱️ **ETAs**", self.mode.store.messages(self.sid)[-1]["content"])

    def test_late_work_gets_a_new_eta_and_the_founder_hears_after_three_slips(self):
        import time as t
        now = t.time()
        task = self.add(eta_minutes=10, status="doing", started=now - 30 * 60)
        did = self.mode.supervisor.check(self.sid, now)
        self.assertEqual(did["late"][0][:2], (task["owner"], 20), "20 minutes past a 10-minute ETA")
        self.assertEqual(self.mode.work.store.get(task["id"])["eta_minutes"], 40, "30 elapsed + 10 more")
        self.assertIn("⏰ **Behind schedule**", self.mode.store.messages(self.sid)[-1]["content"])
        self.assertEqual(self.mode.supervisor.check(self.sid, now + 60)["late"], [], "no nagging every minute")
        self.mode.work.store.update(task["id"], slips=2, pinged=None)
        self.mode.supervisor.check(self.sid, now + 60 * 60)
        self.assertIn("slipped 3 times", self.mode.store.messages(self.sid)[-1]["content"])

    def test_ready_work_is_kicked_and_approvals_are_reminded(self):
        kicked = []
        self.mode.work.kick = lambda sid: kicked.append(sid) or True
        self.add(eta_minutes=15)
        did = self.mode.supervisor.check(self.sid)
        self.assertTrue(did["kicked"])
        import time as t
        waiting = self.add(eta_minutes=15, status="approval", finished=t.time() - 20 * 60)
        did = self.mode.supervisor.check(self.sid)
        self.assertEqual(did["reminded"], [waiting["id"]])
        self.assertEqual(self.mode.supervisor.check(self.sid)["reminded"], [], "once per reminder window")

    def test_a_summary_every_n_minutes_when_something_happened(self):
        import time as t
        now = t.time()
        self.add(eta_minutes=15, status="done", started=now - 60, finished=now)
        self.mode.supervisor.last_summary[self.sid] = now - 3 * 60 * 60
        did = self.mode.supervisor.check(self.sid, now + 1)
        self.assertTrue(did["summary"])
        self.assertTrue(self.sent and "Good progress" in self.sent[-1], "sent to Telegram/WhatsApp/Slack")
        self.assertFalse(self.mode.supervisor.check(self.sid, now + 120)["summary"], "not again right away")

    def test_gantt_in_minutes(self):
        from agentim.supervisor import parse_minutes, schedule
        base = 1_800_000_000
        tasks = [{"id": "a", "status": "done", "created": base, "started": base, "finished": base + 20 * 60,
                  "eta_minutes": 15, "eta_first": 15, "deps": []},
                 {"id": "b", "status": "todo", "created": base, "eta_minutes": 30, "eta_first": 30, "deps": ["a"]}]
        plan, origin = schedule(tasks, now=base + 25 * 60)
        self.assertEqual(origin, base)
        self.assertEqual((plan["a"]["planned_start"], plan["a"]["planned_end"]), (0, 15), "baseline from the first ETA")
        self.assertEqual((plan["a"]["start"], plan["a"]["end"]), (0, 20), "actual: 5 minutes late")
        self.assertEqual((plan["b"]["planned_start"], plan["b"]["planned_end"]), (15, 45))
        self.assertEqual((plan["b"]["start"], plan["b"]["end"]), (25, 55), "starts now, after its dependency")
        self.assertEqual(parse_minutes("~1.5 hours"), 90)
        self.assertEqual(parse_minutes("nope", 15), 15)

    def test_plans_carry_etas(self):
        from agentim.graph import parse_plan
        node = parse_plan("T1 | Ava | Write copy | done when: 3 headlines | after: - | gate: auto | eta: 25")[0]
        self.assertEqual(node["eta"], 25)


class ClaudeViaTests(unittest.TestCase):
    def test_tmux_mode_never_lists_the_claude_api(self):
        from agentim.config import from_env as load_config
        from agentim.models import Catalog as Models
        tmux = load_config({"ANTHROPIC_API_KEY": "sk-ant-x", "RUNNER_TOKEN": "t"})
        self.assertEqual(tmux.claude_via, "tmux", "the default")
        models = Models(tmux, api_factory=lambda url, token: None)
        self.assertFalse(any(m.backend == "anthropic" for m in models.cloud()), "a key alone doesn't switch to the API")
        api = load_config({"ANTHROPIC_API_KEY": "sk-ant-x", "RUNNER_TOKEN": "t", "AGENTIM_CLAUDE_VIA": "api"})
        self.assertTrue(any(m.backend == "anthropic" for m in Models(api, api_factory=lambda url, token: None).cloud()))


class SkillPlaybookTests(unittest.TestCase):
    def test_designers_and_business_development_get_their_playbooks(self):
        from agentim.skills import load_dirs
        from agentim.startup import playbook_slug
        self.assertEqual(playbook_slug("Designer"), "product-designer")
        self.assertEqual(playbook_slug("UX Lead"), "product-designer")
        self.assertEqual(playbook_slug("Brand Designer"), "brand-designer")
        self.assertEqual(playbook_slug("Visual Designer"), "brand-designer")
        self.assertEqual(playbook_slug("Business Development"), "business-development")
        self.assertEqual(playbook_slug("Head of Partnerships"), "business-development")
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        slugs = {s.slug for s in load_dirs(os.path.join(here, "skills"))}
        self.assertTrue({"product-designer", "brand-designer", "business-development"} <= slugs)
        self.assertNotIn("perdiem-business-development", slugs, "nothing company-specific in the public skills")


class BackgroundLimitTests(unittest.TestCase):
    def test_background_work_shares_two_slots_and_the_founder_skips_the_line(self):
        import threading
        import time as t
        _, mode = make_startup_mode(llm=TeamLLM())
        active, peak, lock = [0], [0], threading.Lock()
        release = threading.Event()

        def slow(prompt, label, model=None, avoid=None):
            with lock:
                active[0] += 1
                peak[0] = max(peak[0], active[0])
            release.wait(2)
            with lock:
                active[0] -= 1
            return "ok"

        mode._ask_now = slow
        threads = [threading.Thread(target=mode._ask, args=("p", f"Startup · X · Zoe works")) for _ in range(5)]
        for th in threads:
            th.start()
        t.sleep(0.2)
        self.assertEqual(peak[0], 2, "two background calls at a time")
        start = t.time()
        founder = threading.Thread(target=mode._ask, args=("p", "Startup interview questions"))
        founder.start()
        t.sleep(0.2)
        self.assertEqual(peak[0], 3, "the founder's call runs right away")
        release.set()
        for th in threads + [founder]:
            th.join(5)
        self.assertLess(t.time() - start, 5)


class RecruiterTests(unittest.TestCase):
    def test_sources_on_github_and_drafts_messages_the_founder_sends(self):
        gateway, mode = make_startup_mode(llm=TeamLLM())
        startup = mode.create(PITCH)
        sid = startup["id"]
        calls = []

        def call(path, body=None, timeout=30):
            calls.append((path, body))
            return {"candidates": [{"login": "ada", "name": "Ada L", "location": "Berlin", "company": "Acme",
                                    "repos": [{"name": "swift-sync", "language": "Swift", "stars": 2100, "description": "CRDT sync"}],
                                    "commits": [{"repo": "ada/swift-sync", "message": "Fix actor reentrancy"}]}]}

        gateway.claude.call = call
        mode._ask = lambda p, label="", **kw: (
            "language:swift location:berlin followers:>30" if "ONE GitHub user search query" in p else
            "SCORE: 8\nWHY: Maintains swift-sync (2.1k stars) and fixed actor reentrancy last week.\n"
            "NOTE: Hi Ada, loved your actor reentrancy fix in swift-sync. We're building offline sync for dog walkers: 15 min?\n"
            "MESSAGE: Hi Ada, your swift-sync work is exactly the problem we're solving. Open to a 15-minute call?")
        with self.assertRaisesRegex(ValueError, "Describe the role"):
            mode.recruit.start(sid, "ios")
        mode.recruit.start(sid, "Senior iOS engineer, Swift, Europe")
        import time as t
        end = t.time() + 5
        while sid in mode.recruit.running and t.time() < end:
            t.sleep(0.01)
        self.assertEqual(calls[0], ("/v1/recruit/search", {"q": "language:swift location:berlin followers:>30", "limit": 8}))
        [ada] = mode.recruit.board(sid)["candidates"]
        self.assertEqual((ada["login"], ada["score"], ada["status"]), ("ada", 8.0, "new"))
        self.assertIn("actor reentrancy", ada["note"])
        self.assertLessEqual(len(ada["note"]), 300)
        self.assertTrue(ada["linkedin"].startswith("https://www.linkedin.com/search/results/people/?keywords=Ada%20L"))
        room = "\n".join(m["content"] for m in mode.store.messages(sid))
        self.assertIn("1 candidates", room)
        self.assertIn("send them yourself on LinkedIn", room)
        mode.recruit.set_status(sid, ada["id"], "contacted", message="Edited message")
        ada = mode.recruit.board(sid)["candidates"][0]
        self.assertEqual((ada["status"], ada["message"]), ("contacted", "Edited message"))
        with self.assertRaisesRegex(ValueError, "Status"):
            mode.recruit.set_status(sid, ada["id"], "hired!")
        mode.recruit.start(sid, "Senior iOS engineer, Swift, Europe")
        end = t.time() + 5
        while sid in mode.recruit.running and t.time() < end:
            t.sleep(0.01)
        self.assertEqual(len(mode.recruit.board(sid)["candidates"]), 1, "the same person isn't added twice")

    def test_parse_assessment(self):
        from agentim.recruit import clean_query, parse_assessment
        a = parse_assessment("SCORE: 7.5\nWHY: good\nNOTE: hi\nthere\nMESSAGE: long one")
        self.assertEqual((a["score"], a["why"], a["note"], a["message"]), (7.5, "good", "hi\nthere", "long one"))
        self.assertEqual(clean_query("`query: language:go location:paris`"), "language:go location:paris")


if __name__ == "__main__":
    unittest.main()
