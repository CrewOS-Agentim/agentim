"""Agent Tim runs the loop: every minute he checks each project, keeps the work moving, asks owners for ETAs (in
minutes), chases anything past its ETA, reminds the founder about approvals, and posts a summary every N minutes.

Nothing here runs on days: every limit and rhythm is in minutes.
"""

import logging
import os
import re
import time

log = logging.getLogger("agentim.supervisor")

EVERY_SECONDS = 60
SUMMARY_EVERY_MINUTES = int(os.environ.get("AGENTIM_SUMMARY_EVERY_MINUTES", "120"))
APPROVAL_REMINDER_MINUTES = 15
GRACE_SECONDS = 60          # a task is late a minute after its ETA
MAX_SLIPS = 3               # after this many missed ETAs, the founder hears about it
ETA_ASKS_PER_TICK = 4


def parse_minutes(text, default=None):
    """'25', '~25 min', 'about 1.5 hours' → minutes (2–480)."""
    match = re.search(r"(\d+(?:\.\d+)?)\s*(h|hr|hrs|hour|hours)?", text or "", re.I)
    if not match:
        return default
    value = float(match.group(1)) * (60 if match.group(2) else 1)
    return max(2, min(480, int(round(value))))


class Supervisor:
    def __init__(self, mode):
        self.mode = mode
        self.last_tick = 0
        self.last_summary = {}      # startup id → when Tim last summarized (or when he started watching)
        self.reminded = {}          # task id → when the founder was last reminded about it

    @property
    def work(self):
        return self.mode.work

    def maybe_tick(self, now=None):
        now = now or time.time()
        if now - self.last_tick < EVERY_SECONDS:
            return False
        self.last_tick = now
        for startup in self.mode.store.all():
            if startup["status"] != "running":
                continue
            try:
                self.check(startup["id"], now)
            except Exception:
                log.exception("supervisor: check failed")
        return True

    def check(self, startup_id, now=None):
        """One pass of the loop for one project. Returns what Tim did (for the tests and the log)."""
        now = now or time.time()
        startup = self.mode.store.get(startup_id)
        did = {"kicked": False, "etas": [], "late": [], "reminded": [], "summary": False}
        tasks = self.work.board(startup_id)["tasks"]
        if not tasks:
            return did
        people = self.people(startup)
        # 1. Keep the loop running: ready work that nobody started.
        if any(t["ready"] for t in tasks) and startup_id not in self.work.running:
            did["kicked"] = self.work.kick(startup_id)
        # 2. Every open task gets an ETA, in minutes, from its owner.
        lines = []
        for t in [t for t in tasks if t["status"] in ("todo", "doing") and not t.get("eta_minutes")][:ETA_ASKS_PER_TICK]:
            person = people.get(t["owner"])
            minutes = self.ask_eta(startup, t, person)
            self.work.store.update(t["id"], eta_minutes=minutes, eta_first=t.get("eta_first") or minutes, eta=f"in {minutes} min")
            did["etas"].append((t["owner"], minutes))
            lines.append(f"{person.first if person else t['owner']}: ~{minutes} min for “{t['task'][:60]}”")
        if lines:
            self.say(startup, "⏱️ **ETAs** (I asked the team)\n" + "\n".join(f"- {line}" for line in lines))
        # 3. Chase anything past its ETA: a new ETA, and the founder hears after too many slips.
        late_lines = []
        for t in tasks:
            if t["status"] != "doing" or not t.get("started") or not t.get("eta_minutes"):
                continue
            due = t["started"] + t["eta_minutes"] * 60
            if now < due + GRACE_SECONDS or (t.get("pinged") and now - t["pinged"] < max(300, t["eta_minutes"] * 30)):
                continue
            person = people.get(t["owner"])
            over = int((now - due) / 60)
            more = self.ask_eta(startup, t, person, late_by=over)
            slips = (t.get("slips") or 0) + 1
            self.work.store.update(t["id"], eta_minutes=int((now - t["started"]) / 60) + more, slips=slips, pinged=now)
            did["late"].append((t["owner"], over, more))
            name = person.first if person else t["owner"]
            late_lines.append(f"{name} is {over} min past the ETA on “{t['task'][:60]}”: new ETA ~{more} min"
                              + (" ⚠️ (slipped 3 times: founder, take a look)" if slips == MAX_SLIPS else ""))
        if late_lines:
            self.say(startup, "⏰ **Behind schedule**\n" + "\n".join(f"- {line}" for line in late_lines))
        # 4. Approvals waiting on the founder.
        waiting = [t for t in tasks if t["status"] in ("approval", "blocked")
                   and now - (self.reminded.get(t["id"]) or (t.get("finished") or t.get("started") or now))
                   >= APPROVAL_REMINDER_MINUTES * 60]
        if waiting:
            for t in waiting:
                self.reminded[t["id"]] = now
            did["reminded"] = [t["id"] for t in waiting]
            self.say(startup, "🙋 **Waiting for you**\n" + "\n".join(
                f"- {'approve' if t['status'] == 'approval' else 'unblock'}: “{t['task'][:70]}”" for t in waiting))
        # 5. A summary every N minutes, when something happened since the last one.
        last = self.last_summary.setdefault(startup_id, now)
        changed = any((t.get("finished") or 0) > last or (t.get("started") or 0) > last for t in tasks)
        if now - last >= SUMMARY_EVERY_MINUTES * 60 and changed:
            self.last_summary[startup_id] = now
            result = self.work.summarize(startup_id)
            did["summary"] = True
            self.notify(startup, result["summary"])
        return did

    def people(self, startup):
        from .startup import CEO, people_of
        return {**people_of(startup), CEO.key: CEO}

    def ask_eta(self, startup, task, person, late_by=None):
        """The owner's estimate in minutes (their own model); 15 if no model answers."""
        if not person:
            return task.get("eta_minutes") or 15
        question = (f"You're {late_by} minutes past your ETA. How many more minutes until it's done?" if late_by is not None
                    else "How many minutes until it's done?")
        reply = self.mode._ask(
            f"You are {person.name}, {person.title} at \"{startup['name']}\". Agent Tim (the CEO) is checking progress.\n"
            f"Your task: {task['task']}\n" + (f"Done when: {task['done_when']}\n" if task.get("done_when") else "")
            + f"{question} Reply with only a number of minutes (the team works in minutes, never days).",
            f"Startup · {startup['name']} · ETA from {person.first}", model=self.mode.model_for(person)
            if hasattr(person, "model") else None)
        return parse_minutes(reply, default=15)

    def say(self, startup, text):
        self.mode.store.add_message(startup["id"], max(startup["rounds"], 1), "ceo", text)

    def notify(self, startup, text):
        if self.mode.notify and startup.get("notify_channel") and startup.get("notify_chat"):
            try:
                self.mode.notify(startup["notify_channel"], startup["notify_chat"], f"📋 *{startup['name']}*\n\n{text}")
            except Exception:
                log.exception("supervisor: couldn't send the summary")


def schedule(tasks, now=None):
    """The Gantt chart, in minutes: for each task the baseline (first ETAs, all starting at the goal's start) and the
    forecast (actual starts/finishes, current ETAs, never earlier than now). Returns {task id: {...}}."""
    now = now or time.time()
    by_id = {t["id"]: t for t in tasks}
    origin = min((t.get("created") or now for t in tasks), default=now)
    base, fore = {}, {}

    def deps(t):
        return [d for d in (t.get("deps") or []) if d in by_id]

    def plan(t, table, forecast, seen=()):
        if t["id"] in table:
            return table[t["id"]]
        after = max((plan(by_id[d], table, forecast, seen + (t["id"],))[1] for d in deps(t) if d not in seen), default=origin)
        eta = (t.get("eta_minutes") if forecast else t.get("eta_first") or t.get("eta_minutes")) or 15
        if forecast and t.get("started"):
            start = t["started"]
            end = t.get("finished") or max(start + eta * 60, now)
        elif forecast and t["status"] in ("done", "cancelled") and t.get("finished"):
            start, end = t.get("started") or t["finished"], t["finished"]
        else:
            start = max(after, now) if forecast and t["status"] not in ("done", "cancelled") else after
            end = start + eta * 60
        table[t["id"]] = (start, end)
        return start, end

    for t in tasks:
        plan(t, base, False)
        plan(t, fore, True)
    return {tid: {"planned_start": (base[tid][0] - origin) / 60, "planned_end": (base[tid][1] - origin) / 60,
                  "start": (fore[tid][0] - origin) / 60, "end": (fore[tid][1] - origin) / 60} for tid in by_id} , origin
