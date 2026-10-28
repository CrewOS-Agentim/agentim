"""Startup Mode: a team of agents that meets on a random 10–30 minute schedule to improve your startup.

Each round a few teammates (least recently heard from) read the idea, the living plan and the recent
team discussion, then post concrete improvements and hand questions to each other. The Chief of
Staff folds everything into the plan and the owner gets a short summary in their chat.
"""

import logging
import random
import sqlite3
import threading
import time
from dataclasses import dataclass

from .llm import LLMError

log = logging.getLogger("agentim.startup")


@dataclass(frozen=True)
class Role:
    key: str
    name: str
    emoji: str
    focus: str


TEAM = [
    Role("sales", "Sales", "💼", "who buys first, the pitch, pricing, objections, the first 10 customers and the pipeline"),
    Role("bizdev", "Business Development", "🤝", "partnerships, distribution channels, integrations and deals that unlock customers"),
    Role("marketing", "Marketing & Social", "📣", "positioning, messaging, content, social channels, community and launch moments"),
    Role("automation", "Marketing Automation", "⚙️", "funnels, email/SMS sequences, lead scoring, tooling and metrics that run on their own"),
    Role("engineering", "Engineering", "🛠️", "architecture, build-vs-buy, the smallest shippable version, cost, risk and speed"),
    Role("product", "Product", "🧭", "the problem, the core user, the MVP scope, success metrics and what to cut"),
    Role("design", "Design", "🎨", "first impression, onboarding, the key screens, brand and trust"),
    Role("finance", "Finance & Fundraising", "💰", "unit economics, runway, pricing math, and when and how to raise"),
]
CHIEF = Role("chief", "Chief of Staff", "🗂️", "keeps the startup plan up to date")
ROLES = {r.key: r for r in TEAM + [CHIEF]}

PLAN_TEMPLATE = """# {idea_title}

## Top 3 priorities
1. (to be decided by the team)

## By area
{areas}

## Experiments this week

## Open questions
"""


def initial_plan(idea):
    title = idea.strip().split("\n")[0][:80]
    areas = "\n".join(f"### {r.emoji} {r.name}\n- …" for r in TEAM)
    return PLAN_TEMPLATE.format(idea_title=title, areas=areas)


class StartupStore:
    """One startup per gateway: the idea, schedule, plan and the team's messages."""

    def __init__(self, db: sqlite3.Connection, lock: threading.Lock):
        self.db, self.lock = db, lock
        with self.lock, self.db:
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup (
                id INTEGER PRIMARY KEY CHECK (id = 1), idea TEXT, enabled INTEGER, plan TEXT,
                min_minutes INTEGER, max_minutes INTEGER, next_run REAL, rounds INTEGER,
                notify_channel TEXT, notify_chat TEXT, updated REAL)""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_messages (
                round INTEGER, role TEXT, content TEXT, ts REAL)""")

    def get(self):
        with self.lock:
            row = self.db.execute("""SELECT idea, enabled, plan, min_minutes, max_minutes, next_run, rounds,
                notify_channel, notify_chat, updated FROM startup WHERE id = 1""").fetchone()
        if not row:
            return None
        keys = ["idea", "enabled", "plan", "min_minutes", "max_minutes", "next_run", "rounds",
                "notify_channel", "notify_chat", "updated"]
        state = dict(zip(keys, row))
        state["enabled"] = bool(state["enabled"])
        return state

    def save(self, **fields):
        state = self.get() or {"idea": "", "enabled": False, "plan": "", "min_minutes": 10, "max_minutes": 30,
                               "next_run": None, "rounds": 0, "notify_channel": None, "notify_chat": None}
        state.update(fields)
        state["updated"] = time.time()
        with self.lock, self.db:
            self.db.execute("""INSERT OR REPLACE INTO startup (id, idea, enabled, plan, min_minutes, max_minutes,
                next_run, rounds, notify_channel, notify_chat, updated) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                            (state["idea"], int(state["enabled"]), state["plan"], state["min_minutes"],
                             state["max_minutes"], state["next_run"], state["rounds"], state["notify_channel"],
                             state["notify_chat"], state["updated"]))
        return state

    def add_message(self, round_no, role, content):
        with self.lock, self.db:
            self.db.execute("INSERT INTO startup_messages VALUES (?, ?, ?, ?)", (round_no, role, content, time.time()))

    def messages(self, limit=30):
        with self.lock:
            rows = self.db.execute("SELECT round, role, content, ts FROM startup_messages ORDER BY ts DESC, rowid DESC LIMIT ?",
                                   (limit,)).fetchall()
        return [{"round": r, "role": role, "content": c, "ts": ts} for r, role, c, ts in reversed(rows)]

    def last_spoke(self):
        """{role_key: last round it spoke in}."""
        with self.lock:
            rows = self.db.execute("SELECT role, MAX(round) FROM startup_messages GROUP BY role").fetchall()
        return dict(rows)

    def clear_messages(self):
        with self.lock, self.db:
            self.db.execute("DELETE FROM startup_messages")


def pick_speakers(last_spoke, count=3, rng=random):
    """The teammates heard from least recently go first; ties are broken randomly."""
    team = list(TEAM)
    rng.shuffle(team)
    team.sort(key=lambda r: last_spoke.get(r.key, -1))
    return team[:count]


def role_prompt(role, idea, plan, discussion):
    return f"""You are the {role.name} lead on a small founding team. You care about {role.focus}.

The startup idea:
{idea}

The current plan:
{plan}

Recent team discussion:
{discussion or "(nobody has spoken yet)"}

Write your update for this round, under 180 words:
1. One sharp observation about the idea that only a {role.name} lead would make.
2. Two or three concrete improvements in YOUR area ({role.focus}): who, what, how to test it this week.
3. One question or hand-off to another teammate, starting with @Role (e.g. @Design, @Sales).
React to teammates (agree, push back, or build on one point), but never repeat or re-list their
suggestions and don't repeat the plan back. Stay in your lane. Plain text with short bullets."""


def chief_prompt(idea, plan, round_messages):
    updates = "\n\n".join(f"{ROLES[m['role']].emoji} {ROLES[m['role']].name}:\n{m['content']}" for m in round_messages)
    return f"""You are the Chief of Staff. Keep the startup plan short, concrete and current.

Startup idea:
{idea}

Current plan:
{plan}

This round's updates from the team:
{updates}

Reply with exactly two parts:
PLAN:
<the full updated plan in markdown with the sections: Top 3 priorities, By area (one short bullet list per area that changed), Experiments this week, Open questions. Keep what still holds, replace what changed, stay under 400 words.>
SUMMARY:
<2–3 sentences for the founder: what the team decided this round and the single next action.>"""


def split_chief(output, fallback_plan):
    if "SUMMARY:" in output:
        plan_part, summary = output.split("SUMMARY:", 1)
    else:
        plan_part, summary = output, ""
    plan = plan_part.replace("PLAN:", "", 1).strip() or fallback_plan
    return plan, summary.strip()


class StartupMode:
    def __init__(self, gateway, store: StartupStore, rng=random, clock=time.time, speakers_per_round=3):
        self.gateway, self.store = gateway, store
        self.rng, self.clock = rng, clock
        self.speakers_per_round = speakers_per_round
        self.notify = None  # callable(channel, chat_id, text), set by __main__ once channels exist
        self.running = threading.Lock()

    # ---- control

    def start(self, idea, channel=None, chat_id=None, min_minutes=10, max_minutes=30):
        idea = idea.strip()
        if not idea:
            raise ValueError("Tell me the startup idea first.")
        min_minutes, max_minutes = sorted((max(1, int(min_minutes)), max(1, int(max_minutes))))
        current = self.store.get()
        fresh = not current or current["idea"] != idea
        if fresh:
            self.store.clear_messages()
        state = self.store.save(
            idea=idea, enabled=True, plan=initial_plan(idea) if fresh else current["plan"],
            min_minutes=min_minutes, max_minutes=max_minutes, rounds=0 if fresh else current["rounds"],
            next_run=self.clock() + 60,  # first round about a minute from now
            notify_channel=channel or (current or {}).get("notify_channel"),
            notify_chat=chat_id or (current or {}).get("notify_chat"))
        return state

    def stop(self):
        return self.store.save(enabled=False, next_run=None)

    def schedule_next(self, state=None):
        state = state or self.store.get()
        minutes = self.rng.uniform(state["min_minutes"], state["max_minutes"])
        return self.store.save(next_run=self.clock() + minutes * 60)

    # ---- rounds

    def due(self):
        state = self.store.get()
        return bool(state and state["enabled"] and state["next_run"] and self.clock() >= state["next_run"])

    def run_round(self):
        """Runs one meeting. Returns the summary text, or None when there's nothing to do."""
        if not self.running.acquire(blocking=False):
            return None
        try:
            state = self.store.get()
            if not state or not state["idea"]:
                return None
            round_no = state["rounds"] + 1
            router = self.gateway.router()
            discussion = "\n".join(f"{ROLES[m['role']].emoji} {ROLES[m['role']].name}: {m['content']}"
                                   for m in self.store.messages(limit=12) if m["role"] in ROLES)
            posted = []
            for role in pick_speakers(self.store.last_spoke(), self.speakers_per_round, self.rng):
                prompt = role_prompt(role, state["idea"], state["plan"], discussion)
                reply = self._ask(router, prompt)
                if not reply:
                    continue
                self.store.add_message(round_no, role.key, reply)
                message = {"round": round_no, "role": role.key, "content": reply}
                posted.append(message)
                discussion += f"\n{role.emoji} {role.name}: {reply}"
            if not posted:
                self.schedule_next(state)
                return None
            chief = self._ask(router, chief_prompt(state["idea"], state["plan"], posted)) or ""
            plan, summary = split_chief(chief, state["plan"])
            summary = summary or "The team posted new ideas; see the plan."
            self.store.add_message(round_no, CHIEF.key, summary)
            state = self.store.save(plan=plan, rounds=round_no)
            self.schedule_next(state)
            text = self.digest(round_no, posted, summary)
            if self.notify and state.get("notify_channel") and state.get("notify_chat"):
                try:
                    self.notify(state["notify_channel"], state["notify_chat"], text)
                except Exception:
                    log.exception("startup: couldn't send the round summary")
            return text
        finally:
            self.running.release()

    # Routed by what the work is, not by the prompt text: prompts mention teammates as @Role,
    # which the router would otherwise read as "use the model called @Design".
    ROUTING_HINT = "Analyze the business strategy and plan the next steps step by step."

    def _ask(self, router, prompt):
        try:
            decision = router.route(self.ROUTING_HINT)
        except Exception as e:
            log.warning("startup: no model: %s", e)
            return None
        for model in [decision.model] + decision.fallbacks[:1]:
            try:
                return self.gateway.llm.complete(model, "", [{"role": "user", "content": prompt}]).strip()
            except LLMError as e:
                log.warning("startup: %s failed: %s", model.alias, e)
        return None

    @staticmethod
    def digest(round_no, posted, summary):
        who = " ".join(ROLES[m["role"]].emoji for m in posted)
        return f"🚀 *Startup round {round_no}* {who}\n\n{summary}\n\n_Send /startup to see the plan._"

    # ---- scheduler

    def loop(self, tick=30, sleep=time.sleep):
        while True:
            try:
                if self.due():
                    log.info("startup: round starting")
                    self.run_round()
            except Exception:
                log.exception("startup: round failed")
                try:
                    self.schedule_next()
                except Exception:
                    pass
            sleep(tick)

    def snapshot(self):
        state = self.store.get()
        if not state:
            return {"configured": False, "team": [r.__dict__ for r in TEAM]}
        return {"configured": True, **state, "now": self.clock(), "team": [r.__dict__ for r in TEAM],
                "roles": {k: {"name": r.name, "emoji": r.emoji} for k, r in ROLES.items()},
                "messages": self.store.messages(limit=40)}

    # ---- chat command: /startup [idea | now | off | plan]

    def command(self, channel, chat_id, arg):
        arg = arg.strip()
        state = self.store.get()
        if arg.lower() in ("off", "stop", "pause"):
            if not state:
                return "Startup Mode isn't on."
            self.stop()
            return "⏸️ Startup Mode paused. `/startup on` resumes it."
        if arg.lower() in ("on", "resume"):
            if not state or not state["idea"]:
                return "Tell me the idea first: `/startup <your idea>`"
            self.start(state["idea"], channel, chat_id, state["min_minutes"], state["max_minutes"])
            return "▶️ Startup Mode is back on. The team meets every 10–30 minutes."
        if arg.lower() == "now":
            if not state or not state["idea"]:
                return "Tell me the idea first: `/startup <your idea>`"
            threading.Thread(target=self.run_round, daemon=True).start()
            return "🧑‍🤝‍🧑 Calling the team in now. The summary will land here in a few minutes."
        if arg and arg.lower() != "plan":
            self.start(arg, channel, chat_id)
            names = ", ".join(f"{r.emoji} {r.name}" for r in TEAM)
            return (f"🚀 *Startup Mode is on.* Your team: {names}.\n\nThey'll meet every 10–30 minutes, build on each "
                    "other's ideas, and I'll send you a short summary after each round. "
                    "`/startup` shows the plan · `/startup now` meets right away · `/startup off` pauses.")
        if not state or not state["idea"]:
            return ("🚀 *Startup Mode*: a team of agents (sales, bizdev, marketing, automation, engineering, product, "
                    "design, finance) that meets every 10–30 minutes to improve your startup.\n\n"
                    "Start it with `/startup <your idea in a sentence or two>`.")
        status = "on" if state["enabled"] else "paused"
        when = ""
        if state["enabled"] and state["next_run"]:
            when = f" · next meeting in ~{max(1, int((state['next_run'] - self.clock()) / 60))} min"
        return f"🚀 Startup Mode is {status} · {state['rounds']} rounds so far{when}\n\n{state['plan']}"
