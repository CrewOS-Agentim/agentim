"""Harness, loops and graphs for Startup Mode (after "Harness, Loops, Graphs: what each layer fixes").

- Harness: the team's memory (decisions, facts, the founder's rules, lessons) lives outside any one conversation and
  goes into every agent's brief; permissions stay where they are (only Claude Code touches code, the founder approves
  anything public or costly).
- Loop: every task has a "done when" (evidence that can fail). Agent Tim checks each result against it; a fail goes back
  with the specific reason (no repeating the same result), up to 2 retries, then the task is blocked and comes to you.
- Graph: a goal becomes a graph of tasks with dependencies; independent tasks run in parallel; passed work is frozen.
  Gates follow the cost of undoing: auto (cheap), review (Tim checks), founder (public, customers, money, deploys).
- Learning: a task that fails its check twice leaves a lesson in that role's memory, so the class of mistake doesn't
  come back.
- One meeting: no scheduled rounds; the agents room is one continuous meeting, summarized on demand.
"""

import json
import re
import time
import uuid

MAX_ATTEMPTS = 3            # the first try + 2 retries
GATES = ("auto", "review", "founder", "code")
# Work you can't take back: never accepted without the founder.
IRREVERSIBLE = re.compile(r"\b(publish|post(ed|ing)? (it|on|to)|tweet|send (it|the|an?|to)|email (the )?(customers?|users?|list)|"
                          r"launch (it )?publicly|go live|deploy|pay|spend|buy|sign (the|a) contract|press release)\b", re.I)
PLAN_LINE = re.compile(r"^\s*\**\s*(?P<id>T\d+)\s*\**\s*\|\s*(?P<owner>[^|]+)\|\s*(?P<task>[^|]+)\|(?P<rest>.*)$", re.I)


class Memory:
    """The startup's memory: rules (from the founder), decisions, facts and lessons (by role)."""

    def __init__(self, db, lock):
        self.db, self.lock = db, lock
        with self.lock, self.db:
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_memory (
                id TEXT PRIMARY KEY, startup_id TEXT, kind TEXT, role TEXT, text TEXT, created REAL)""")

    def add(self, startup_id, kind, text, role=""):
        item = {"id": uuid.uuid4().hex[:8], "kind": kind, "role": role, "text": text.strip()[:400], "created": time.time()}
        with self.lock, self.db:
            self.db.execute("INSERT INTO startup_memory VALUES (?, ?, ?, ?, ?, ?)",
                            (item["id"], startup_id, kind, role, item["text"], item["created"]))
        return item

    def all(self, startup_id):
        with self.lock:
            rows = self.db.execute("SELECT id, kind, role, text, created FROM startup_memory WHERE startup_id = ? "
                                   "ORDER BY created", (startup_id,)).fetchall()
        return [{"id": i, "kind": k, "role": r, "text": t, "created": c} for i, k, r, t, c in rows]

    def delete(self, startup_id, item_id=None):
        with self.lock, self.db:
            if item_id:
                self.db.execute("DELETE FROM startup_memory WHERE startup_id = ? AND id = ?", (startup_id, item_id))
            else:
                self.db.execute("DELETE FROM startup_memory WHERE startup_id = ?", (startup_id,))

    def brief(self, startup_id, role=None, limit=12):
        """What an agent must keep in mind: the founder's rules, the decisions and facts, and its own lessons."""
        items = self.all(startup_id)
        rules = [i["text"] for i in items if i["kind"] == "rule"]
        known = [i["text"] for i in items if i["kind"] in ("decision", "fact")][-limit:]
        lessons = [i["text"] for i in items if i["kind"] == "lesson" and (not role or i["role"] in (role, ""))][-6:]
        parts = []
        if rules:
            parts.append("The founder's rules (always follow):\n" + "\n".join(f"- {r}" for r in rules))
        if known:
            parts.append("What the team decided and knows:\n" + "\n".join(f"- {k}" for k in known))
        if lessons:
            parts.append("Lessons from earlier mistakes (don't repeat them):\n" + "\n".join(f"- {l}" for l in lessons))
        return "\n\n".join(parts)


IRREVERSIBLE_VERB = re.compile(r"^\W*(post|publish|tweet|send|email|announce|deploy|pay|buy|submit)\b", re.I)


def gate_for(task, proposed="review"):
    """The planner's gate, never lower than what undoing the task would cost ("Post the…" yes, "Draft a post" no)."""
    gate = proposed if proposed in GATES else "review"
    if gate == "code" and not re.search(r"\b(deploy|publish|release)\b", task, re.I):
        return "code"
    return "founder" if IRREVERSIBLE.search(task) or IRREVERSIBLE_VERB.search(task) else gate


def parse_plan(text):
    """Tim's plan lines → [{"ref", "owner", "task", "done_when", "after": [refs], "gate"}]."""
    nodes = []
    for line in (text or "").splitlines():
        match = PLAN_LINE.match(line)
        if not match:
            continue
        rest = match.group("rest")
        done = re.search(r"done when:\s*([^|]+)", rest, re.I)
        after = re.search(r"after:\s*([^|]+)", rest, re.I)
        gate = re.search(r"gate:\s*(\w+)", rest, re.I)
        eta = re.search(r"eta:\s*~?(\d+)", rest, re.I)
        refs = [r.strip().upper() for r in re.split(r"[,\s]+", after.group(1)) if re.match(r"^T\d+$", r.strip(), re.I)] if after else []
        task = match.group("task").strip().strip("*").strip()
        nodes.append({"ref": match.group("id").upper(), "owner": match.group("owner").strip().strip("@*").strip(),
                      "task": task, "done_when": done.group(1).strip() if done else "",
                      "after": refs, "gate": gate_for(task, (gate.group(1).lower() if gate else "review")),
                      "eta": max(2, min(480, int(eta.group(1)))) if eta else None})
    return nodes


def plan_prompt(startup, goal, team, memory=""):
    members = "\n".join(f"- {p.first} ({p.title}): {p.owns}" for p in team)
    return f"""You are Agent Tim, CEO of "{startup['name']}" ({startup['pitch']}). Turn this goal into a work graph for the \
team.

GOAL: {goal}

The team:
{members}

The current plan:
{startup.get('plan') or '(none yet)'}
{f"{chr(10)}{memory}{chr(10)}" if memory else ""}
Break the goal into 3–8 tasks. One line per task, exactly in this format:
T1 | <Owner first name> | <the task, concrete> | done when: <evidence in the result that can fail, e.g. "3 subject lines under 50 chars"> | after: - | gate: auto | eta: 20
Rules:
- after: the T-ids this task needs first (comma-separated), or "-". Tasks that don't need each other must NOT be chained: they run in parallel.
- gate: auto (cheap to redo), review (I check it), code (changes the product's code: Claude Code does it in the \
project folder and the tests check it), founder (anything public, sent to customers, money, or a deploy).
- eta: minutes the owner needs (the team works in minutes, never days).
- Each task belongs to the person whose area it is. No other text."""


def check_prompt(task, result):
    return f"""You are Agent Tim, CEO, checking a teammate's work before it's accepted. Be strict but fair.

Task: {task['task']}
Done when: {task['done_when']}

The result:
{result}

Judge only against "done when", using evidence in the result itself (saying "I did it" is not evidence). Reply with \
PASS or FAIL on the first line. If FAIL, add two lines:
Reason: <the specific thing missing or wrong>
Fix: <exactly what to change>"""


def parse_check(reply):
    """(passed, reason) from the checker's reply; an unreadable reply counts as a pass with a note."""
    text = (reply or "").strip()
    first = text.splitlines()[0].strip().strip("*#: ").upper() if text else ""
    if first.startswith("FAIL"):
        reason = re.search(r"reason:\s*(.+)", text, re.I)
        fix = re.search(r"fix:\s*(.+)", text, re.I)
        detail = (reason.group(1).strip() if reason else text[4:].strip()[:300]) + (f" Fix: {fix.group(1).strip()}" if fix else "")
        return False, detail.strip() or "It doesn't meet the done-when yet."
    return True, ""


def summary_prompt(startup, board, memory, room):
    def line(t):
        extra = {"blocked": f" (blocked: {t.get('feedback') or ''})", "approval": " (waiting for your approval)"}.get(t["status"], "")
        return f"- [{t['status']}] {t['owner']}: {t['task']}{extra}"
    tasks = "\n".join(line(t) for t in board[-30:]) or "(no tasks yet)"
    return f"""You are Agent Tim, CEO of "{startup['name']}". The founder asked for a summary of where things stand.

Tasks:
{tasks}

{memory}

Recent conversation:
{room}

Write it in markdown with exactly these sections, short bullets:
## Summary
<3–4 sentences: what got done, what's in progress, how close the goal is>
## Decisions
- <decision>
## Action items
- **<Owner first name>**: <task> — ETA: <in N min | in N h | after <Name>'s <task>>
## Needs you
- <approvals waiting, blocked tasks and what would unblock them, or "- Nothing right now">
## Open questions
- <question> (or "- None")"""


def layers(tasks):
    """Each task's column in the graph view: 0 for tasks with no dependencies, else 1 + the deepest dependency."""
    by_id = {t["id"]: t for t in tasks}
    depth = {}

    def visit(t, seen=()):
        if t["id"] in depth:
            return depth[t["id"]]
        deps = [by_id[d] for d in t.get("deps") or [] if d in by_id and d not in seen]
        depth[t["id"]] = 0 if not deps else 1 + max(visit(d, seen + (t["id"],)) for d in deps)
        return depth[t["id"]]

    for t in tasks:
        visit(t)
    return depth


def deps_of(task):
    deps = json.loads(task.get("deps") or "[]") if isinstance(task.get("deps"), str) else (task.get("deps") or [])
    if task.get("depends_on") and task["depends_on"] not in deps:
        deps = deps + [task["depends_on"]]
    return deps
