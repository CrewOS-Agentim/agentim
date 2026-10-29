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

    COLUMNS = ["id", "startup_id", "owner", "task", "eta", "status", "depends_on", "from_role", "input", "output",
               "depth", "round", "created", "started", "finished"]

    def add(self, startup_id, owner, task, eta="", depends_on=None, from_role="meeting", input="", depth=0, round_no=0):
        row = {"id": uuid.uuid4().hex[:10], "startup_id": startup_id, "owner": owner, "task": task.strip()[:500],
               "eta": eta, "status": "todo", "depends_on": depends_on, "from_role": from_role, "input": input[-4000:],
               "output": "", "depth": depth, "round": round_no, "created": time.time(), "started": None, "finished": None}
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
            t["waiting_for"] = by_id[t["depends_on"]]["task"] if t["depends_on"] in by_id else None
            t["ready"] = t["status"] == "todo" and self.is_ready(t, by_id)
        return {"tasks": tasks, "working": sorted(set((self.working.get(startup_id) or {}).values())),
                "started_today": self.store.started_today(startup_id), "budget": self.max_per_day}

    @staticmethod
    def is_ready(task, by_id):
        dep = by_id.get(task["depends_on"]) if task["depends_on"] else None
        return dep is None or dep["status"] in ("done", "cancelled")

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
                    for task in batch:
                        self.store.update(task["id"], status="doing", started=time.time())
                        self.working.setdefault(startup_id, {})[task["id"]] = task["owner"]
                    list(pool.map(lambda t: self.do(startup_id, t), batch))
                    if all((self.store.get(t["id"]) or {}).get("status") == "todo" for t in batch):
                        break  # no model answered: stop here; the next meeting or message tries again
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
            source = {"meeting": "the team meeting", "founder": "the founder"}.get(task["from_role"]) \
                or (people[task["from_role"]].first if task["from_role"] in people else task["from_role"])
            colleagues = ", ".join(p.first for p in team if p.key != person.key)
            can_hand_off = task["depth"] < self.max_depth
            prompt = (person_context(person, startup, discussion, team, self.mode.playbook(person)) + f"""

YOUR TASK (from {source}): {task['task']}
{f"Input from {source}:{chr(10)}{task['input']}{chr(10)}" if task['input'] else ""}
Do the task now and deliver the actual result (the draft, copy, numbers, plan or checklist), not a promise or a plan to \
do it. Under 300 words, markdown. Never invent traction (users, sign-ups, revenue, customers): use a placeholder like \
[X users] unless the founder or the team gave the real number.""" + (f"""
Then, on the last lines, hand off to colleagues who should continue from your result ({colleagues}), 0–2 of them:
HANDOFF: @FirstName: <their next task, building on your result> — ETA: in N min
Write "HANDOFF: none" if your result needs nothing more.""" if can_hand_off else ""))
            reply = self.mode._ask(prompt, f"Startup · {startup['name']} · {person.first} works")
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
            self.store.update(task["id"], status="done", output=result, finished=time.time())
            text = f"✅ **Done**: {task['task']}\n\n{result}" + (
                "\n\n➡️ Handed off to " + "; ".join(passed) if passed else "")
            self.mode.store.add_message(startup_id, round_no, person.key, text)
        except Exception as e:  # noqa: BLE001
            log.exception("work: task failed")
            self.store.update(task["id"], status="todo", started=None, output=f"(failed: {e})")
        finally:
            (self.working.get(startup_id) or {}).pop(task["id"], None)

    def after_work(self, startup_id):
        """Nothing left to do: the team meets after a short break to plan the next tasks."""
        startup = self.mode.store.get(startup_id)
        if not startup or startup["status"] != "running":
            return
        by_id = {t["id"]: t for t in self.store.all(startup_id)}
        if any(t["status"] == "doing" or (t["status"] == "todo" and self.is_ready(t, by_id)) for t in by_id.values()):
            return
        startup["next_run"] = self.mode.clock() + int(startup.get("min_minutes") or 10) * 60
        self.mode.store.save(startup)
