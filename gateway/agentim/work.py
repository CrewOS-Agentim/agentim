"""Event-driven work: tasks, agents working as soon as a task is ready, and handoffs.

A meeting's action items become tasks on the startup's work board. A task is ready when what it waits for is done.
Ready tasks start right away (a few at a time): the owner does the work, posts the result in the agents room, and
hands off to the colleagues who should continue from it, which starts them immediately. When nothing is left, the
team meets (after a short break) to plan the next tasks. Budgets keep it from running forever.
"""

import json
import logging
import re
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

from .graph import MAX_ATTEMPTS, check_prompt, deps_of, gate_for, layers, parse_check, parse_plan, plan_prompt, summary_prompt

log = logging.getLogger("agentim.work")

MAX_TASKS_PER_DAY = 40      # per startup
MAX_DEPTH = 4               # a handoff chain stops after this many steps
PARALLEL = 3                # agents working at the same time
HANDOFF = re.compile(r"^\s*\**HANDOFF\**\s*:\s*(?P<rest>.+)$", re.IGNORECASE)
TARGET = re.compile(r"^@?(?P<name>[\w-]+)\s*[:\-–—]\s*(?P<task>.+?)(?:\s*[—–-]+\s*ETA:\s*(?P<eta>.+))?$")


def parse_handoffs(output):
    """(the result without the HANDOFF lines, [(first name, task, eta)])."""
    kept, handoffs = [], []
    for line in (output or "").splitlines():
        match = HANDOFF.match(line)
        if not match:
            kept.append(line)
            continue
        rest = match.group("rest").strip().strip("*").strip()
        target = TARGET.match(rest)
        if rest.lower().startswith("none") or not target:
            continue
        handoffs.append((target.group("name"), target.group("task").strip(), (target.group("eta") or "").strip()))
    return "\n".join(kept).strip(), handoffs


class WorkStore:
    def __init__(self, db, lock):
        self.db, self.lock = db, lock
        with self.lock, self.db:
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_tasks (
                id TEXT PRIMARY KEY, startup_id TEXT, owner TEXT, task TEXT, eta TEXT, status TEXT,
                depends_on TEXT, from_role TEXT, input TEXT, output TEXT, depth INTEGER, round INTEGER,
                created REAL, started REAL, finished REAL)""")
            self.db.execute("CREATE INDEX IF NOT EXISTS startup_tasks_id ON startup_tasks (startup_id, created)")
            # Graph, loop and gate columns (added in place on older databases).
            existing = {row[1] for row in self.db.execute("PRAGMA table_info(startup_tasks)")}
            for column, kind in (("deps", "TEXT"), ("done_when", "TEXT"), ("gate", "TEXT"), ("attempts", "INTEGER"),
                                 ("feedback", "TEXT"), ("goal", "TEXT")):
                if column not in existing:
                    self.db.execute(f"ALTER TABLE startup_tasks ADD COLUMN {column} {kind}")

    COLUMNS = ["id", "startup_id", "owner", "task", "eta", "status", "depends_on", "from_role", "input", "output",
               "depth", "round", "created", "started", "finished", "deps", "done_when", "gate", "attempts", "feedback",
               "goal"]

    def add(self, startup_id, owner, task, eta="", depends_on=None, from_role="meeting", input="", depth=0, round_no=0,
            deps=None, done_when="", gate="auto", goal=""):
        row = {"id": uuid.uuid4().hex[:10], "startup_id": startup_id, "owner": owner, "task": task.strip()[:500],
               "eta": eta, "status": "todo", "depends_on": depends_on, "from_role": from_role, "input": input[-4000:],
               "output": "", "depth": depth, "round": round_no, "created": time.time(), "started": None, "finished": None,
               "deps": json.dumps(deps or []), "done_when": done_when, "gate": gate_for(task, gate) if gate != "auto" or
               done_when else gate, "attempts": 0, "feedback": "", "goal": goal}
        with self.lock, self.db:
            self.db.execute(f"INSERT INTO startup_tasks VALUES ({', '.join('?' * len(self.COLUMNS))})",
                            [row[c] for c in self.COLUMNS])
        return row

    def update(self, task_id, **fields):
        sets = ", ".join(f"{k} = ?" for k in fields)
        with self.lock, self.db:
            self.db.execute(f"UPDATE startup_tasks SET {sets} WHERE id = ?", [*fields.values(), task_id])

    def all(self, startup_id, limit=200):
        with self.lock:
            rows = self.db.execute(f"SELECT {', '.join(self.COLUMNS)} FROM startup_tasks WHERE startup_id = ? "
                                   "ORDER BY created DESC LIMIT ?", (startup_id, limit)).fetchall()
        return [dict(zip(self.COLUMNS, r)) for r in reversed(rows)]

    def get(self, task_id):
        with self.lock:
            row = self.db.execute(f"SELECT {', '.join(self.COLUMNS)} FROM startup_tasks WHERE id = ?", (task_id,)).fetchone()
        return dict(zip(self.COLUMNS, row)) if row else None

    def delete_startup(self, startup_id):
        with self.lock, self.db:
            self.db.execute("DELETE FROM startup_tasks WHERE startup_id = ?", (startup_id,))

    def started_today(self, startup_id):
        midnight = time.mktime(time.localtime()[:3] + (0, 0, 0, 0, 0, -1))
        with self.lock:
            return self.db.execute("SELECT COUNT(*) FROM startup_tasks WHERE startup_id = ? AND started >= ?",
                                   (startup_id, midnight)).fetchone()[0]


class Work:
    def __init__(self, mode, store: WorkStore):
        self.mode, self.store = mode, store
        self.running = set()          # startups whose work loop is running
        self.working = {}             # startup id → {task id: owner key} being worked on now
        self.guard = threading.Lock()
        self.max_per_day, self.max_depth, self.parallel = MAX_TASKS_PER_DAY, MAX_DEPTH, PARALLEL

    # ---- the board

    def board(self, startup_id):
        tasks = self.store.all(startup_id)
        by_id = {t["id"]: t for t in tasks}
        for t in tasks:
            t["deps"] = deps_of(t)
            waiting = [by_id[d]["task"] for d in t["deps"] if d in by_id and by_id[d]["status"] not in ("done", "cancelled")]
            t["waiting_for"] = "; ".join(waiting) or None
            t["ready"] = t["status"] == "todo" and self.is_ready(t, by_id)
            t["attempts"] = t.get("attempts") or 0
        depth = layers(tasks)
        for t in tasks:
            t["layer"] = depth.get(t["id"], 0)
        return {"tasks": tasks, "working": sorted(set((self.working.get(startup_id) or {}).values())),
                "started_today": self.store.started_today(startup_id), "budget": self.max_per_day}

    @staticmethod
    def is_ready(task, by_id):
        return all(by_id[d]["status"] in ("done", "cancelled") for d in deps_of(task) if d in by_id)

    def people(self, startup):
        from .startup import team_of
        return {p.first.lower(): p for p in team_of(startup)} | {p.key: p for p in team_of(startup)}

    def seed(self, startup_id, round_no, items):
        """A meeting's action items → tasks (skipping ones already open). "after X's …" becomes a dependency."""
        startup = self.mode.store.get(startup_id)
        people = self.people(startup)
        open_tasks = [t for t in self.store.all(startup_id) if t["status"] in ("todo", "doing")]
        seen = {(t["owner"], t["task"].lower()) for t in open_tasks}
        created = []
        for item in items:
            person = people.get((item.get("owner") or "").lower())
            if not person or (person.key, item["task"].lower()) in seen:
                continue
            depends = None
            if item.get("after"):
                first = item["after"].split("'")[0].split()[0].lower() if item["after"].split() else ""
                dep_person = people.get(first)
                if dep_person:
                    depends = next((t["id"] for t in reversed(open_tasks + created) if t["owner"] == dep_person.key), None)
            task = self.store.add(startup_id, person.key, item["task"], item.get("eta", ""), depends, "meeting",
                                  round_no=round_no)
            seen.add((person.key, item["task"].lower()))
            created.append(task)
        return created

    def assign(self, startup_id, owner, text):
        """The founder gives someone a task directly; it starts right away."""
        startup = self.mode.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        person = self.people(startup).get((owner or "").lower())
        if not person:
            raise ValueError("Pick someone on the team.")
        if not (text or "").strip():
            raise ValueError("What should they do?")
        task = self.store.add(startup_id, person.key, text, "", None, "founder")
        self.kick(startup_id)
        return task

    def cancel(self, startup_id, task_id):
        task = self.store.get(task_id)
        if not task or task["startup_id"] != startup_id:
            raise ValueError("No such task.")
        if task["status"] in ("todo", "doing"):
            self.store.update(task_id, status="cancelled", finished=time.time())
        return self.store.get(task_id)

    # ---- the work loop (event-driven)

    def kick(self, startup_id):
        """Starts working through the ready tasks (does nothing if that's already happening)."""
        with self.guard:
            if startup_id in self.running:
                return False
            self.running.add(startup_id)
        threading.Thread(target=self.run, args=(startup_id,), daemon=True).start()
        return True

    def run(self, startup_id):
        try:
            with ThreadPoolExecutor(max_workers=self.parallel) as pool:
                while True:
                    startup = self.mode.store.get(startup_id)
                    if not startup or startup["status"] != "running":
                        break
                    if self.store.started_today(startup_id) >= self.max_per_day:
                        self.mode.store.add_message(startup_id, max(startup["rounds"], 1), "ceo",
                                                    f"That's {self.max_per_day} tasks today: we'll pick the rest up tomorrow.")
                        break
                    by_id = {t["id"]: t for t in self.store.all(startup_id)}
                    ready = [t for t in by_id.values() if t["status"] == "todo" and self.is_ready(t, by_id)]
                    if not ready:
                        break
                    batch = ready[:self.parallel]
                    attempts = {t["id"]: t.get("attempts") or 0 for t in batch}
                    for task in batch:
                        self.store.update(task["id"], status="doing", started=time.time())
                        self.working.setdefault(startup_id, {})[task["id"]] = task["owner"]
                    list(pool.map(lambda t: self.do(startup_id, t), batch))
                    after = {t["id"]: self.store.get(t["id"]) or {} for t in batch}
                    if all(a.get("status") == "todo" and (a.get("attempts") or 0) == attempts[i] for i, a in after.items()):
                        break  # no model answered: stop here; the next goal, meeting or message tries again
            self.after_work(startup_id)
        except Exception:
            log.exception("work: the loop failed")
        finally:
            self.working.pop(startup_id, None)
            with self.guard:
                self.running.discard(startup_id)

    def do(self, startup_id, task):
        """One agent does one task, posts the result and hands off."""
        from .startup import FOUNDER, people_of, person_context, team_of
        try:
            startup = self.mode.store.get(startup_id)
            if not startup:
                return  # the startup was deleted while this was queued
            team, people = team_of(startup), people_of(startup)
            person = next((p for p in team if p.key == task["owner"]), None)
            if not person:
                self.store.update(task["id"], status="cancelled", finished=time.time(), output="(no longer on the team)")
                return
            current = {p.key for p in team} | {"ceo", FOUNDER.key}
            discussion = "\n".join(f"{people[m['role']].name}: {m['content']}"
                                   for m in self.mode.store.messages(startup_id, limit=6) if m["role"] in current)
            startup["memory"] = self.mode.memory.brief(startup_id, person.key)  # the harness: memory outside the chat
            source = {"meeting": "the team meeting", "founder": "the founder", "graph": "the plan"}.get(task["from_role"]) \
                or (people[task["from_role"]].first if task["from_role"] in people else task["from_role"])
            colleagues = ", ".join(p.first for p in team if p.key != person.key)
            can_hand_off = task["depth"] < self.max_depth and task["from_role"] != "graph"  # the graph sets the flow
            prompt = (person_context(person, startup, discussion, team, self.mode.playbook(person)) + f"""

YOUR TASK (from {source}): {task['task']}
{f"Input from {source}:{chr(10)}{task['input']}{chr(10)}" if task['input'] else ""}{self.inputs(task)}\
{f"It's done when: {task['done_when']}. Make sure the result itself shows that.{chr(10)}" if task.get('done_when') else ""}\
{f"Your last attempt didn't pass the check: {task['feedback']}{chr(10)}Change exactly that; don't repeat the same result.{chr(10)}" if task.get('feedback') and task.get('status') != 'blocked' else ""}
Do the task now and deliver the actual result (the draft, copy, numbers, plan or checklist), not a promise or a plan to \
do it. Under 300 words, markdown. Never invent traction (users, sign-ups, revenue, customers): use a placeholder like \
[X users] unless the founder or the team gave the real number.""" + (f"""
Then, on the last lines, hand off to colleagues who should continue from your result ({colleagues}), 0–2 of them:
HANDOFF: @FirstName: <their next task, building on your result> — ETA: in N min
Write "HANDOFF: none" if your result needs nothing more.""" if can_hand_off else ""))
            if task.get("gate") == "code":
                return self.do_code(startup_id, startup, task, person)
            worker = self.mode.model_for(person)
            task["worker_model"] = worker
            reply = self.mode._ask(prompt, f"Startup · {startup['name']} · {person.first} works", model=worker)
            if not reply:
                self.store.update(task["id"], status="todo", started=None)  # no model: try again later
                return
            result, handoffs = parse_handoffs(reply)
            round_no = max(startup["rounds"], 1)  # work is filed under the meeting it came from
            names = self.people(startup)
            passed = []
            for name, next_task, eta in handoffs[:2] if can_hand_off else []:
                target = names.get(name.lower())
                if not target or target.key == person.key:
                    continue
                self.store.add(startup_id, target.key, next_task, eta, None, person.key, input=result,
                               depth=task["depth"] + 1, round_no=round_no)
                passed.append(f"@{target.first}: {next_task}" + (f" ({eta})" if eta else ""))
            self.finish(startup_id, task, person, result, passed, round_no)
        except Exception as e:  # noqa: BLE001
            log.exception("work: task failed")
            self.store.update(task["id"], status="todo", started=None, output=f"(failed: {e})")
        finally:
            (self.working.get(startup_id) or {}).pop(task["id"], None)

    def inputs(self, task):
        """In a graph, a task starts from the results of the tasks it needed."""
        deps = [self.store.get(d) for d in deps_of(task)]
        done = [d for d in deps if d and d["status"] == "done" and d["output"]]
        if not done:
            return ""
        return "".join(f"Result of \"{d['task']}\" ({d['owner']}):\n{d['output'][-1500:]}\n\n" for d in done)

    # ---- the loop: check against "done when", feedback, retries, gates, lessons

    def finish(self, startup_id, task, person, result, passed, round_no):
        gate = task.get("gate") or "auto"
        say = lambda role, text: self.mode.store.add_message(startup_id, round_no, role, text)  # noqa: E731
        handed = ("\n\n➡️ Handed off to " + "; ".join(passed)) if passed else ""
        if gate in ("review", "founder", "code") and task.get("done_when"):
            checker = self.mode.checker_model(avoid=task.get("worker_model"))
            ok, reason = parse_check(self.mode._ask(check_prompt(task, result), f"Check · {task['task'][:40]}", model=checker))
            if not ok:
                attempts = (task.get("attempts") or 0) + 1
                say(person.key, f"📝 **Attempt {attempts}**: {task['task']}\n\n{result}")
                if attempts < MAX_ATTEMPTS:
                    self.store.update(task["id"], status="todo", started=None, attempts=attempts, feedback=reason,
                                      output=result)
                    say("ceo", f"🔁 Not yet, {person.first}: {reason}")
                else:
                    self.store.update(task["id"], status="blocked", attempts=attempts, feedback=reason, output=result,
                                      finished=time.time())
                    # Learning: the failure becomes a lesson for this role, so the same mistake doesn't come back.
                    self.mode.memory.add(startup_id, "lesson", f"{task['task'][:80]}: {reason}", role=person.key)
                    say("ceo", f"⛔ **Blocked** after {attempts} tries: {task['task']}\n\nWhy: {reason}\n\n"
                               "It needs you: give a hint and retry, or cancel it.")
                return
        if gate == "founder":
            self.store.update(task["id"], status="approval", output=result, feedback="")
            say(person.key, f"🙋 **Needs your approval**: {task['task']}\n\n{result}{handed}")
            return
        self.store.update(task["id"], status="done", output=result, feedback="", finished=time.time())  # frozen
        check = " (checked ✓)" if gate == "review" and task.get("done_when") else ""
        say(person.key, f"✅ **Done**{check}: {task['task']}\n\n{result}{handed}")

    def do_code(self, startup_id, startup, task, person):
        """A code task: Claude Code changes the project's code (only on autopilot, which the founder turned on;
        otherwise it plans the change and waits for approval), the tests are the evidence, and a pass is a version."""
        launch = self.mode.launch
        config = startup.get("config") or {}
        autopilot = bool(config.get("autopilot"))
        try:
            source = launch.workspace(startup_id)
        except Exception as e:  # noqa: BLE001
            self.store.update(task["id"], status="blocked", feedback=f"No project folder: {e}", finished=time.time())
            return
        prompt = (f"{task['task']}\n\nProject: {startup['name']}: {startup['pitch']}\n"
                  + (f"Done when: {task['done_when']}\n" if task.get("done_when") else "")
                  + self.inputs(task)
                  + (f"Your last attempt didn't pass: {task['feedback']}\nFix exactly that.\n" if task.get("feedback") else "")
                  + ("Make the change, keep it focused, add or update tests, and end with a short summary." if autopilot
                     else "Plan the change without editing files: the files, the steps and the tests (under 250 words)."))
        try:
            result = launch.runner("/v1/projects/task", {"source": source, "prompt": prompt, "agent": "claude-code",
                                                         "mode": "edit" if autopilot else "read", "confirmed": autopilot,
                                                         "timeout": 1800}, timeout=1900)
        except Exception as e:  # noqa: BLE001
            self.store.update(task["id"], status="todo", started=None, feedback=f"Claude Code couldn't run: {e}")
            return
        output = result.get("output", "").strip()[-3000:]
        changed = result.get("changed") or ""
        evidence = ""
        command = config.get("test_command")
        if autopilot and command:
            run = launch.runner("/v1/projects/run", {"source": source, "command": command, "confirmed": True,
                                                     "timeout": 900}, timeout=960)
            evidence = f"\n\nTests (`{command}`): {'passed' if run['exit_code'] == 0 else 'FAILED'}\n```\n{run['output'][-800:]}\n```"
            if run["exit_code"] != 0:
                task = {**task, "done_when": (task.get("done_when") or "") + f" AND `{command}` passes"}
        body = output + (f"\n\nChanged:\n```\n{changed}\n```" if changed else "") + evidence
        round_no = max(startup["rounds"], 1)
        if not autopilot:
            self.store.update(task["id"], status="approval", output=body, feedback="")
            self.mode.store.add_message(startup_id, round_no, "claude-code",
                                        f"🙋 **Plan for a code change** ({person.first}'s task): {task['task']}\n\n{body}\n\n"
                                        "_Turn on autopilot to let Claude Code make code changes, or approve this plan._")
            return
        task["worker_model"] = "claude-code"
        self.finish(startup_id, task, person, body, [], round_no)
        if (self.store.get(task["id"]) or {}).get("status") == "done":
            launch._version(startup_id, f"feat: {task['task'][:72]}", output[:400])

    def approve(self, startup_id, task_id):
        task = self._own(startup_id, task_id)
        if task["status"] != "approval":
            raise ValueError("That task isn't waiting for approval.")
        self.store.update(task_id, status="done", finished=time.time())
        self.mode.store.add_message(startup_id, max(self.mode.store.get(startup_id)["rounds"], 1), "founder",
                                    f"👍 Approved: {task['task']}")
        self.kick(startup_id)
        return self.store.get(task_id)

    def reject(self, startup_id, task_id, note=""):
        """Back to the owner with the founder's reason (it also becomes a lesson)."""
        task = self._own(startup_id, task_id)
        if task["status"] not in ("approval", "done", "blocked"):
            raise ValueError("Only finished, blocked or waiting tasks can be sent back.")
        note = (note or "").strip() or "Not good enough yet: try again."
        self.store.update(task_id, status="todo", started=None, feedback=f"The founder says: {note}", attempts=0)
        self.mode.memory.add(startup_id, "lesson", f"{task['task'][:80]}: the founder said {note}", role=task["owner"])
        self.kick(startup_id)
        return self.store.get(task_id)

    def retry(self, startup_id, task_id, hint=""):
        task = self._own(startup_id, task_id)
        feedback = (f"The founder's hint: {hint.strip()}. " if (hint or "").strip() else "") + (task.get("feedback") or "")
        self.store.update(task_id, status="todo", started=None, attempts=0, feedback=feedback.strip())
        self.kick(startup_id)
        return self.store.get(task_id)

    def _own(self, startup_id, task_id):
        task = self.store.get(task_id)
        if not task or task["startup_id"] != startup_id:
            raise ValueError("No such task.")
        return task

    # ---- the graph: a goal becomes tasks with dependencies and gates

    def plan(self, startup_id, goal):
        startup = self.mode.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        goal = (goal or "").strip()
        if not goal:
            raise ValueError("What's the goal?")
        from .startup import team_of
        team = team_of(startup)
        reply = self.mode._ask(plan_prompt(startup, goal, team, self.mode.memory.brief(startup_id)),
                               f"Startup · {startup['name']} · plan the graph")
        nodes = parse_plan(reply or "")
        people = self.people(startup)
        nodes = [n for n in nodes if people.get(n["owner"].lower())]
        if not nodes:
            raise ValueError("Agent Tim couldn't turn that into tasks. Try a more concrete goal, or check that a model is running.")
        ids, created = {}, []
        for n in nodes:
            owner = people[n["owner"].lower()]
            task = self.store.add(startup_id, owner.key, n["task"], "", None, "graph", round_no=max(startup["rounds"], 1),
                                  deps=[ids[r] for r in n["after"] if r in ids], done_when=n["done_when"],
                                  gate=n["gate"], goal=goal)
            ids[n["ref"]] = task["id"]
            created.append((n, owner, task))
        self.mode.memory.add(startup_id, "decision", f"Goal: {goal}")
        lines = "\n".join(f"- **{n['ref']} {o.first}**: {n['task']}" + (f" _(after {', '.join(n['after'])})_" if n["after"] else "")
                          + {"founder": " 🙋 needs you", "review": " 🔍 checked"}.get(t["gate"], "") for n, o, t in created)
        self.mode.store.add_message(startup_id, max(startup["rounds"], 1), "ceo",
                                    f"🗺️ **Plan**: {goal}\n\n{lines}\n\n_Tasks without arrows start now, in parallel._")
        self.kick(startup_id)
        return [t for _, _, t in created]

    # ---- one meeting: a summary on demand

    def summarize(self, startup_id):
        startup = self.mode.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        from .startup import FOUNDER, day_of, people_of, with_owners_and_etas, clean_minutes
        people = people_of(startup)
        board = self.board(startup_id)["tasks"]
        for t in board:
            t["owner"] = people[t["owner"]].first if t["owner"] in people else t["owner"]
        room = "\n".join(f"{people[m['role']].first if m['role'] in people else m['role']}: {m['content'][:300]}"
                         for m in self.mode.store.messages(startup_id, limit=25))
        reply = self.mode._ask(summary_prompt(startup, board, self.mode.memory.brief(startup_id), room),
                               f"Startup · {startup['name']} · summary")
        if not reply:
            counts = {s: sum(1 for t in board if t["status"] == s) for s in ("done", "doing", "todo", "approval", "blocked")}
            reply = (f"## Summary\n{counts['done']} tasks done, {counts['doing']} in progress, {counts['todo']} to do.\n\n"
                     f"## Needs you\n- {counts['approval']} waiting for approval, {counts['blocked']} blocked\n")
        text = reply.strip()
        # Decisions go into memory (the harness), so every agent works from them.
        decisions = re.search(r"^## Decisions\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
        known = {m["text"] for m in self.mode.memory.all(startup_id)}
        for line in (decisions.group(1).splitlines() if decisions else []):
            item = line.strip().lstrip("-* ").strip()
            if item and item.lower() not in ("none", "none yet") and item not in known:
                self.mode.memory.add(startup_id, "decision", item)
        minutes = clean_minutes(text) or text
        speakers = [p.first for k, p in people.items() if k not in ("founder", "ceo", "claude-code")]
        minutes = with_owners_and_etas(minutes, [], time.time()) if "## Action items" in minutes else minutes
        today = day_of(time.time())
        row = self.mode.store.day_row(startup_id, today)
        self.mode.store.save_day(startup_id, today, minutes, row["rounds"] if row else [])
        self.mode.store.add_message(startup_id, max(startup["rounds"], 1), "ceo", f"📋 **Summary**\n\n{text}")
        _ = (FOUNDER, speakers)
        return {"summary": text, "day": today}

    def after_work(self, startup_id):
        """Nothing left to do: in the graph, the goal is done (or waits for you); with meetings, the team meets after
        a short break to plan the next tasks."""
        startup = self.mode.store.get(startup_id)
        if not startup or startup["status"] != "running":
            return
        if self.mode.rhythm(startup) == "graph":
            tasks = self.store.all(startup_id)
            if any(t["status"] in ("todo", "doing") for t in tasks if t["status"] == "doing" or self.is_ready(t, {x["id"]: x for x in tasks})):
                return
            waiting = [t for t in tasks if t["status"] in ("approval", "blocked")]
            if waiting:
                self.mode.store.add_message(startup_id, max(startup["rounds"], 1), "ceo",
                                            f"⏸️ {len(waiting)} task{'s' if len(waiting) != 1 else ''} need you (approve, give a hint, or cancel); the rest is done.")
            elif tasks and tasks[-1].get("goal"):
                autopilot = (startup.get("config") or {}).get("autopilot")
                self.mode.store.add_message(startup_id, max(startup["rounds"], 1), "ceo",
                                            f"🏁 **Goal done**: {tasks[-1]['goal']}." + (
                                                " Autopilot: setting the next goal." if autopilot
                                                else " Ask for a summary, or set the next goal."))
                if autopilot:
                    import threading as _t
                    _t.Thread(target=self.mode.next_goal, args=(startup_id,), daemon=True).start()
            return
        by_id = {t["id"]: t for t in self.store.all(startup_id)}
        if any(t["status"] == "doing" or (t["status"] == "todo" and self.is_ready(t, by_id)) for t in by_id.values()):
            return
        startup["next_run"] = self.mode.clock() + int(startup.get("min_minutes") or 10) * 60
        self.mode.store.save(startup)
