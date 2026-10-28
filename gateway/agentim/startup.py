"""Startup Mode: run your startups with a team of agents who act like real employees.

Each startup starts as a pitch. Agent Tim interviews the founder with follow-up questions
(generated with the "Validate Your Startup" skill), then a team (PM, designer, engineer,
marketer, sales, bizdev, automation, finance) meets on a random 10–30 minute schedule. The
people who spoke least recently go first; each reads the pitch, the founder's answers, the plan
and the recent discussion, does their job and hands off to colleagues by name. Tim (CEO) folds
the meeting into a living plan and sends the founder a short summary.
"""

import json
import logging
import random
import re
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass

from .llm import LLMError

log = logging.getLogger("agentim.startup")


@dataclass(frozen=True)
class Person:
    key: str
    name: str
    title: str
    emoji: str
    owns: str

    @property
    def first(self):
        return self.name.split()[0]


TEAM = [
    Person("product", "Maya Chen", "Product Manager", "🧭", "the problem, the core user, MVP scope, success metrics and what to cut"),
    Person("design", "Leo Park", "Designer", "🎨", "first impression, onboarding, the key screens, brand and trust"),
    Person("engineering", "Noah Patel", "Engineering Lead", "🛠️", "architecture, build vs. buy, the smallest shippable version, cost and risk"),
    Person("marketing", "Ava Brooks", "Marketing & Social Lead", "📣", "positioning, messaging, content, social channels, community and launch"),
    Person("automation", "Sam Rivera", "Marketing Automation", "⚙️", "funnels, email/SMS sequences, lead scoring and tooling that runs on its own"),
    Person("sales", "Zoe Kim", "Head of Sales", "💼", "the first 10 customers, the pitch, pricing, objections and the pipeline"),
    Person("bizdev", "Omar Haddad", "Business Development", "🤝", "partnerships, distribution channels, integrations and deals"),
    Person("finance", "Grace Liu", "Finance & Fundraising", "💰", "unit economics, runway, pricing math, and when and how to raise"),
]
CEO = Person("ceo", "Agent Tim", "CEO", "🐙", "the plan, priorities and keeping the founder in the loop")
PEOPLE = {p.key: p for p in TEAM + [CEO]}
MAX_TEAM = 12

# Suggestions for hiring beyond the default team (the Mac app's "Hire" menu).
ROLE_PRESETS = [
    {"title": "CTO", "emoji": "🧠", "owns": "technical vision, architecture decisions, hiring engineers and technical risk"},
    {"title": "Customer Success", "emoji": "🫶", "owns": "onboarding customers, retention, support and turning users into advocates"},
    {"title": "Growth Lead", "emoji": "📈", "owns": "acquisition experiments, referral loops, activation and the weekly growth metric"},
    {"title": "Data Scientist", "emoji": "📊", "owns": "metrics, dashboards, experiment analysis and pricing data"},
    {"title": "Head of Operations", "emoji": "📦", "owns": "logistics, suppliers, fulfilment, costs and processes"},
    {"title": "Legal & Compliance", "emoji": "⚖️", "owns": "contracts, terms, privacy, regulation and company setup"},
    {"title": "Recruiter", "emoji": "🧲", "owns": "who to hire next, job posts, sourcing and interview loops"},
    {"title": "Community Manager", "emoji": "💬", "owns": "community, events, user stories and early-adopter relationships"},
]


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "person"


def person_dict(person):
    return {"key": person.key, "name": person.name, "title": person.title, "emoji": person.emoji, "owns": person.owns}


def normalize_member(raw, taken):
    """Validates one employee from the app or chat and gives them a unique key."""
    name = " ".join(str(raw.get("name", "")).split())
    title = " ".join(str(raw.get("title", "")).split())
    if not (2 <= len(name) <= 60) or not (2 <= len(title) <= 60):
        raise ValueError("Every employee needs a name and a title.")
    if slug(name) == "agent-tim":
        raise ValueError("Agent Tim is the CEO and is always on the team.")
    owns = " ".join(str(raw.get("owns") or "").split())[:300] or f"everything a {title} is responsible for"
    emoji = (str(raw.get("emoji") or "").strip() or "🧑‍💼")[:4]
    key = slug(str(raw.get("key") or "")) or slug(name.split()[0] + "-" + title)
    base, n = key, 2
    while key in taken or key == CEO.key:
        key, n = f"{base}-{n}", n + 1
    taken.add(key)
    return {"key": key, "name": name, "title": title, "emoji": emoji, "owns": owns}


def normalize_team(members):
    if not isinstance(members, list) or not members:
        raise ValueError("A startup needs at least one employee besides Agent Tim.")
    if len(members) > MAX_TEAM:
        raise ValueError(f"Keep the team to {MAX_TEAM} people or fewer.")
    taken = set()
    return [normalize_member(m, taken) for m in members]


def team_of(startup):
    """This startup's employees (the default team for startups created before teams were editable)."""
    members = (startup or {}).get("team") or []
    return [Person(**m) for m in members] or list(TEAM)


def people_of(startup):
    """Everyone who can appear in the team room: current team, former employees and the CEO."""
    people = {m["key"]: Person(**m) for m in (startup or {}).get("alumni") or []}
    people.update({p.key: p for p in team_of(startup)})
    people[CEO.key] = CEO
    return people

# Used when no model answers: five YC-partner questions, then five co-founder questions.
FALLBACK_QUESTIONS = [
    "Who desperately needs this (a specific person and situation), and how do you know?",
    "What do they do today instead, and what does that cost them?",
    "What do you understand about this problem that most smart people don't?",
    "Who pays, how much, how often, and what's the rough math to $1M a year?",
    "What single metric will you grow every week, and what is it today?",
    "Why are you the right founders for this: what's your unfair advantage?",
    "Are you full-time on this? How many months of runway do you have?",
    "Who builds, who sells, and who decides when you disagree?",
    "What ships in the next 90 days, and who are the first 10 customers?",
    "What would make you stop or pivot, and when will you check?",
]


def initial_plan(name, team=None):
    areas = "\n".join(f"### {p.emoji} {p.title} ({p.first})\n- …" for p in (team or TEAM))
    return f"# {name}\n\n## Top 3 priorities\n1. (the team will decide)\n\n## By area\n{areas}\n\n## Experiments this week\n\n## Open questions\n"


def name_from_pitch(pitch):
    first = re.split(r"[.!?\n]", pitch.strip(), maxsplit=1)[0]
    words = first.split()
    return " ".join(words[:6]) + ("…" if len(words) > 6 else "") or "Untitled startup"


def parse_questions(text, limit=10):
    """Numbered or bulleted lines → questions. Keeps only the question part: small models sometimes
    write "**What are you making?** Leafy is…" (a heading plus their own made-up answer)."""
    questions = []
    for line in text.splitlines():
        match = re.match(r"^\s*(?:\d+[.)]|[-•]|\*(?!\*))\s+(.+)$", line)
        if not match:
            continue
        item = match.group(1).strip()
        # Drop a lens label the model may add: "YC Partner**: …", "**Co-founder:** …", "(YC) …".
        item = re.sub(r"^(?:\*\*)?\(?[A-Za-z][\w -]{1,20}\)?(?:\*\*)?\s*:\s*(?:\*\*)?\s*(?=\S)", "", item)
        item = re.sub(r"^\([A-Za-z][\w -]{1,20}\)\s*", "", item)
        bold = re.match(r"^\*\*(.+?\?)\*\*", item)
        question = bold.group(1) if bold else item.split("?")[0] + "?" if "?" in item else ""
        question = question.strip(" *")
        if len(question) >= 6:  # "Why now?" counts
            questions.append(question)
    return questions[:limit]


def pick_speakers(last_spoke, count=3, rng=random, team=None):
    """Whoever spoke least recently goes first; ties broken randomly."""
    team = list(team or TEAM)
    rng.shuffle(team)
    team.sort(key=lambda p: last_spoke.get(p.key, -1))
    return team[:count]


def brief(startup):
    answers = "\n".join(f"Q: {q}\nA: {a}" for q, a in zip(startup["questions"], startup["answers"]) if a)
    return f"Startup: {startup['name']}\nPitch: {startup['pitch']}" + (f"\n\nFounder's answers:\n{answers}" if answers else "")


def person_prompt(person, startup, discussion, team=None):
    colleagues = ", ".join(f"{p.first} ({p.title})" for p in (team or TEAM) if p.key != person.key) or "none yet"
    return f"""You are {person.name}, {person.title} at "{startup['name']}", an early-stage startup. You are a real, \
experienced employee: you own {person.owns}. Your colleagues: {colleagues}. The CEO is Agent Tim.

{brief(startup)}

The current plan:
{startup['plan']}

Recent team discussion:
{discussion or "(this is the team's first meeting)"}

Post your update for this meeting, under 180 words, in first person like you would in the team Slack:
1. What you did or decided since last time (be specific and realistic).
2. Two or three concrete next moves in YOUR area: what, by when, how you'll know it worked.
3. One ask for a colleague, by first name (e.g. "@Leo, can you…").
React to colleagues (agree, push back, or build on one point) but never repeat or re-list their suggestions.
Do NOT write the company plan or other people's tasks: Agent Tim keeps the plan.
Remember: you are {person.first}, the {person.title}. Everything you propose is about {person.owns}.
Short bullets, no headings, start with "{person.first} here:"."""


def ceo_prompt(startup, posted, people=None):
    people = people or PEOPLE
    updates = "\n\n".join(f"{people[m['role']].name} ({people[m['role']].title}):\n{m['content']}" for m in posted)
    return f"""You are Agent Tim, CEO of "{startup['name']}". Keep the company plan short, concrete and current.

{brief(startup)}

Current plan:
{startup['plan']}

Updates from this meeting:
{updates}

Reply with exactly two parts:
PLAN:
<the full updated plan in markdown with: Top 3 priorities, By area (short bullets per area that changed, with the owner's first name), Experiments this week, Open questions. Keep what still holds, replace what changed, under 400 words.>
SUMMARY:
<2–3 sentences for the founder: what the team decided and the single next action, with the owner's name.>"""


def split_ceo(output, fallback_plan):
    """Splits Tim's reply into the plan and the founder summary; models format the labels loosely
    ("SUMMARY:", "**Summary**", "### Summary")."""
    parts = re.split(r"^[#*\s]*summary[*\s]*:?[*\s]*$|\**summary\**\s*:", output, maxsplit=1,
                     flags=re.IGNORECASE | re.MULTILINE)
    plan_part, summary = (parts[0], parts[1]) if len(parts) == 2 else (output, "")
    plan = re.sub(r"^[#*\s]*plan[*\s]*:?[*\s]*\n", "", plan_part, count=1,
                  flags=re.IGNORECASE | re.MULTILINE).strip() or fallback_plan
    return plan, summary.strip().strip("*").strip()


class StartupStore:
    """Startups, their interviews, plans and team messages, in the gateway's SQLite."""

    COLUMNS = ["id", "name", "pitch", "questions", "answers", "status", "plan", "min_minutes", "max_minutes",
               "next_run", "rounds", "notify_channel", "notify_chat", "created", "updated", "team", "alumni"]
    JSON_COLUMNS = ("questions", "answers", "team", "alumni")

    def __init__(self, db: sqlite3.Connection, lock: threading.Lock):
        self.db, self.lock = db, lock
        with self.lock, self.db:
            self.db.execute("""CREATE TABLE IF NOT EXISTS startups (
                id TEXT PRIMARY KEY, name TEXT, pitch TEXT, questions TEXT, answers TEXT, status TEXT, plan TEXT,
                min_minutes INTEGER, max_minutes INTEGER, next_run REAL, rounds INTEGER,
                notify_channel TEXT, notify_chat TEXT, created REAL, updated REAL)""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_team_messages (
                startup_id TEXT, round INTEGER, role TEXT, content TEXT, ts REAL)""")
            self.db.execute("CREATE INDEX IF NOT EXISTS startup_team_messages_id ON startup_team_messages (startup_id, ts)")
            # Databases from before editable teams: add the new columns in place.
            existing = {row[1] for row in self.db.execute("PRAGMA table_info(startups)")}
            for column in ("team", "alumni"):
                if column not in existing:
                    self.db.execute(f"ALTER TABLE startups ADD COLUMN {column} TEXT")

    def _row(self, row):
        if not row:
            return None
        s = dict(zip(self.COLUMNS, row))
        for column in self.JSON_COLUMNS:
            s[column] = json.loads(s[column] or "[]")
        return s

    def get(self, startup_id):
        with self.lock:
            row = self.db.execute(f"SELECT {', '.join(self.COLUMNS)} FROM startups WHERE id = ?", (startup_id,)).fetchone()
        return self._row(row)

    def all(self):
        with self.lock:
            rows = self.db.execute(f"SELECT {', '.join(self.COLUMNS)} FROM startups ORDER BY created").fetchall()
        return [self._row(r) for r in rows]

    def save(self, startup):
        startup["updated"] = time.time()
        startup.setdefault("team", [])
        startup.setdefault("alumni", [])
        values = [json.dumps(startup[c]) if c in self.JSON_COLUMNS else startup[c] for c in self.COLUMNS]
        with self.lock, self.db:
            self.db.execute(f"INSERT OR REPLACE INTO startups ({', '.join(self.COLUMNS)}) VALUES ({', '.join('?' * len(self.COLUMNS))})",
                            values)
        return startup

    def delete(self, startup_id):
        with self.lock, self.db:
            self.db.execute("DELETE FROM startups WHERE id = ?", (startup_id,))
            self.db.execute("DELETE FROM startup_team_messages WHERE startup_id = ?", (startup_id,))

    def add_message(self, startup_id, round_no, role, content):
        with self.lock, self.db:
            self.db.execute("INSERT INTO startup_team_messages VALUES (?, ?, ?, ?, ?)",
                            (startup_id, round_no, role, content, time.time()))

    def messages(self, startup_id, limit=40):
        with self.lock:
            rows = self.db.execute("""SELECT round, role, content, ts FROM startup_team_messages WHERE startup_id = ?
                ORDER BY ts DESC, rowid DESC LIMIT ?""", (startup_id, limit)).fetchall()
        return [{"round": r, "role": role, "content": c, "ts": ts} for r, role, c, ts in reversed(rows)]

    def last_spoke(self, startup_id):
        with self.lock:
            rows = self.db.execute("SELECT role, MAX(round) FROM startup_team_messages WHERE startup_id = ? GROUP BY role",
                                   (startup_id,)).fetchall()
        return dict(rows)

    def interviewing(self, channel, chat_id):
        """The startup whose follow-up questions are being answered in this chat, if any."""
        return next((s for s in self.all() if s["status"] == "interview"
                     and s["notify_channel"] == channel and s["notify_chat"] == str(chat_id)), None)


class StartupMode:
    def __init__(self, gateway, store: StartupStore, rng=random, clock=time.time, speakers_per_round=3):
        self.gateway, self.store = gateway, store
        self.rng, self.clock = rng, clock
        self.speakers_per_round = speakers_per_round
        self.notify = None  # callable(channel, chat_id, text), set by __main__
        self.locks = {}
        self.locks_guard = threading.Lock()

    # ---- creating a startup: pitch → follow-up questions → team

    def create(self, pitch, name=None, channel=None, chat_id=None, min_minutes=10, max_minutes=30, team=None):
        pitch = pitch.strip()
        if len(pitch) < 10:
            raise ValueError("Tell me the pitch in a sentence or two.")
        min_minutes, max_minutes = sorted((max(1, int(min_minutes)), max(1, int(max_minutes))))
        name = (name or "").strip() or name_from_pitch(pitch)
        members = normalize_team(team) if team else [person_dict(p) for p in TEAM]
        startup = {
            "id": uuid.uuid4().hex[:12], "name": name, "pitch": pitch, "questions": self.follow_up_questions(pitch),
            "answers": [], "status": "interview", "plan": initial_plan(name, [Person(**m) for m in members]),
            "team": members, "alumni": [], "min_minutes": min_minutes,
            "max_minutes": max_minutes, "next_run": None, "rounds": 0, "notify_channel": channel,
            "notify_chat": str(chat_id) if chat_id is not None else None, "created": self.clock(), "updated": self.clock(),
        }
        return self.store.save(startup)

    def follow_up_questions(self, pitch):
        """Tim's interview: questions through the lens of each configured skill (YC partner + co-founder)."""
        count = max(1, self.gateway.config.startup_questions)
        skills = [s for slug in self.gateway.config.startup_skills for s in self.gateway.skills if s.slug == slug]
        lenses = "\n\n".join(f"### {s.name}\n{s.instructions}" for s in skills)
        split = " and ".join(f"about {count // max(1, len(skills))} as the {s.name}" for s in skills) or "from every angle"
        prompt = f"""You are interviewing a founder before hiring a team for their startup. Use these perspectives:

{lenses}

The founder's pitch:
{pitch}

Write exactly {count} follow-up QUESTIONS for the founder ({split}).
Rules:
- Only questions. Never answer them and never guess facts about the startup.
- Make each one specific to this pitch (mention its customers, product or market), not a generic template.
- Skip anything the pitch already answers. Each question ends with "?".
Format, one per line, numbered 1 to {count}, nothing else. For example:
1. Which office managers have you already talked to, and what did they say about dead plants?"""
        questions = parse_questions(self._ask(prompt) or "", limit=count)
        if len(questions) >= count // 2:
            return questions
        return (questions + [q for q in FALLBACK_QUESTIONS if q not in questions])[:count]

    def answer(self, startup_id, answers):
        """Records answers (all at once, or the next one). The team starts when every question has one."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        if isinstance(answers, str):
            answers = startup["answers"] + [answers.strip()]
        startup["answers"] = [str(a).strip() for a in answers][: len(startup["questions"])]
        if len(startup["answers"]) >= len(startup["questions"]):
            self._launch(startup)
        return self.store.save(startup)

    def skip_questions(self, startup_id):
        startup = self.store.get(startup_id)
        self._launch(startup)
        return self.store.save(startup)

    def _launch(self, startup):
        startup["status"] = "running"
        startup["next_run"] = self.clock() + 60  # first meeting in about a minute

    def set_enabled(self, startup_id, enabled):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        if startup["status"] == "interview":
            return startup
        startup["status"] = "running" if enabled else "paused"
        startup["next_run"] = self.clock() + 60 if enabled else None
        return self.store.save(startup)

    def update(self, startup_id, **fields):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        for key in ("name", "min_minutes", "max_minutes", "notify_channel", "notify_chat"):
            if fields.get(key) is not None:
                startup[key] = fields[key]
        startup["min_minutes"], startup["max_minutes"] = sorted((int(startup["min_minutes"]), int(startup["max_minutes"])))
        if fields.get("enabled") is not None:
            self.store.save(startup)
            return self.set_enabled(startup_id, bool(fields["enabled"]))
        return self.store.save(startup)

    def delete(self, startup_id):
        self.store.delete(startup_id)

    # ---- the team: edit, hire, fire

    def set_team(self, startup_id, members):
        """Replaces the team. People who leave become alumni (their messages stay in the history)."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        new_team = normalize_team(members)
        alumni = {m["key"]: m for m in startup.get("alumni") or []}
        # Rehiring someone by name gives them back their old identity (and their message history).
        by_name = {m["name"].lower(): key for key, m in alumni.items()}
        taken = {m["key"] for m in new_team}
        for member in new_team:
            old_key = by_name.get(member["name"].lower())
            if old_key and member["key"] not in alumni and old_key not in taken:
                taken.discard(member["key"])
                member["key"] = old_key
                taken.add(old_key)
        kept = {m["key"] for m in new_team}
        for person in team_of(startup):
            if person.key not in kept:
                alumni[person.key] = person_dict(person)
        for key in kept:
            alumni.pop(key, None)  # rehired
        startup["team"], startup["alumni"] = new_team, list(alumni.values())
        return self.store.save(startup)

    def hire(self, startup_id, name, title, owns="", emoji=""):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        members = [person_dict(p) for p in team_of(startup)]
        return self.set_team(startup_id, members + [{"name": name, "title": title, "owns": owns, "emoji": emoji}])

    def fire(self, startup_id, who):
        """Removes an employee by key, full name or first name."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        who = who.strip().lower()
        members = [person_dict(p) for p in team_of(startup)]
        remaining = [m for m in members if who not in (m["key"], m["name"].lower(), m["name"].split()[0].lower())]
        if len(remaining) == len(members):
            raise ValueError(f"No one called {who} works here.")
        return self.set_team(startup_id, remaining)

    # ---- meetings

    def due(self):
        now = self.clock()
        return [s for s in self.store.all() if s["status"] == "running" and s["next_run"] and now >= s["next_run"]]

    def schedule_next(self, startup):
        startup["next_run"] = self.clock() + self.rng.uniform(startup["min_minutes"], startup["max_minutes"]) * 60
        return self.store.save(startup)

    def _lock(self, startup_id):
        with self.locks_guard:
            return self.locks.setdefault(startup_id, threading.Lock())

    def run_round(self, startup_id):
        """One team meeting. Returns the founder's summary, or None if nothing happened."""
        lock = self._lock(startup_id)
        if not lock.acquire(blocking=False):
            return None
        try:
            startup = self.store.get(startup_id)
            if not startup or startup["status"] == "interview":
                return None
            round_no = startup["rounds"] + 1
            team, people = team_of(startup), people_of(startup)
            current = {p.key for p in team} | {CEO.key}
            # Former employees' messages stay in the history but not in the current team's context.
            discussion = "\n".join(f"{people[m['role']].name}: {m['content']}"
                                   for m in self.store.messages(startup_id, limit=12) if m["role"] in current)
            posted = []
            speakers = pick_speakers(self.store.last_spoke(startup_id), min(self.speakers_per_round, len(team)),
                                     self.rng, team)
            for person in speakers:
                reply = self._ask(person_prompt(person, startup, discussion, team))
                if not reply:
                    continue
                self.store.add_message(startup_id, round_no, person.key, reply)
                posted.append({"round": round_no, "role": person.key, "content": reply})
                discussion += f"\n{person.name}: {reply}"
            if not posted:
                self.schedule_next(startup)
                return None
            plan, summary = split_ceo(self._ask(ceo_prompt(startup, posted, people)) or "", startup["plan"])
            summary = summary or "The team posted new ideas; see the plan."
            self.store.add_message(startup_id, round_no, CEO.key, summary)
            startup = self.store.get(startup_id) or startup
            startup["plan"], startup["rounds"] = plan, round_no
            self.schedule_next(startup)
            text = self.digest(startup, posted, summary, people)
            if self.notify and startup.get("notify_channel") and startup.get("notify_chat"):
                try:
                    self.notify(startup["notify_channel"], startup["notify_chat"], text)
                except Exception:
                    log.exception("startup: couldn't send the meeting summary")
            return text
        finally:
            lock.release()

    # Routed by the kind of work, not the prompt text (prompts mention people as @Name).
    ROUTING_HINT = "Analyze the business strategy and plan the next steps step by step."

    def _ask(self, prompt):
        try:
            decision = self.gateway.router().route(self.ROUTING_HINT)
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
    def digest(startup, posted, summary, people=None):
        people = people or PEOPLE
        who = ", ".join(people[m["role"]].first for m in posted)
        return f"🚀 *{startup['name']}*, meeting {startup['rounds']} ({who})\n\n{summary}\n\n_/startup to see your startups and plans._"

    def loop(self, tick=30, sleep=time.sleep):
        while True:
            for startup in self.due():
                try:
                    log.info("startup: %s meeting", startup["name"])
                    self.run_round(startup["id"])
                except Exception:
                    log.exception("startup: meeting failed")
                    try:
                        self.schedule_next(startup)
                    except Exception:
                        pass
            sleep(tick)

    # ---- views

    def team(self):
        """The default team new startups get."""
        return [person_dict(p) for p in TEAM]

    def summary(self, startup):
        return {k: startup[k] for k in ("id", "name", "pitch", "status", "rounds", "next_run", "min_minutes", "max_minutes",
                                        "created", "updated")}

    def detail(self, startup_id):
        startup = self.store.get(startup_id)
        if not startup:
            return None
        current = {p.key for p in team_of(startup)} | {CEO.key}
        people = {k: {"name": p.name, "title": p.title, "emoji": p.emoji, "former": k not in current}
                  for k, p in people_of(startup).items()}
        return {**startup, "now": self.clock(), "team": [person_dict(p) for p in team_of(startup)], "people": people,
                "presets": ROLE_PRESETS, "messages": self.store.messages(startup_id)}

    def listing(self):
        return {"now": self.clock(), "team": self.team(), "presets": ROLE_PRESETS,
                "startups": [self.summary(s) for s in self.store.all()]}

    # ---- chat: /startup …  and interview answers

    def pending_interview(self, channel, chat_id):
        return self.store.interviewing(channel, chat_id)

    def handle_answer(self, startup, text):
        """A chat message while Tim is interviewing the founder about a startup."""
        if text.strip().lower() in ("skip", "/skip", "start", "go"):
            self.skip_questions(startup["id"])
            return f"👍 Skipping the rest. The *{startup['name']}* team meets in about a minute."
        startup = self.answer(startup["id"], text)
        if startup["status"] == "running":
            names = ", ".join(f"{p.emoji} {p.first}" for p in team_of(startup))
            return (f"🚀 Thanks! *{startup['name']}* has a team now: {names} and me as CEO.\n\n"
                    "We meet every 10–30 minutes and I'll send you a summary after each meeting. "
                    "`/startup` lists your startups.")
        n = len(startup["answers"])
        return f"*{n + 1}/{len(startup['questions'])}*: {startup['questions'][n]}\n\n_(reply here, or `skip`)_"

    def _by_index(self, arg):
        startups = self.store.all()
        try:
            return startups[int(arg) - 1]
        except (ValueError, IndexError):
            return None

    def command(self, channel, chat_id, arg):
        arg = arg.strip()
        verb, _, rest = arg.partition(" ")
        verb = verb.lower()
        startups = self.store.all()
        if verb in ("team", "hire", "fire"):
            return self.team_command(verb, rest)
        if verb == "new" or (arg and verb not in ("now", "off", "on", "pause", "resume", "delete") and not verb.isdigit()):
            pitch = rest if verb == "new" else arg
            try:
                startup = self.create(pitch, channel=channel, chat_id=chat_id)
            except ValueError as e:
                return f"🤔 {e} e.g. `/startup new A marketplace for…`"
            return (f"🚀 New startup: *{startup['name']}*. Before I hire the team, a few questions.\n\n"
                    f"*1/{len(startup['questions'])}*: {startup['questions'][0]}\n\n_(reply here, or `skip`)_")
        if verb in ("now", "off", "pause", "on", "resume", "delete") or verb.isdigit():
            target = self._by_index(rest if not verb.isdigit() else verb) or (startups[-1] if startups and not rest and not verb.isdigit() else None)
            if not target:
                return "🤔 Which startup? Send `/startup` for the numbered list."
            if verb == "now":
                threading.Thread(target=self.run_round, args=(target["id"],), daemon=True).start()
                return f"🧑‍🤝‍🧑 Calling the *{target['name']}* team in now. The summary lands here in a few minutes."
            if verb in ("off", "pause"):
                self.set_enabled(target["id"], False)
                return f"⏸️ *{target['name']}* paused."
            if verb in ("on", "resume"):
                self.set_enabled(target["id"], True)
                return f"▶️ *{target['name']}* is back on."
            if verb == "delete":
                self.delete(target["id"])
                return f"🗑️ Deleted *{target['name']}*."
            return f"🚀 *{target['name']}* · {target['status']} · {target['rounds']} meetings\n\n{target['plan']}"
        if not startups:
            return ("🚀 *Startup Mode*: pitch me a startup and I'll interview you, then hire a team (PM, designer, "
                    "engineer, marketing, sales, bizdev, automation, finance) that works on it every 10–30 minutes.\n\n"
                    "Start with `/startup new <your pitch>`.")
        lines = []
        for i, s in enumerate(startups, 1):
            when = ""
            if s["status"] == "running" and s["next_run"]:
                when = f" · next meeting ~{max(1, int((s['next_run'] - self.clock()) / 60))} min"
            lines.append(f"{i}. *{s['name']}*: {s['status']}, {s['rounds']} meetings{when}")
        return ("🚀 *Your startups*\n" + "\n".join(lines) +
                "\n\n`/startup <n>` plan · `/startup now <n>` meet · `/startup off <n>` pause · `/startup new <pitch>`"
                "\n`/startup team <n>` · `/startup hire <n> Name | Title | what they own` · `/startup fire <n> Name`")

    def team_command(self, verb, rest):
        number, _, details = rest.strip().partition(" ")
        target = self._by_index(number)
        if not target:
            return f"🤔 Which startup? e.g. `/startup {verb} 1 …` (send `/startup` for the list)."
        try:
            if verb == "hire":
                parts = [part.strip() for part in details.split("|")]
                if len(parts) < 2:
                    return "🤔 Use `/startup hire 1 Jordan Lee | Customer Success | onboarding and retention`."
                target = self.hire(target["id"], parts[0], parts[1], parts[2] if len(parts) > 2 else "")
                person = team_of(target)[-1]
                return f"👋 {person.emoji} *{person.name}* joined *{target['name']}* as {person.title}."
            if verb == "fire":
                if not details.strip():
                    return "🤔 Who? e.g. `/startup fire 1 Omar`."
                target = self.fire(target["id"], details)
                return f"👋 Done. *{target['name']}* has {len(team_of(target))} people now."
        except ValueError as e:
            return f"🤔 {e}"
        lines = [f"{p.emoji} *{p.name}*, {p.title}: {p.owns}" for p in team_of(target)]
        return f"🧑‍🤝‍🧑 *{target['name']}* team\n" + "\n".join(lines) + f"\n🐙 *Agent Tim*, CEO"
