"""Startup Mode: run your startups with a team of agents who act like real employees.

Each startup starts as a pitch. Agent Tim interviews the founder with follow-up questions
(generated with the "Validate Your Startup" skill), then a team (PM, designer, engineer,
marketer, sales, bizdev, automation, finance) meets on a random 10–30 minute schedule. The
people who spoke least recently go first; each reads the pitch, the founder's answers, the plan
and the recent discussion, does their job and hands off to colleagues by name. Tim (CEO) folds
the meeting into a living plan and sends the founder a short summary.
"""

import json
import os
import logging
import random
import re
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass

from .launch import PROVIDERS, Launch, pipeline_view, status_line
from .graph import Memory
from .work import Work, WorkStore
from .llm import LLMError, labelled

log = logging.getLogger("agentim.startup")


@dataclass(frozen=True)
class Person:
    key: str
    name: str
    title: str
    emoji: str
    owns: str
    persona: str = ""  # personality, background and how they talk (set by the founder)
    model: str = ""    # the model this agent thinks with ("" = picked for the role)

    @property
    def first(self):
        return self.name.split()[0]


TEAM = [
    Person("product", "Maya Chen", "CPO", "🧭", "the problem, the core user, MVP scope, success metrics and what to cut"),
    Person("design", "Leo Park", "Designer", "🎨", "first impression, onboarding, the key screens, brand and trust"),
    Person("engineering", "Noah Patel", "CTO", "🛠️", "architecture, build vs. buy, the smallest shippable version, cost and risk"),
    Person("marketing", "Ava Brooks", "CMO", "📣", "positioning, messaging, content, social channels, community and launch"),
    Person("automation", "Sam Rivera", "Marketing Automation", "⚙️", "funnels, email/SMS sequences, lead scoring and tooling that runs on its own"),
    Person("sales", "Zoe Kim", "CRO", "💼", "the first 10 customers, the pitch, pricing, objections and the pipeline"),
    Person("bizdev", "Omar Haddad", "Business Development", "🤝", "partnerships, distribution channels, integrations and deals"),
    Person("finance", "Grace Liu", "CFO", "💰", "unit economics, runway, pricing math, and when and how to raise"),
    Person("data", "Nina Shah", "Data Analyst", "📊", "the metrics: north star, funnel, retention, the tracking plan, dashboards and experiment results"),
    Person("security", "Dana Cohen", "CISO", "🛡️", "security and trust: the risk register, SOC 2 / ISO 27001 readiness, customer security reviews and incident readiness"),
    Person("operations", "Marcus Reed", "COO", "⚙️", "execution: OKRs, the operating rhythm, processes, hiring plan and vendors"),
]
CEO = Person("ceo", "Agent Tim", "CEO", "🐙", "the plan, priorities and keeping the founder in the loop")
FOUNDER = Person("founder", "Founder", "Founder", "🧑‍🚀", "the vision and the final call")
# Claude Code on the founder's Mac, posting plans and build results for ideas.
CODER = Person("claude-code", "Claude Code", "Coding agent on your Mac", "🤖", "planning and building changes in the code")
MAX_FOUNDER_MESSAGE = 2000
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
    {"title": "QA Engineer", "emoji": "🐞", "owns": "test plans, automated web/mobile/API tests, bug triage and release quality"},
    {"title": "Penetration Tester", "emoji": "🔓", "owns": "authorized penetration tests: scoping, rules of engagement, methodology and findings"},
    {"title": "Security Researcher", "emoji": "🔬", "owns": "vulnerability research, threat intelligence, new attack techniques and tooling"},
    {"title": "CPO", "emoji": "🧭", "owns": "product vision, strategy, roadmap and product-market fit"},
    {"title": "CMO", "emoji": "📣", "owns": "positioning, channels, launches and pipeline from marketing"},
    {"title": "CRO", "emoji": "💼", "owns": "revenue: pipeline, sales process, pricing, forecast, expansion and retention"},
    {"title": "CFO", "emoji": "💰", "owns": "runway, unit economics, budgets, fundraising and board reporting"},
    {"title": "COO", "emoji": "⚙️", "owns": "OKRs, operating rhythm, processes, hiring plan and execution"},
    {"title": "CHRO", "emoji": "🫂", "owns": "hiring plan, interviews, onboarding, performance and culture"},
    {"title": "CDO", "emoji": "🗄️", "owns": "data strategy, platform, governance and data quality"},
    {"title": "CCO", "emoji": "🤗", "owns": "customer onboarding, success, support and retention"},
    {"title": "CLO", "emoji": "⚖️", "owns": "contracts, company structure, IP, privacy and regulatory risk"},
    {"title": "CAIO", "emoji": "🤖", "owns": "AI strategy, use cases, evaluation, cost and AI governance"},
    {"title": "CISO", "emoji": "🛡️", "owns": "the security program, risk register, compliance and incident readiness"},
    {"title": "Compliance & GRC", "emoji": "🛡️", "owns": "SOC 2 / ISO 27001 / PCI readiness, policies, audits and what customers' security teams ask"},
]


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "person"


def person_dict(person):
    return {"key": person.key, "name": person.name, "title": person.title, "emoji": person.emoji, "owns": person.owns,
            "persona": person.persona, "model": person.model}


MAX_PERSONA = 600

# Agents whose title matches a C-level skill follow that skill's playbook in meetings.
ROLE_PLAYBOOKS = {"cto": "cto", "chief technology": "cto", "cmo": "cmo", "chief marketing": "cmo",
                  "cro": "cro", "chief revenue": "cro", "cfo": "cfo", "chief financial": "cfo",
                  "coo": "coo", "chief operating": "coo",
                  "chro": "chro", "chief human": "chro", "chief people": "chro", "cdo": "cdo", "chief data": "cdo",
                  "cco": "cco", "chief customer": "cco", "clo": "clo", "chief legal": "clo", "general counsel": "clo",
                  "caio": "caio", "chief ai": "caio",
                  "cpo": "cpo", "chief product": "cpo", "ciso": "ciso", "chief information security": "ciso",
                  "data analyst": "data-analytics", "qa": "web-qa"}


def playbook_slug(title):
    title = title.lower()
    return next((slug for words, slug in ROLE_PLAYBOOKS.items() if re.search(rf"\b{re.escape(words)}\b", title)), None)


def normalize_member(raw, taken):
    """Validates one employee from the app or chat and gives them a unique key."""
    name = " ".join(str(raw.get("name", "")).split())
    title = " ".join(str(raw.get("title", "")).split())
    if not (2 <= len(name) <= 60) or not (2 <= len(title) <= 60):
        raise ValueError("Every employee needs a name and a title.")
    if slug(name) == "agent-tim":
        raise ValueError("Agent Tim is the CEO and is always on the team.")
    owns = " ".join(str(raw.get("owns") or "").split())[:300] or f"everything a {title} is responsible for"
    persona = str(raw.get("persona") or "").strip()[:MAX_PERSONA]
    emoji = (str(raw.get("emoji") or "").strip() or "🧑‍💼")[:4]
    key = slug(str(raw.get("key") or "")) or slug(name.split()[0] + "-" + title)
    base, n = key, 2
    while key in taken or key == CEO.key:
        key, n = f"{base}-{n}", n + 1
    taken.add(key)
    model = str(raw.get("model") or "").strip()[:80]
    return {"key": key, "name": name, "title": title, "emoji": emoji, "owns": owns, "persona": persona,
            "model": "" if model == "auto" else model}


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
    people[FOUNDER.key] = FOUNDER
    people[CODER.key] = CODER
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


# How every startup's agents work, whatever the idea.
def time_rule(startup):
    """The team works in minutes: plans and ETAs are in minutes, never days."""
    return (f"Timelines are in minutes, never days: Agent Tim checks progress every minute and it's "
            f"{time.strftime('%H:%M')} now. Give every ETA in minutes (\"in 40 min\", \"in 120 min\"), as a time "
            "(\"by 15:30\"), or as a dependency: \"right after Leo's ROI page\".")


# Launch mode: the one finished deliverable each role produces, in parallel, right now.
SPRINT_TASKS = {
    "product": "the v1 scope: the one core user, the 3–5 must-have features (and what's cut), the activation event and the success metric with a target",
    "design": "the design brief for v1: the landing page and the 2–3 key screens section by section, the look (colors with hex codes, fonts, tone), and the onboarding flow",
    "engineering": "the technical plan: the stack, the data model, the pages and API routes, analytics events to instrument, and what to skip for v1",
    "marketing": "the launch kit: the landing page copy (headline, subheadline, 3 benefit blocks, call to action, FAQ), a launch post for LinkedIn, a post for X, and a Show HN / Product Hunt blurb",
    "automation": "the welcome email sequence (3 emails with subject lines and body) and the sign-up → activation funnel with the trigger for each email",
    "sales": "the pricing (plans and prices), the cold outreach message (email + LinkedIn DM), the first 20 target customer profiles to contact, and answers to the top 3 objections",
    "bizdev": "the 5 best partners or channels to launch with, why each, and the exact intro message to send each",
    "finance": "the unit economics for the chosen pricing (price, cost to serve, margin, payback) and the launch budget",
    "data": "the tracking plan: the north star metric, the funnel steps, the events with names and properties, and the launch-day dashboard",
    "security": "the launch security checklist: auth, secrets, data protection, privacy policy and terms points, and the top 3 risks to fix before going live",
    "operations": "the launch-day run sheet: who does what in the first 2 hours after going live, by the minute or hour, and how the team reports back",
}

MAX_GOALS_PER_HOUR = int(os.environ.get("AGENTIM_AUTOPILOT_GOALS_PER_HOUR", "3"))
VERDICTS = {"build": "✅ Worth building", "buy": "🛒 Better to buy or use what exists",
            "build-on-top": "🧩 Build on top of something that exists", "stop": "🛑 Not worth building"}


def parse_worth(text):
    """The worth-building check's reply → {"verdict", "why", "existing": [{"name", "what"}], "gap", "recommendation"}."""
    def field(name):
        m = re.search(rf"^\W*{name}\W*:\s*(.+)$", text, re.I | re.M)
        return m.group(1).strip() if m else ""
    verdict = field("VERDICT").lower().replace(" ", "-").strip("*.`")
    verdict = next((v for v in ("build-on-top", "build", "buy", "stop") if verdict.startswith(v)), "build")
    block = re.search(r"^\W*EXISTING\W*:\s*$(.*?)(?=^\W*GAP\W*:|\Z)", text, re.I | re.M | re.S)
    existing = []
    for line in (block.group(1).splitlines() if block else []):
        item = line.strip().lstrip("-*• ").strip()
        if not item:
            continue
        name, _, what = item.partition(":")
        existing.append({"name": name.strip().strip("*"), "what": what.strip()})
    return {"verdict": verdict, "why": field("WHY"), "existing": existing[:10], "gap": field("GAP") or "none",
            "recommendation": field("RECOMMENDATION")}


DAILY_SUMMARY_HOUR = int(os.environ.get("AGENTIM_DAILY_SUMMARY_HOUR", "18"))

OPERATING_PRINCIPLES = """How this company works:
- Launch fast: ship the smallest useful version this week, not the perfect one next month.
- Measure everything: every launch has a metric and a target; look at the numbers before deciding.
- Improve in loops: launch → measure → learn → improve, every meeting.
- Sales and marketing exist to grow revenue and weekly active users; report both.
- Design keeps making the product clearer, faster and more delightful, one improvement at a time."""

# What each role pushes for, on top of the principles (by key; custom roles fall back to their title).
ROLE_GOALS = {
    "product": "decide the next smallest launch and the metric it must move",
    "design": "ship one concrete design improvement every meeting (onboarding, key screens, landing page) and say how you'll know it worked",
    "engineering": "get things live fast and safely, and make sure every launch is instrumented",
    "marketing": "grow sign-ups and weekly active users through content, social and launches; report the numbers",
    "automation": "turn sign-ups into active and paying users with automated onboarding, email/SMS and lead scoring",
    "sales": "close revenue: pipeline, demos, pilots and paying customers; report deals and revenue",
    "bizdev": "open partnerships and channels that bring users and revenue",
    "finance": "keep pricing, unit economics and runway healthy as revenue grows",
    "security": "make security a reason customers buy (trust page, questionnaires, SOC 2 path) without slowing launches",
    "operations": "turn the plan into owners, dates and a weekly rhythm, and unblock whoever is stuck",
    "data": "set up the metrics and tracking, report the numbers each meeting, and say what they mean",
}


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


def mentioned(text, team, limit=3):
    """Agents the founder tagged with @FirstName (or @key), in order, at most `limit`."""
    names = [n.lower() for n in re.findall(r"@([\w-]+)", text)]
    found = []
    for name in names:
        person = next((p for p in team if name in (p.first.lower(), p.key.lower())), None)
        if person and person not in found:
            found.append(person)
    return found[:limit]


def normalize_sources(sources):
    """[{"type": "dir", "path": …} | {"type": "github", "repo": "owner/name"}], deduplicated, at most 8."""
    clean, seen = [], set()
    for source in sources or []:
        if not isinstance(source, dict):
            continue
        if source.get("type") == "github" and str(source.get("repo", "")).strip():
            item = {"type": "github", "repo": str(source["repo"]).strip()}
        elif source.get("type") == "dir" and str(source.get("path", "")).strip():
            item = {"type": "dir", "path": str(source["path"]).strip()}
        else:
            continue
        key = item.get("repo") or item.get("path")
        if key not in seen:
            seen.add(key)
            clean.append(item)
    return clean[:8]


def source_label(source):
    return source.get("repo") or os.path.basename(str(source.get("path", "")).rstrip("/")) or "project"


def pick_speakers(last_spoke, count=3, rng=random, team=None):
    """Whoever spoke least recently goes first; ties broken randomly."""
    team = list(team or TEAM)
    rng.shuffle(team)
    team.sort(key=lambda p: last_spoke.get(p.key, -1))
    return team[:count]


def brief(startup):
    answers = "\n".join(f"Q: {q}\nA: {a}" for q, a in zip(startup["questions"], startup["answers"]) if a)
    if startup.get("kind") == "idea":
        head = f"Feature: {startup['name']}\nThe feature to add (across the services below): {startup['pitch']}"
    elif startup.get("kind") == "project":
        head = f"Project: {startup['name']}\nThe goal: {startup['pitch']}"
    else:
        head = f"Startup: {startup['name']}\nPitch: {startup['pitch']}"
    code = startup.get("codebase")
    launch = status_line(startup)
    if startup.get("memory"):
        launch = startup["memory"] + ("\n\n" + launch if launch else "")
    if startup.get("open_items"):
        launch = (launch + "\n\n" if launch else "") + ("Open action items (if one is yours, say if it's done, or "
                                                          "your new ETA):\n" + startup["open_items"])
    return (head + (f"\n\nFounder's answers:\n{answers}" if answers else "")
            + (f"\n\nThe code (improve it based on what's really there; name files when you can):\n{code}" if code else "")
            + (f"\n\n{launch}" if launch else ""))


def person_prompt(person, startup, discussion, team=None, playbook="", private=""):
    return person_context(person, startup, discussion, team, playbook, private) + f"""

Post your update for this meeting, under 180 words, in first person like you would in the team Slack:
1. What you did or decided since last time (be specific and realistic).
2. Two or three concrete next moves in YOUR area: what, an ETA in minutes or hours (or "right after @Name's …"), \
and the metric that shows it worked.
3. One ask for a colleague, by first name (e.g. "@Leo, can you…").
If the Founder said something in the discussion, start by answering it or acting on it: the founder has the final call.
React to colleagues (agree, push back, or build on one point) but never repeat or re-list their suggestions.
Do NOT write the company plan or other people's tasks: Agent Tim keeps the plan.
Remember: you are {person.first}, the {person.title}. Everything you propose is about {person.owns}.
Short bullets, no headings, start with "{person.first} here:"."""


def person_context(person, startup, discussion, team=None, playbook="", private=""):
    colleagues = ", ".join(f"{p.first} ({p.title})" for p in (team or TEAM) if p.key != person.key) or "none yet"
    return f"""You are {person.name}, {person.title} at "{startup['name']}", an early-stage startup. You are a real, \
experienced employee: you own {person.owns}. Your colleagues: {colleagues}. The CEO is Agent Tim.

{brief(startup)}

The current plan:
{startup['plan']}

{OPERATING_PRINCIPLES}
Your goal: {ROLE_GOALS.get(person.key, f"push {person.owns} forward, fast and measurably")}.
{f"Your persona (stay in character, including how you talk): {person.persona}" if person.persona else ""}
{f"Your playbook as {person.title}:{chr(10)}{playbook}" if playbook else ""}

{time_rule(startup)}

Recent team discussion:
{discussion or "(this is the team's first meeting)"}
{f"{chr(10)}Your private chat with the founder (act on what you agreed there):{chr(10)}{private}" if private else ""}"""


def ceo_prompt(startup, posted, people=None, founder_notes=()):
    people = people or {**PEOPLE, FOUNDER.key: FOUNDER}
    updates = "\n\n".join(f"{people[m['role']].name} ({people[m['role']].title}):\n{m['content']}" for m in posted)
    if founder_notes:
        updates = ("The founder told the team (this overrides earlier plans where they conflict):\n"
                   + "\n".join(f"- {note}" for note in founder_notes) + "\n\n" + updates)
    return f"""You are Agent Tim, CEO of "{startup['name']}". Keep the company plan short, concrete and current.

{OPERATING_PRINCIPLES}
{time_rule(startup)}

{brief(startup)}

Current plan:
{startup['plan']}

Updates from this meeting:
{updates}

Reply with exactly two parts:
PLAN:
<the full updated plan in markdown with: Top 3 priorities, Metrics (north star, active users, revenue, with current value or "not measured yet" and a target), By area (short bullets per area that changed, with the owner's first name and an ETA in minutes or hours, or "after <Name>'s <task>"), Next experiments, Open questions. Keep what still holds, replace what changed, under 400 words.>
SUMMARY:
<2–3 sentences for the founder: what the team decided and the single next action, with the owner's name.>"""


MINUTES_SECTIONS = ["Summary", "Decisions", "Action items", "Metrics", "Open questions"]


def minutes_prompt(startup, round_no, transcript, today=None):
    today = today or time.strftime("%A, %b %d, %Y, %H:%M")
    return f"""You are the note-taker for "{startup['name']}" (meeting {round_no}, today is {today}). Write the \
meeting minutes from this transcript. Only what was actually said: never invent numbers or decisions.
Every action item needs ONE owner (a first name from the meeting) and an ETA in minutes, never days: "in 30 min", \
"in 120 min", "by 15:30", or a dependency: "after Leo's ROI page". Use what the meeting said; if it said nothing, \
propose a realistic one and add "(proposed)".

Transcript:
{transcript}

Reply in markdown with exactly these sections, short bullets:
## Summary
<2–3 sentences: what the meeting was about and the outcome>
## Decisions
- <decision> (who decided or proposed it)
## Action items
- **<Owner first name>**: <task> — ETA: <in N min | by HH:MM | after <Name>'s <task>> [(proposed)]
(at least one per person who committed to something; never leave the owner or the ETA out)
## Metrics
- <metric: value or target, as mentioned> (or "- None mentioned")
## Open questions
- <question> (or "- None")"""


def clean_minutes(text):
    """Keeps the reply only if it has the expected sections; normalises the headings."""
    text = text.strip().strip("`").strip()
    found = [s for s in MINUTES_SECTIONS if re.search(rf"^#+\s*{s}\b", text, re.IGNORECASE | re.MULTILINE)]
    if len(found) < 3:
        return None
    for section in MINUTES_SECTIONS:
        text = re.sub(rf"^#+\s*{section}\b.*$", f"## {section}", text, flags=re.IGNORECASE | re.MULTILINE)
    return text[text.index("## "):] if "## " in text else text


def minutes_section(minutes, name):
    """The body of one "## Section" of the minutes, or None."""
    if not minutes:
        return None
    match = re.search(rf"^## {re.escape(name)}\s*$(.*?)(?=^## |\Z)", minutes, re.MULTILINE | re.DOTALL)
    body = match.group(1).strip() if match else ""
    return body or None


ACTION = re.compile(r"^-\s*(?:\[[ x]\]\s*)?(?:\*\*(?P<owner>[^*]+?)\*\*\s*[:\-–—]?\s*)?(?P<rest>.+)$")
ETA = re.compile(r"\s*(?:[—–-]\s*)?\(?\s*(?:ETA|by|due)\s*:?\s*(?P<eta>[^)]+?)\)?\s*(?P<proposed>\(proposed\))?\s*$",
                 re.IGNORECASE)


REL_ETA = re.compile(r"\bin\s+(\d+(?:\.\d+)?)\s*(m|mins?|minutes?|h|hrs?|hours?)\b", re.IGNORECASE)
CLOCK_ETA = re.compile(r"(?:^|\bby\s+|\bat\s+)(\d{1,2}):(\d{2})\b", re.IGNORECASE)
AFTER_ETA = re.compile(r"^(?:right\s+|just\s+)?(?:after|once|as soon as|when)\s+(.+)$", re.IGNORECASE)


def eta_due(eta, base):
    """("in 45 min" | "by 15:30" | "after Leo's …", meeting time) → (due timestamp or None, dependency or None)."""
    after = AFTER_ETA.match(eta.strip())
    if after:
        return None, after.group(1).strip()
    rel = REL_ETA.search(eta)
    if rel and base:
        amount, unit = float(rel.group(1)), rel.group(2).lower()
        return base + amount * (3600 if unit.startswith("h") else 60), None
    clock = CLOCK_ETA.search(eta)
    if clock and base:
        local = time.localtime(base)
        due = time.mktime((local.tm_year, local.tm_mon, local.tm_mday, int(clock.group(1)), int(clock.group(2)), 0,
                           0, 0, -1))
        return (due + 86400 if due < base - 3600 else due), None
    return None, None


def parse_action_items(minutes, base=None):
    """The minutes' action items as [{"owner", "task", "eta", "proposed", "due", "after"}] (`base`: the meeting's
    end, so "in 45 min" gets a due time)."""
    items = []
    for line in (minutes_section(minutes, "Action items") or "").splitlines():
        match = ACTION.match(line.strip())
        if not match or line.strip().lower().startswith(("- none", "- no action")):
            continue
        rest = match.group("rest").strip()
        eta = ETA.search(rest)
        task = rest[:eta.start()].strip(" —–-:") if eta else rest
        items.append({"owner": (match.group("owner") or "").strip().rstrip(":"), "task": task,
                      "eta": eta.group("eta").strip() if eta else "",
                      "proposed": bool(eta and (eta.group("proposed") or "proposed" in eta.group("eta").lower()))})
    for item in items:
        item["eta"] = re.sub(r"\s*\(?proposed\)?\s*$", "", item["eta"], flags=re.IGNORECASE).strip()
        item["due"], item["after"] = eta_due(item["eta"], base)
    return items


def open_items_text(items, now):
    """The last meeting's action items for the next meeting's brief, with what's due or overdue."""
    lines = []
    for item in items:
        if item.get("after"):
            when = f"after {item['after']}"
        elif item.get("due"):
            minutes = int((item["due"] - now) / 60)
            when = (f"due {time.strftime('%H:%M', time.localtime(item['due']))}, "
                    + (f"OVERDUE by {-minutes} min" if minutes < 0 else f"in {minutes} min"))
        else:
            when = item.get("eta") or "no ETA"
        lines.append(f"- {item['owner']}: {item['task']} ({when})")
    return "\n".join(lines)


def with_owners_and_etas(minutes, speakers, now, default_eta="in 60 min"):
    """Makes sure every action item has an owner and an ETA (and that the meeting has action items at all):
    a missing owner becomes Tim (the CEO follows up), a missing ETA becomes a proposed "in 60 min"."""
    items = parse_action_items(minutes) or [
        {"owner": name, "task": "follow up on what they committed to in this meeting", "eta": "", "proposed": True}
        for name in speakers] or [{"owner": "Tim", "task": "set next steps", "eta": "", "proposed": True}]
    lines = []
    for item in items:
        eta = item["eta"] or default_eta
        proposed = item["proposed"] or not item["eta"]
        lines.append(f"- **{item['owner'] or 'Tim'}**: {item['task']} — ETA: {eta}{' (proposed)' if proposed else ''}")
    body = "\n".join(lines)
    if minutes_section(minutes, "Action items") is None and "## Action items" not in minutes:
        return minutes.rstrip() + f"\n\n## Action items\n{body}\n"
    return re.sub(r"(^## Action items\s*$)(.*?)(?=^## |\Z)", lambda m: f"{m.group(1)}\n{body}\n\n", minutes,
                  count=1, flags=re.MULTILINE | re.DOTALL).rstrip() + "\n"


def day_of(ts):
    return time.strftime("%Y-%m-%d", time.localtime(ts))


def merge_minutes(all_minutes):
    """The day's minutes without a model: the latest summary, and every round's other sections, de-duplicated."""
    merged = {}
    for minutes in all_minutes:
        for section in MINUTES_SECTIONS:
            body = minutes_section(minutes, section)
            if not body:
                continue
            if section == "Summary":
                merged[section] = [body]
                continue
            lines = merged.setdefault(section, [])
            for line in body.splitlines():
                if line.strip() and not line.strip().lower().startswith(("- none", "- see the conversation")) \
                        and line not in lines:
                    lines.append(line)
    return "\n\n".join(f"## {s}\n" + "\n".join(merged.get(s) or ["- None"]) for s in MINUTES_SECTIONS) + "\n"


def daily_prompt(startup, day, rounds_text):
    return f"""You are the note-taker for "{startup['name']}". The team meets every few minutes; write ONE rolling \
summary of the whole day ({day}) from the minutes of each meeting below. Merge duplicates, keep the latest decision \
when one changed, keep open action items (with owner and ETA in minutes/hours, or "after X"), drop finished ones.

{rounds_text}

Reply in markdown with exactly these sections, short bullets:
## Summary
<3–4 sentences: what the team did today and where things stand now>
## Decisions
- <decision> (who)
## Action items
- **<Owner first name>**: <task> — ETA: <in N min | in N h | by HH:MM | after <Name>'s <task>>
## Metrics
- <metric: value or target> (or "- None mentioned")
## Open questions
- <question> (or "- None")"""


def fallback_minutes(messages, people):
    """When no model answers: Tim's summary plus who spoke."""
    summary = next((m["content"] for m in reversed(messages) if m["role"] == "ceo"), "The agents met.")
    speakers = sorted({people[m["role"]].first for m in messages if m["role"] in people and m["role"] != "ceo"})
    return (f"## Summary\n{summary}\n\n## Decisions\n- See the conversation\n\n## Action items\n"
            + "\n".join(f"- **{name}**: follow up on their update" for name in speakers)
            + "\n\n## Metrics\n- None recorded\n\n## Open questions\n- None recorded")


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
               "next_run", "rounds", "notify_channel", "notify_chat", "created", "updated", "team", "alumni",
               "kind", "sources", "config", "pipeline"]
    JSON_COLUMNS = ("questions", "answers", "team", "alumni", "sources", "config", "pipeline")
    # Written only by save_launch, so a long meeting saving its plan never overwrites launch progress.
    LAUNCH_COLUMNS = ("config", "pipeline")

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
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_dms (
                startup_id TEXT, person TEXT, role TEXT, content TEXT, ts REAL)""")
            self.db.execute("CREATE INDEX IF NOT EXISTS startup_dms_id ON startup_dms (startup_id, person, ts)")
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_summaries (
                startup_id TEXT, at REAL, text TEXT)""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_days (
                startup_id TEXT, day TEXT, minutes TEXT, rounds TEXT, updated REAL, sent INTEGER DEFAULT 0,
                PRIMARY KEY (startup_id, day))""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_groups (
                startup_id TEXT, id TEXT, name TEXT, members TEXT, created REAL, PRIMARY KEY (startup_id, id))""")
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_meeting_minutes (
                startup_id TEXT, round INTEGER, minutes TEXT, created REAL, PRIMARY KEY (startup_id, round))""")
            # Databases from before editable teams: add the new columns in place.
            existing = {row[1] for row in self.db.execute("PRAGMA table_info(startups)")}
            for column in ("team", "alumni", "kind", "sources", "config", "pipeline"):
                if column not in existing:
                    self.db.execute(f"ALTER TABLE startups ADD COLUMN {column} TEXT")

    def _row(self, row):
        if not row:
            return None
        s = dict(zip(self.COLUMNS, row))
        for column in self.JSON_COLUMNS:
            s[column] = json.loads(s[column] or ("{}" if column in self.LAUNCH_COLUMNS else "[]"))
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
        columns = [c for c in self.COLUMNS if c not in self.LAUNCH_COLUMNS]
        values = [json.dumps(startup[c]) if c in self.JSON_COLUMNS else startup[c] for c in columns]
        updates = ", ".join(f"{c} = excluded.{c}" for c in columns if c != "id")
        with self.lock, self.db:
            self.db.execute(f"INSERT INTO startups ({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))}) "
                            f"ON CONFLICT(id) DO UPDATE SET {updates}", values)
        return startup

    def save_launch(self, startup_id, config=None, pipeline=None):
        """Writes only the launch columns (config and/or pipeline)."""
        with self.lock, self.db:
            if config is not None:
                self.db.execute("UPDATE startups SET config = ? WHERE id = ?", (json.dumps(config), startup_id))
            if pipeline is not None:
                self.db.execute("UPDATE startups SET pipeline = ? WHERE id = ?", (json.dumps(pipeline), startup_id))

    def delete(self, startup_id):
        with self.lock, self.db:
            self.db.execute("DELETE FROM startups WHERE id = ?", (startup_id,))
            self.db.execute("DELETE FROM startup_dms WHERE startup_id = ?", (startup_id,))
            self.db.execute("DELETE FROM startup_groups WHERE startup_id = ?", (startup_id,))
            self.db.execute("DELETE FROM startup_days WHERE startup_id = ?", (startup_id,))
            self.db.execute("DELETE FROM startup_summaries WHERE startup_id = ?", (startup_id,))
            self.db.execute("DELETE FROM startup_team_messages WHERE startup_id = ?", (startup_id,))
            self.db.execute("DELETE FROM startup_meeting_minutes WHERE startup_id = ?", (startup_id,))

    def add_message(self, startup_id, round_no, role, content):
        with self.lock, self.db:
            self.db.execute("INSERT INTO startup_team_messages VALUES (?, ?, ?, ?, ?)",
                            (startup_id, round_no, role, content, time.time()))

    def add_group(self, startup_id, name, members):
        group = {"id": uuid.uuid4().hex[:8], "name": name, "members": members, "created": time.time()}
        with self.lock, self.db:
            self.db.execute("INSERT INTO startup_groups VALUES (?, ?, ?, ?, ?)",
                            (startup_id, group["id"], name, json.dumps(members), group["created"]))
        return group

    def groups(self, startup_id):
        with self.lock:
            rows = self.db.execute("SELECT id, name, members, created FROM startup_groups WHERE startup_id = ? ORDER BY created",
                                   (startup_id,)).fetchall()
        return [{"id": i, "name": n, "members": json.loads(m), "created": c} for i, n, m, c in rows]

    def delete_group(self, startup_id, group_id):
        with self.lock, self.db:
            self.db.execute("DELETE FROM startup_groups WHERE startup_id = ? AND id = ?", (startup_id, group_id))
            self.db.execute("DELETE FROM startup_dms WHERE startup_id = ? AND person = ?", (startup_id, f"group-{group_id}"))

    def add_dm(self, startup_id, person, role, content):
        with self.lock, self.db:
            self.db.execute("INSERT INTO startup_dms VALUES (?, ?, ?, ?, ?)", (startup_id, person, role, content, time.time()))

    def dms(self, startup_id, person, limit=60):
        with self.lock:
            rows = self.db.execute("""SELECT role, content, ts FROM startup_dms WHERE startup_id = ? AND person = ?
                ORDER BY ts DESC, rowid DESC LIMIT ?""", (startup_id, person, limit)).fetchall()
        return [{"role": role, "content": c, "ts": ts} for role, c, ts in reversed(rows)]

    def messages(self, startup_id, limit=40):
        with self.lock:
            rows = self.db.execute("""SELECT round, role, content, ts FROM startup_team_messages WHERE startup_id = ?
                ORDER BY ts DESC, rowid DESC LIMIT ?""", (startup_id, limit)).fetchall()
        return [{"round": r, "role": role, "content": c, "ts": ts} for r, role, c, ts in reversed(rows)]

    def round_messages(self, startup_id, round_no):
        with self.lock:
            rows = self.db.execute("""SELECT round, role, content, ts FROM startup_team_messages
                WHERE startup_id = ? AND round = ? ORDER BY ts, rowid""", (startup_id, round_no)).fetchall()
        return [{"round": r, "role": role, "content": c, "ts": ts} for r, role, c, ts in rows]

    def meetings(self, startup_id):
        """One row per meeting: when it started and ended, who spoke, how many messages."""
        with self.lock:
            rows = self.db.execute("""SELECT round, MIN(ts), MAX(ts), COUNT(*), GROUP_CONCAT(DISTINCT role)
                FROM startup_team_messages WHERE startup_id = ? GROUP BY round ORDER BY round DESC""",
                                   (startup_id,)).fetchall()
            summaries = dict(self.db.execute("""SELECT round, content FROM startup_team_messages
                WHERE startup_id = ? AND role = 'ceo'""", (startup_id,)).fetchall())
        minutes = self.all_minutes(startup_id)
        return [{"round": r, "started": start, "ended": end, "messages": count, "minutes": minutes.get(r),
                 "attendees": (roles or "").split(","), "summary": summaries.get(r)} for r, start, end, count, roles in rows]

    def save_summary(self, startup_id, at, text):
        with self.lock, self.db:
            self.db.execute("INSERT INTO startup_summaries VALUES (?, ?, ?)", (startup_id, at, text))

    def summaries(self, startup_id, limit=50):
        with self.lock:
            rows = self.db.execute("SELECT at, text FROM startup_summaries WHERE startup_id = ? ORDER BY at DESC LIMIT ?",
                                   (startup_id, limit)).fetchall()
        return [{"at": at, "text": text} for at, text in rows]

    def save_day(self, startup_id, day, minutes, rounds):
        with self.lock, self.db:
            self.db.execute("""INSERT INTO startup_days (startup_id, day, minutes, rounds, updated) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(startup_id, day) DO UPDATE SET minutes = excluded.minutes, rounds = excluded.rounds,
                updated = excluded.updated""", (startup_id, day, minutes, json.dumps(rounds), time.time()))

    def day_row(self, startup_id, day):
        with self.lock:
            row = self.db.execute("SELECT day, minutes, rounds, updated, sent FROM startup_days WHERE startup_id = ? AND day = ?",
                                  (startup_id, day)).fetchone()
        return {"day": row[0], "minutes": row[1], "rounds": json.loads(row[2] or "[]"), "updated": row[3],
                "sent": bool(row[4])} if row else None

    def day_rows(self, startup_id):
        with self.lock:
            rows = self.db.execute("SELECT day FROM startup_days WHERE startup_id = ? ORDER BY day DESC", (startup_id,)).fetchall()
        return [self.day_row(startup_id, d) for (d,) in rows]

    def mark_day_sent(self, startup_id, day):
        with self.lock, self.db:
            self.db.execute("UPDATE startup_days SET sent = 1 WHERE startup_id = ? AND day = ?", (startup_id, day))

    def save_minutes(self, startup_id, round_no, minutes):
        with self.lock, self.db:
            self.db.execute("INSERT OR REPLACE INTO startup_meeting_minutes VALUES (?, ?, ?, ?)",
                            (startup_id, round_no, minutes, time.time()))

    def minutes(self, startup_id, round_no):
        with self.lock:
            row = self.db.execute("SELECT minutes FROM startup_meeting_minutes WHERE startup_id = ? AND round = ?",
                                  (startup_id, round_no)).fetchone()
        return row[0] if row else None

    def all_minutes(self, startup_id):
        with self.lock:
            return dict(self.db.execute("SELECT round, minutes FROM startup_meeting_minutes WHERE startup_id = ?",
                                        (startup_id,)).fetchall())

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
    def __init__(self, gateway, store: StartupStore, rng=random, clock=time.time, speakers_per_round=4):
        self.gateway, self.store = gateway, store
        self.rng, self.clock = rng, clock
        self.speakers_per_round = speakers_per_round
        self.notify = None  # callable(channel, chat_id, text), set by __main__
        self.locks = {}
        self.locks_guard = threading.Lock()
        self.live = {}  # startup id → {"round", "speaking", "started"} while a meeting runs
        self.launch = Launch(self)  # design → build → test → deploy → live
        # Event-driven work: tasks start as soon as they're ready, and agents hand off to each other.
        self.work = Work(self, WorkStore(store.db, store.lock))
        self.memory = Memory(store.db, store.lock)  # the harness: what the team knows, outside any one chat
        self.default_rhythm = os.environ.get("AGENTIM_STARTUP_RHYTHM", "graph")
        self.checking = set()  # projects whose worth-building check is running
        self.auto_check = True  # every new project starts with the worth-building check
        self.autopilot_waiting = set()  # autopilot projects waiting for the goal window to free up
        from .supervisor import Supervisor
        self.supervisor = Supervisor(self)  # Agent Tim runs the loop: ETAs, late work, approvals, summaries
        self.dm_typing = set()  # (startup id, thread key) while someone writes a 1:1 or group reply
        # Telegram/WhatsApp/Slack: one summary a day ("daily", default) or one after every meeting ("meeting").
        self.notify_mode = os.environ.get("AGENTIM_STARTUP_NOTIFY", "summary")
        self.daily_hour = DAILY_SUMMARY_HOUR  # today's summary goes out after this hour
        self.dm_speaking = {}  # (startup id, group thread key) → who's typing in the group

    # ---- creating a startup: pitch → follow-up questions → team

    def create(self, pitch, name=None, channel=None, chat_id=None, min_minutes=10, max_minutes=30, team=None,
               kind="startup", sources=None):
        """A project: a new idea (pitch → interview → team), a new project to build (its goal → interview → team), or a
        feature for existing code (straight to the team). Every one gets a worth-building check first."""
        pitch = pitch.strip()
        kind = kind if kind in ("idea", "project") else "startup"
        sources = normalize_sources(sources)
        if len(pitch) < 10:
            raise ValueError("Describe the feature in a sentence or two." if kind == "idea"
                             else "Tell me the pitch in a sentence or two.")
        if kind == "idea" and not sources:
            raise ValueError("Pick at least one folder or GitHub repo for the idea.")
        min_minutes, max_minutes = sorted((max(1, int(min_minutes)), max(1, int(max_minutes))))
        name = (name or "").strip() or name_from_pitch(pitch)
        members = normalize_team(team) if team else [person_dict(p) for p in TEAM]
        startup = {
            "id": uuid.uuid4().hex[:12], "name": name, "pitch": pitch,
            # Ideas skip the founder interview: the code and the feature are the brief.
            "questions": [] if kind == "idea" else self.follow_up_questions(pitch),
            "answers": [], "status": "running" if kind == "idea" else "interview",
            "plan": initial_plan(name, [Person(**m) for m in members]), "kind": kind, "sources": sources,
            "team": members, "alumni": [], "min_minutes": min_minutes,
            "max_minutes": max_minutes, "next_run": self.clock() + 60 if kind == "idea" else None, "rounds": 0,
            "notify_channel": channel,
            "notify_chat": str(chat_id) if chat_id is not None else None, "created": self.clock(), "updated": self.clock(),
        }
        saved = self.store.save(startup)
        if self.auto_check:
            self.start_check(saved["id"])
        return self.store.get(saved["id"])

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
        questions = parse_questions(self._ask(prompt, "Startup interview questions") or "", limit=count)
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

    AI_MARK = " (suggested by AI)"

    def suggest_answers(self, startup_id, indexes=None, answers=None):
        """AI drafts answers to the interview questions from the pitch (and the founder's own answers so far).
        Returns {index: answer} for the asked questions (default: every unanswered one)."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        questions = startup["questions"]
        given = [str(a).strip() for a in (answers if answers is not None else startup["answers"])][:len(questions)]
        wanted = [i for i in (indexes if indexes is not None else range(len(questions)))
                  if 0 <= i < len(questions) and (indexes is not None or i >= len(given) or not given[i])]
        if not wanted:
            return {}
        known = "\n".join(f"Q: {questions[i]}\nA: {a}" for i, a in enumerate(given) if a and i not in wanted)
        asked = "\n".join(f"{i + 1}. {questions[i]}" for i in wanted)
        reply = self._ask(f"""You are helping a founder fill in a startup interview. Startup: "{startup['name']}".
Pitch: {startup['pitch']}
{f"What the founder already answered:{chr(10)}{known}" if known else ""}

Answer each question below as the founder would: specific, realistic and consistent with the pitch, 1–3 sentences, \
with concrete guesses (a named customer type, a price, a number) rather than "it depends". Never contradict the founder.

{asked}

Reply with one line per question, starting with its number exactly as above, like "{wanted[0] + 1}. <answer>".""",
                          f"Startup interview · {startup['name']} · AI answers") or ""
        found = {}
        for line in reply.splitlines():
            match = re.match(r"^\s*\**(\d+)[.)]\**\s*(.+)$", line)
            if match and int(match.group(1)) - 1 in wanted:
                found[int(match.group(1)) - 1] = match.group(2).strip().strip("*").strip()
        if not found:
            raise ValueError("No model could suggest answers right now. Check that a model is running.")
        return found

    def autocomplete(self, startup_id, answers=None):
        """AI answers every remaining question (marked as suggested by AI), then the team starts."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        given = [str(a).strip() for a in (answers if answers is not None else startup["answers"])][:len(startup["questions"])]
        suggested = self.suggest_answers(startup_id, answers=given)
        full = [given[i] if i < len(given) and given[i]
                else (suggested[i] + self.AI_MARK if i in suggested else "") for i in range(len(startup["questions"]))]
        return self.answer(startup_id, full)

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
        if fields.get("sources") is not None:
            startup["sources"] = normalize_sources(fields["sources"])
        if fields.get("rhythm") is not None:
            self.set_rhythm(startup_id, fields["rhythm"])
            startup = {**self.store.get(startup_id), **{k: startup[k] for k in ("name", "sources", "min_minutes",
                                                                                   "max_minutes", "notify_channel",
                                                                                   "notify_chat")}}
        startup["min_minutes"], startup["max_minutes"] = sorted((int(startup["min_minutes"]), int(startup["max_minutes"])))
        if fields.get("enabled") is not None:
            self.store.save(startup)
            return self.set_enabled(startup_id, bool(fields["enabled"]))
        return self.store.save(startup)

    def delete(self, startup_id):
        self.store.delete(startup_id)
        self.work.store.delete_startup(startup_id)
        self.memory.delete(startup_id)

    def post_founder(self, startup_id, text):
        """The founder talks to the agents: during a meeting, the agents who speak next see it;
        otherwise the next meeting starts from it."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        text = (text or "").strip()
        if not text:
            raise ValueError("Write something for the agents.")
        if len(text) > MAX_FOUNDER_MESSAGE:
            raise ValueError(f"Keep it under {MAX_FOUNDER_MESSAGE} characters.")
        live = self.live.get(startup_id)
        round_no = live["round"] if live else startup["rounds"] + 1
        self.store.add_message(startup_id, round_no, FOUNDER.key, text)
        tagged = mentioned(text, team_of(startup))
        for person in tagged:
            threading.Thread(target=self.reply_directly, args=(startup_id, person, text, round_no), daemon=True).start()
        if not tagged and self.rhythm(startup) == "graph":
            # One continuous meeting: Agent Tim answers, and a new goal becomes a new graph.
            threading.Thread(target=self.ceo_reply, args=(startup_id, text, round_no), daemon=True).start()
        return {"posted": True, "live": bool(live), "round": round_no, "mentioned": [p.key for p in tagged]}

    def ceo_reply(self, startup_id, text, round_no):
        startup = self.store.get(startup_id)
        if not startup:
            return None
        explicit = re.match(r"^\s*(?:new\s+)?goal\s*:\s*(.+)$", text, re.I | re.S)
        if explicit:
            try:
                self.set_goal(startup_id, explicit.group(1))
            except ValueError as e:
                self.store.add_message(startup_id, round_no, CEO.key, f"I couldn't plan that: {e}")
            return None
        board = self.work.board(startup_id)["tasks"]
        people = people_of(startup)
        state = "\n".join(f"- [{t['status']}] {people[t['owner']].first if t['owner'] in people else t['owner']}: {t['task']}"
                          for t in board[-15:]) or "(no tasks yet)"
        reply = self._ask(f"""You are Agent Tim, CEO of "{startup['name']}". The founder just wrote in the team room:
"{text}"

Where the work stands:
{state}

{self.memory.brief(startup_id)}

Answer the founder in under 100 words: what you'll do about it, naming who on the team. If they're giving the team a new \
goal, put it on the first line as "GOAL: <the goal>" and nothing else on that line.""",
                          f"Startup · {startup['name']} · Tim replies")
        if not reply:
            return None
        goal = re.match(r"^\s*\**GOAL\**\s*:\s*(.+)$", reply.splitlines()[0], re.I)
        body = "\n".join(reply.splitlines()[1:]).strip() if goal else reply.strip()
        if body:
            self.store.add_message(startup_id, round_no, CEO.key, body)
        if goal:
            try:
                self.set_goal(startup_id, goal.group(1))
            except ValueError as e:
                self.store.add_message(startup_id, round_no, CEO.key, f"I couldn't plan that: {e}")
        return reply

    def reply_directly(self, startup_id, person, text, round_no):
        """A tagged agent answers the founder right away (outside the meeting order)."""
        startup = self.store.get(startup_id)
        if not startup:
            return None
        team, people = team_of(startup), people_of(startup)
        current = {p.key for p in team} | {CEO.key, FOUNDER.key}
        discussion = "\n".join(f"{people[m['role']].name}: {m['content']}"
                               for m in self.store.messages(startup_id, limit=14) if m["role"] in current)
        owns_live = startup_id not in self.live
        if owns_live:
            self.live[startup_id] = {"round": round_no, "speaking": person.key, "started": self.clock(),
                                     "speakers": [person.key], "direct": True}
        try:
            prompt = person_prompt(person, startup, discussion, team, self.playbook(person)) + f"""

The founder just tagged you directly: "{text}"
Answer the founder now, as {person.first}: do what they asked in your area (concrete output, not a promise), \
under 180 words, start with "{person.first} here:"."""
            reply = self._ask(prompt, f"Startup · {startup['name']} · @{person.first} replies")
            if reply:
                self.store.add_message(startup_id, round_no, person.key, reply)
            return reply
        finally:
            if owns_live and self.live.get(startup_id, {}).get("direct"):
                self.live.pop(startup_id, None)

    # ---- launch mode: everyone works in parallel

    def sprint_task(self, startup_id, person):
        """One employee's launch-mode deliverable: finished and ready to use, posted in the agents room."""
        startup = self.store.get(startup_id)
        team, people = team_of(startup), people_of(startup)
        current = {p.key for p in team} | {CEO.key, FOUNDER.key}
        discussion = "\n".join(f"{people[m['role']].name}: {m['content']}"
                               for m in self.store.messages(startup_id, limit=8) if m["role"] in current)
        task = SPRINT_TASKS.get(person.key, f"the one deliverable in {person.owns} the launch needs most")
        prompt = (person_context(person, startup, discussion, team, self.playbook(person)) + f"""

LAUNCH MODE: the whole team is working in parallel right now to design, build and launch v1 today. Claude Code is \
building the product while you work. Deliver, finished and ready to use (not a plan or a promise): {task}.
Under 350 words, concrete names and numbers, markdown. Start with a one-line bold title. Don't start with your name.""")
        reply = self._ask(prompt, f"Launch mode · {startup['name']} · {person.first}")
        if reply:
            self.store.add_message(startup_id, startup["rounds"] + 1, person.key, reply)
        return person, reply

    # ---- open action items and 1:1 chats with one employee

    def open_items(self, startup_id, last_round):
        """The last meeting's action items with their due times, for the next meeting's brief."""
        if last_round < 1:
            return ""
        messages = self.store.round_messages(startup_id, last_round)
        items = parse_action_items(self.store.minutes(startup_id, last_round), messages[-1]["ts"] if messages else None)
        return open_items_text(items, self.clock()) if items else ""

    def private_notes(self, startup_id, person, limit=6):
        """What the founder and this person agreed in their 1:1 and in the groups they're in."""
        startup = self.store.get(startup_id)
        people = people_of(startup) if startup else {}
        lines = [f"{'Founder' if m['role'] == FOUNDER.key else person.first}: {m['content']}"
                 for m in self.store.dms(startup_id, person.key, limit)]
        for group in self.store.groups(startup_id):
            if person.key in group["members"]:
                lines += [f"[{group['name']}] {'Founder' if m['role'] == FOUNDER.key else people[m['role']].first if m['role'] in people else m['role']}: {m['content']}"
                          for m in self.store.dms(startup_id, f"group-{group['id']}", 4)]
        return "\n".join(lines)[-1600:]

    # ---- groups and the conversation list (iMessage-style)

    def group(self, startup_id, group_id):
        group = next((g for g in self.store.groups(startup_id) if g["id"] == group_id), None)
        if not group:
            raise ValueError("No such group.")
        return group

    def create_group(self, startup_id, members, name=""):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        valid = [p.key for p in team_of(startup)] + [CEO.key]
        members = [m for m in dict.fromkeys(members or []) if m in valid]
        if len(members) < 2:
            raise ValueError("Pick at least two people for a group.")
        people = {**people_of(startup), CEO.key: CEO}
        name = (name or "").strip()[:60] or ", ".join(people[m].first for m in members[:3]) + (
            f" +{len(members) - 3}" if len(members) > 3 else "")
        return self.store.add_group(startup_id, name, members)

    def delete_group(self, startup_id, group_id):
        self.group(startup_id, group_id)
        self.store.delete_group(startup_id, group_id)

    def threads(self, startup_id):
        """Every conversation: the team room, the founder's groups, and each person, with the last message."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        team = team_of(startup)
        last = self.store.messages(startup_id, limit=1)
        threads = [{"key": "room", "kind": "room", "name": "Team room", "members": [p.key for p in team] + [CEO.key],
                    "last": last[-1] if last else None, "typing": startup_id in self.live}]
        for group in self.store.groups(startup_id):
            key = f"group-{group['id']}"
            msgs = self.store.dms(startup_id, key, 1)
            threads.append({"key": key, "kind": "group", "name": group["name"], "members": group["members"],
                            "last": msgs[-1] if msgs else None, "typing": (startup_id, key) in self.dm_typing})
        for person in team + [CEO]:
            msgs = self.store.dms(startup_id, person.key, 1)
            threads.append({"key": person.key, "kind": "person", "name": person.name, "title": person.title,
                            "emoji": person.emoji, "members": [person.key], "last": msgs[-1] if msgs else None,
                            "typing": (startup_id, person.key) in self.dm_typing})
        return {"threads": threads}

    def chat_person(self, startup, key):
        people = {**{p.key: p for p in team_of(startup)}, CEO.key: CEO}
        if key not in people:
            raise ValueError("Pick someone on the team.")
        return people[key]

    def dm(self, startup_id, key):
        """A private 1:1 chat between the founder and one employee (or a group chat: key "group-<id>")."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        if key.startswith("group-"):
            group = self.group(startup_id, key[6:])
            return {"person": {"key": key, "name": group["name"], "title": f"{len(group['members'])} people", "emoji": "👥"},
                    "group": group, "messages": self.store.dms(startup_id, key),
                    "typing": (startup_id, key) in self.dm_typing, "speaking": self.dm_speaking.get((startup_id, key))}
        person = self.chat_person(startup, key)
        return {"person": person_dict(person) if person.key != CEO.key else
                {"key": CEO.key, "name": CEO.name, "title": CEO.title, "emoji": CEO.emoji},
                "messages": self.store.dms(startup_id, key), "typing": (startup_id, key) in self.dm_typing}

    def send_dm(self, startup_id, key, text):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        text = (text or "").strip()
        if not text:
            raise ValueError("Write something.")
        if len(text) > MAX_FOUNDER_MESSAGE:
            raise ValueError(f"Keep it under {MAX_FOUNDER_MESSAGE} characters.")
        if key.startswith("group-"):
            group = self.group(startup_id, key[6:])
            self.store.add_dm(startup_id, key, FOUNDER.key, text)
            self.dm_typing.add((startup_id, key))
            threading.Thread(target=self.reply_group, args=(startup_id, group, text), daemon=True).start()
            return self.dm(startup_id, key)
        person = self.chat_person(startup, key)
        self.store.add_dm(startup_id, key, FOUNDER.key, text)
        self.dm_typing.add((startup_id, key))
        threading.Thread(target=self.reply_dm, args=(startup_id, person), daemon=True).start()
        return self.dm(startup_id, key)

    def reply_dm(self, startup_id, person):
        try:
            startup = self.store.get(startup_id)
            team, people = team_of(startup), people_of(startup)
            current = {p.key for p in team} | {CEO.key, FOUNDER.key}
            discussion = "\n".join(f"{people[m['role']].name}: {m['content']}"
                                   for m in self.store.messages(startup_id, limit=8) if m["role"] in current)
            history = "\n".join(f"{'Founder' if m['role'] == FOUNDER.key else person.first}: {m['content']}"
                                for m in self.store.dms(startup_id, person.key, 12))
            prompt = (person_context(person, startup, discussion, team, self.playbook(person)) + f"""

You're in a private 1:1 chat with the founder (the team doesn't see it). The chat so far:
{history}

Reply to the founder's last message as {person.first}: direct, helpful and in character, under 150 words. If they ask \
for work, do it now when you can (a draft, numbers, a plan) and give an ETA in minutes or hours for the rest. Don't \
start with your name.""")
            reply = self._ask(prompt, f"Startup · {startup['name']} · 1:1 with {person.first}")
            self.store.add_dm(startup_id, person.key, person.key,
                              reply or f"(No model answered: {person.first} couldn't reply. Check that a model is running.)")
        finally:
            self.dm_typing.discard((startup_id, person.key))

    def reply_group(self, startup_id, group, text):
        """Everyone in the group answers in turn (or only the people the founder @tagged), each seeing the others."""
        key = f"group-{group['id']}"
        try:
            startup = self.store.get(startup_id)
            team, people = team_of(startup), {**people_of(startup), CEO.key: CEO}
            members = [people[m] for m in group["members"] if m in people]
            speakers = mentioned(text, members, limit=len(members)) or members
            current = {p.key for p in team} | {CEO.key, FOUNDER.key}
            discussion = "\n".join(f"{people[m['role']].name}: {m['content']}"
                                   for m in self.store.messages(startup_id, limit=6) if m["role"] in current)
            for person in speakers:
                self.dm_speaking[(startup_id, key)] = person.key
                history = "\n".join(f"{'Founder' if m['role'] == FOUNDER.key else people[m['role']].first if m['role'] in people else m['role']}: {m['content']}"
                                    for m in self.store.dms(startup_id, key, 14))
                others = ", ".join(f"{p.first} ({p.title})" for p in members if p.key != person.key)
                prompt = (person_context(person, startup, discussion, team, self.playbook(person)) + f"""

You're in a group chat called "{group['name']}" with the founder and {others} (the rest of the team doesn't see it). \
The chat so far:
{history}

Reply as {person.first}, in the first person ("I'll…"), about what YOU will do in your own area ({person.owns}), \
under 120 words. You are {person.first}: never address yourself, and don't give tasks to people outside this group. \
React to what {others} just said, by name, without repeating it. Give each thing you'll do an ETA in minutes or \
hours. Don't start with your name.""")
                reply = self._ask(prompt, f"Startup · {startup['name']} · {group['name']} · {person.first}")
                if reply:
                    self.store.add_dm(startup_id, key, person.key, reply)
        finally:
            self.dm_typing.discard((startup_id, key))
            self.dm_speaking.pop((startup_id, key), None)

    # ---- code: context for meetings, and planning/building ideas with Claude Code on the Mac

    def codebase(self, startup, max_chars=1500):
        """A short brief of the linked folders/repos from the runner on the Mac ("" when none or unreachable)."""
        if not startup.get("sources"):
            return ""
        try:
            return self.gateway.claude.call("/v1/projects/context",
                                            {"sources": startup["sources"], "max_chars": max_chars}, timeout=600)["context"]
        except Exception as e:
            log.warning("startup: no codebase context: %s", e)
            return ""

    def work_on_code(self, startup_id, mode="plan", confirmed=False):
        """Claude Code plans (read-only) or builds (edit, confirmed by the founder) the idea in each linked project.
        Each result lands in the agents room; then the team meets on it."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        if not startup.get("sources"):
            raise ValueError("Link a folder or GitHub repo first.")
        if mode == "build" and not confirmed:
            raise ValueError("Building changes the code: confirm it first.")
        round_no = startup["rounds"] + 1
        notes = "\n".join(f"- {m['content']}" for m in self.store.messages(startup_id, limit=30)
                          if m["role"] == FOUNDER.key)[-1500:]
        for source in startup["sources"]:
            label = source_label(source)
            self.live[startup_id] = {"round": round_no, "speaking": CODER.key, "started": self.clock(),
                                     "speakers": [CODER.key], "direct": True}
            if mode == "build":
                prompt = (f"Implement this feature in this service: {startup['pitch']}\n"
                          + (f"Founder's notes:\n{notes}\n" if notes else "")
                          + "Follow the codebase's conventions, keep the change focused, add or update tests, and end "
                            "with a short summary of what you changed.")
            else:
                prompt = (f"Plan how to add this feature in this service, without changing any files: {startup['pitch']}\n"
                          + (f"Founder's notes:\n{notes}\n" if notes else "")
                          + "Answer in under 250 words: whether this service needs changes at all, the files to change, "
                            "the steps in order, API or data changes other services depend on, risks, and the tests to add.")
            try:
                result = self.gateway.claude.call("/v1/projects/task", {
                    "source": source, "prompt": prompt, "agent": "claude-code",
                    "mode": "edit" if mode == "build" else "read", "confirmed": mode == "build" and confirmed},
                    timeout=1800)
                body = result["output"].strip()[:2500]
                if mode == "build":
                    changed = result.get("changed") or "no files changed"
                    text = f"**{label}**: built.\n\n{body}\n\nChanged:\n```\n{changed}\n```"
                else:
                    text = f"**{label}**: plan\n\n{body}"
            except Exception as e:
                text = f"**{label}**: couldn't {'build' if mode == 'build' else 'plan'} ({e})"
            self.store.add_message(startup_id, round_no, CODER.key, text)
        self.live.pop(startup_id, None)
        # The team discusses the plans (or reviews the build) right away.
        return self.run_round(startup_id)

    def start_work(self, startup_id, mode="plan", confirmed=False):
        """Runs work_on_code in the background (it can take minutes)."""
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        if mode == "build" and not confirmed:
            raise ValueError("Building changes the code: confirm it first.")
        if not startup.get("sources"):
            raise ValueError("Link a folder or GitHub repo first.")
        threading.Thread(target=self.work_on_code, args=(startup_id, mode, confirmed), daemon=True).start()

    def meetings(self, startup_id):
        if not self.store.get(startup_id):
            raise KeyError(startup_id)
        return self.store.meetings(startup_id)

    def meeting(self, startup_id, round_no):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        messages = self.store.round_messages(startup_id, round_no)
        if not messages:
            return None
        people = {k: {"name": p.name, "title": p.title, "emoji": p.emoji} for k, p in people_of(startup).items()}
        summary = next((m["content"] for m in reversed(messages) if m["role"] == CEO.key), None)
        return {"round": round_no, "started": messages[0]["ts"], "ended": messages[-1]["ts"],
                "summary": summary, "minutes": self.store.minutes(startup_id, round_no),
                "action_items": parse_action_items(self.store.minutes(startup_id, round_no), messages[-1]["ts"]),
                "messages": messages, "people": people}

    # ---- event-driven work: the meeting's action items become tasks; agents hand off as they finish

    def rhythm(self, startup):
        """"graph" (default): goals become task graphs with checks and gates; one continuous meeting, summarized on
        demand. "events": meetings make tasks and agents hand off. "timer": the team meets every min–max minutes."""
        return (startup.get("config") or {}).get("rhythm") or self.default_rhythm

    def begin_work(self, startup_id, round_no, minutes):
        startup = self.store.get(startup_id)
        if not startup or self.rhythm(startup) != "events":
            return []
        messages = self.store.round_messages(startup_id, round_no)
        items = parse_action_items(minutes, messages[-1]["ts"] if messages else None) if minutes else []
        created = self.work.seed(startup_id, round_no, items)
        board = self.work.board(startup_id)["tasks"]
        if created or any(t["ready"] for t in board):
            startup = self.store.get(startup_id)
            startup["next_run"] = None  # the next meeting comes when the work is done
            self.store.save(startup)
            self.work.kick(startup_id)
        return created

    def set_rhythm(self, startup_id, rhythm):
        if rhythm not in ("graph", "events", "timer"):
            raise ValueError("The rhythm is graph, events or timer.")
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        config = {**(startup.get("config") or {}), "rhythm": rhythm}
        self.store.save_launch(startup_id, config=config)
        if rhythm == "timer" and startup["status"] == "running" and not startup.get("next_run"):
            self.schedule_next(startup)
            self.store.save(startup)
        elif rhythm in ("events", "graph"):
            if rhythm == "graph":
                startup = self.store.get(startup_id)
                startup["next_run"] = None  # no scheduled meetings
                self.store.save(startup)
            self.work.kick(startup_id)

    # ---- the rolling daily meeting: every round of a day folds into one meeting with one summary

    def update_day(self, startup_id, round_no):
        """Folds this round into its day's rolling meeting and rewrites the day's summary."""
        startup = self.store.get(startup_id)
        messages = self.store.round_messages(startup_id, round_no)
        if not startup or not messages:
            return None
        day = day_of(messages[-1]["ts"])
        rounds = sorted(m["round"] for m in self.store.meetings(startup_id) if day_of(m["ended"]) == day)
        parts = [(r, self.store.minutes(startup_id, r)) for r in rounds]
        parts = [(r, m) for r, m in parts if m]
        if not parts:
            return None
        if len(parts) == 1:
            minutes = parts[0][1]
        else:
            text = "\n\n".join(f"### Meeting {r} ({time.strftime('%H:%M', time.localtime(self.store.round_messages(startup_id, r)[0]['ts']))})\n{m}"
                                for r, m in parts)[-12000:]
            reply = self._ask(daily_prompt(startup, day, text), f"Startup · {startup['name']} · daily summary")
            minutes = clean_minutes(reply or "") or merge_minutes([m for _, m in parts])
            people = people_of(startup)
            speakers = [people[m["role"]].first for r in rounds for m in self.store.round_messages(startup_id, r)
                        if m["role"] in people and m["role"] not in ("founder", "ceo", "claude-code")]
            minutes = with_owners_and_etas(minutes, list(dict.fromkeys(speakers)), messages[-1]["ts"])
        self.store.save_day(startup_id, day, minutes, rounds)
        return self.store.day_row(startup_id, day)

    def days(self, startup_id):
        """One rolling meeting per day, newest first."""
        if not self.store.get(startup_id):
            raise KeyError(startup_id)
        out = []
        for row in self.store.day_rows(startup_id):
            meetings = [m for m in self.store.meetings(startup_id) if m["round"] in row["rounds"]]
            out.append({**row, "started": min((m["started"] for m in meetings), default=0),
                        "ended": max((m["ended"] for m in meetings), default=0),
                        "round": max(row["rounds"], default=0), "messages": sum(m["messages"] for m in meetings),
                        "summary": None,
                        "action_items": parse_action_items(row["minutes"], row["updated"]),
                        "attendees": sorted({a for m in meetings for a in m["attendees"]})})
        return out

    def day(self, startup_id, day):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        row = self.store.day_row(startup_id, day)
        if not row:
            return None
        messages = [m for r in row["rounds"] for m in self.store.round_messages(startup_id, r)]
        people = {k: {"name": p.name, "title": p.title, "emoji": p.emoji} for k, p in people_of(startup).items()}
        return {**row, "started": messages[0]["ts"] if messages else 0, "ended": messages[-1]["ts"] if messages else 0,
                "round": max(row["rounds"], default=0), "summary": None,
                "action_items": parse_action_items(row["minutes"], row["updated"]), "messages": messages, "people": people}

    def daily_digest(self, startup, day_row):
        actions = minutes_section(day_row["minutes"], "Action items")
        summary = minutes_section(day_row["minutes"], "Summary") or ""
        label = "Today" if day_row["day"] == day_of(time.time()) else time.strftime("%A", time.strptime(day_row["day"], "%Y-%m-%d"))
        return (f"🗓️ *{startup['name']}*: {label}'s meeting ({len(day_row['rounds'])} rounds)\n\n{summary}"
                + (f"\n\n✅ *Action items*\n{actions}" if actions and "None" not in actions[:12] else "")
                + "\n\n_/startup to see your startups and plans._")

    def send_daily(self, startup, hour=None):
        """Sends each finished day's summary once: yesterday's on the first meeting of a new day, and today's after
        AGENTIM_DAILY_SUMMARY_HOUR (default 18:00)."""
        if not (self.notify and startup.get("notify_channel") and startup.get("notify_chat")):
            return []
        hour = self.daily_hour if hour is None else hour
        # Message timestamps are wall-clock time, so the day is too.
        today, sent = day_of(time.time()), []
        for row in self.store.day_rows(startup["id"]):
            if row["sent"] or (row["day"] == today and time.localtime().tm_hour < hour):
                continue
            try:
                self.notify(startup["notify_channel"], startup["notify_chat"], self.daily_digest(startup, row))
                self.store.mark_day_sent(startup["id"], row["day"])
                sent.append(row["day"])
            except Exception:
                log.exception("startup: couldn't send the daily summary")
        return sent

    def write_minutes(self, startup_id, round_no):
        """Meeting minutes from the transcript: summary, decisions, action items, metrics, open questions."""
        startup = self.store.get(startup_id)
        messages = self.store.round_messages(startup_id, round_no) if startup else []
        if not messages:
            raise KeyError(f"{startup_id}/{round_no}")
        people = people_of(startup)
        transcript = "\n\n".join(f"{people[m['role']].name if m['role'] in people else m['role']}"
                                  f" ({people[m['role']].title if m['role'] in people else ''}): {m['content']}"
                                  for m in messages)
        reply = self._ask(minutes_prompt(startup, round_no, transcript),
                          f"Startup meeting · {startup['name']} · minutes") or ""
        minutes = clean_minutes(reply) or fallback_minutes(messages, people)
        speakers = [people[m["role"]].first for m in messages if m["role"] in people
                    and m["role"] not in ("founder", "ceo", "claude-code")]
        minutes = with_owners_and_etas(minutes, list(dict.fromkeys(speakers)), messages[-1]["ts"])
        self.store.save_minutes(startup_id, round_no, minutes)
        return minutes

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
        """One team meeting. Returns the founder's summary, or None if nothing happened.
        In graph mode there are no rounds: the first goal is planned (or the work resumes) instead."""
        startup = self.store.get(startup_id)
        if startup and startup["status"] != "interview" and self.rhythm(startup) == "graph":
            return self.graph_tick(startup_id)
        return self._run_round(startup_id)

    def graph_tick(self, startup_id):
        startup = self.store.get(startup_id)
        startup["next_run"] = None  # one continuous meeting: nothing is scheduled
        self.store.save(startup)
        if not self.cleared_to_build(startup):
            return None  # the worth-building check is running, or waits for the founder's decision
        if any(t["status"] in ("todo", "doing") for t in self.work.store.all(startup_id)):
            self.work.kick(startup_id)
            return None
        if self.work.store.all(startup_id):
            return None  # the last goal is done or waits for the founder: they set the next one
        goal = (f"Get {startup['name']} to its first 10 customers: the v1 scope, the landing page copy, pricing, "
                "the tracking plan and the launch plan")
        try:
            self.work.plan(startup_id, goal)
        except ValueError as e:
            log.warning("startup: couldn't plan the first goal: %s", e)
        return None

    def set_goal(self, startup_id, goal):
        return self.work.plan(startup_id, goal)

    # ---- worth building? (build vs buy, and who already solves it)

    def cleared_to_build(self, startup):
        config = startup.get("config") or {}
        check = config.get("check")
        if not check:
            return True  # projects from before the check
        if check.get("status") == "running":
            return False
        return config.get("decision") == "build"

    def start_check(self, startup_id):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        if startup_id in self.checking:
            return False
        self.checking.add(startup_id)
        config = {**(startup.get("config") or {}), "check": {"status": "running", "at": self.clock()}}
        self.store.save_launch(startup_id, config=config)
        threading.Thread(target=self.check_worth, args=(startup_id,), daemon=True).start()
        return True

    def check_worth(self, startup_id):
        """Is it worth building? Who already solves this, build vs buy, and the gap. Uses Claude Code on the Mac
        (it can search the web) when it's there, else the best model's own knowledge."""
        try:
            startup = self.store.get(startup_id)
            kind = {"idea": "A feature for existing code", "project": "A project to build"}.get(startup.get("kind"), "A startup idea")
            researcher = next((m["alias"] for m in self.model_choices() if m["agent"] and "claude" in m["alias"]), None)
            reply = self._ask(f"""You are a sharp CTO and business-development analyst. Before anyone builds this, check if it's worth building.

{kind}: "{startup['name']}": {startup['pitch']}

1. Existing solutions: companies, products, open-source projects or built-in features that already solve this. Name \
them, with what they do and the price if you know it.{" Search the web to check." if researcher else ""}
2. Build vs buy: the time and cost to build a v1 vs using or buying the best existing option.
3. The gap: what no one does well yet, if anything.

Reply exactly in this format:
VERDICT: build | buy | build-on-top | stop
WHY: <2–3 sentences>
EXISTING:
- <name>: <what it does, price if known>
GAP: <the gap, or "none">
RECOMMENDATION: <one line>""", f"Startup · {startup['name']} · worth building?", model=researcher)
            check = parse_worth(reply or "")
            check.update(status="done", at=self.clock(), source="Claude Code (web search)" if researcher else "model knowledge")
            config = {**(self.store.get(startup_id).get("config") or {}), "check": check}
            if check["verdict"] == "build" and not config.get("decision"):
                config["decision"] = "build"
            self.store.save_launch(startup_id, config=config)
            existing = "\n".join(f"- **{e['name']}**: {e['what']}" for e in check["existing"][:6]) or "- None found"
            ask = "" if config.get("decision") == "build" else \
                "\n\n**Your call**: build anyway, or stop? (The work starts when you choose Build.)"
            self.store.add_message(startup_id, max(startup["rounds"], 1), CEO.key,
                                   f"🔎 **Worth building?** {VERDICTS.get(check['verdict'], check['verdict'])}\n\n{check['why']}\n\n"
                                   f"**Already out there**\n{existing}\n\n**The gap**: {check['gap']}\n\n"
                                   f"**Recommendation**: {check['recommendation']}{ask}")
            if config.get("decision") == "build":
                self.run_round(startup_id) if self.rhythm(self.store.get(startup_id)) == "graph" and \
                    self.store.get(startup_id)["status"] == "running" else None
        except Exception:
            log.exception("startup: the worth-building check failed")
            startup = self.store.get(startup_id)
            if startup:
                config = {**(startup.get("config") or {}), "check": {"status": "failed", "at": self.clock()},
                          "decision": (startup.get("config") or {}).get("decision") or "build"}
                self.store.save_launch(startup_id, config=config)
        finally:
            self.checking.discard(startup_id)

    def decide(self, startup_id, decision):
        """The founder's call after the check: build (the work starts) or stop (the project pauses)."""
        if decision not in ("build", "stop"):
            raise ValueError("Build or stop?")
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        config = {**(startup.get("config") or {}), "decision": decision}
        self.store.save_launch(startup_id, config=config)
        self.store.add_message(startup_id, max(startup["rounds"], 1), FOUNDER.key,
                               "🛠️ Build it." if decision == "build" else "🛑 Let's not build this.")
        if decision == "stop":
            return self.set_enabled(startup_id, False)
        if startup["status"] == "running" and self.rhythm(startup) == "graph":
            threading.Thread(target=self.run_round, args=(startup_id,), daemon=True).start()
        return self.store.get(startup_id)

    # ---- autopilot: keep going, goal after goal, until the project is developed

    def next_goal(self, startup_id):
        """Autopilot: Agent Tim sets the next goal toward the project's goal, or says it's developed."""
        startup = self.store.get(startup_id)
        recent = [m for m in self.memory.all(startup_id) if m["kind"] == "decision" and m["text"].startswith("Goal:")
                  and time.time() - m["created"] < 3600]
        if len(recent) >= MAX_GOALS_PER_HOUR:
            self.store.add_message(startup_id, max(startup["rounds"], 1), CEO.key,
                                   f"⏸️ That's {MAX_GOALS_PER_HOUR} goals in the last 60 minutes: autopilot picks up "
                                   "the next one as soon as the window frees up.")
            self.autopilot_waiting.add(startup_id)
            return None
        self.autopilot_waiting.discard(startup_id)
        done = [t for t in self.work.store.all(startup_id) if t["status"] == "done"][-20:]
        history = "\n".join(f"- {t['task']}" for t in done) or "(nothing yet)"
        version = (startup.get("config") or {}).get("version")
        reply = self._ask(f"""You are Agent Tim, CEO of "{startup['name']}", on autopilot: the team keeps working until the \
project is developed.

The project's goal: {startup['pitch']}
Done so far{f" (the code is at {version})" if version else ""}:
{history}

{self.memory.brief(startup_id)}

What's the next goal that moves the project closest to working, shipped and used? One line: "GOAL: <the goal>". If the \
project is fully developed and nothing important is left, reply "DONE: <why>".""", f"Startup · {startup['name']} · next goal")
        if not reply:
            return None
        first = reply.strip().splitlines()[0]
        if re.match(r"^\W*DONE\b", first, re.I):
            self.store.add_message(startup_id, max(startup["rounds"], 1), CEO.key,
                                   f"🏁 **The project is developed.** {first.split(':', 1)[-1].strip()}\n\nAsk for a summary, or set a new goal.")
            return None
        goal = re.match(r"^\W*GOAL\W*:\s*(.+)$", first, re.I)
        return self.set_goal(startup_id, goal.group(1) if goal else first.strip())

    def _run_round(self, startup_id):
        lock = self._lock(startup_id)
        if not lock.acquire(blocking=False):
            return None
        try:
            startup = self.store.get(startup_id)
            if not startup or startup["status"] == "interview":
                return None
            round_no = startup["rounds"] + 1
            startup["codebase"] = self.codebase(startup)
            startup["open_items"] = self.open_items(startup_id, startup["rounds"])
            team, people = team_of(startup), people_of(startup)
            current = {p.key for p in team} | {CEO.key, FOUNDER.key, CODER.key}

            def discussion():
                # Re-read before each speaker: the founder may have posted mid-meeting. Former employees'
                # messages stay in the history but not in the current team's context.
                return "\n".join(f"{people[m['role']].name}: {m['content']}"
                                 for m in self.store.messages(startup_id, limit=14) if m["role"] in current)

            posted = []
            speakers = pick_speakers(self.store.last_spoke(startup_id), min(self.speakers_per_round, len(team)),
                                     self.rng, team)
            self.live[startup_id] = {"round": round_no, "speaking": None, "started": self.clock(),
                                     "speakers": [p.key for p in speakers]}
            for person in speakers:
                self.live[startup_id]["speaking"] = person.key
                reply = self._ask(person_prompt(person, startup, discussion(), team, self.playbook(person),
                                                private=self.private_notes(startup_id, person)),
                                  f"Startup meeting · {startup['name']} · {person.first}")
                if not reply:
                    continue
                self.store.add_message(startup_id, round_no, person.key, reply)
                posted.append({"round": round_no, "role": person.key, "content": reply})
            if not posted:
                self.schedule_next(startup)
                return None
            self.live[startup_id]["speaking"] = CEO.key
            # Everything the founder said since Tim's last summary (between meetings and during this one).
            recent = self.store.messages(startup_id, limit=60)
            last_summary = max((m["ts"] for m in recent if m["role"] == CEO.key), default=0)
            notes = [m["content"] for m in recent if m["role"] == FOUNDER.key and m["ts"] > last_summary]
            plan, summary = split_ceo(self._ask(ceo_prompt(startup, posted, people, notes),
                                                f"Startup meeting · {startup['name']} · Tim (plan)") or "", startup["plan"])
            summary = summary or "The team posted new ideas; see the plan."
            self.store.add_message(startup_id, round_no, CEO.key, summary)
            startup = self.store.get(startup_id) or startup
            startup["plan"], startup["rounds"] = plan, round_no
            self.schedule_next(startup)
            self.live.pop(startup_id, None)  # the meeting is over; the minutes are written after it
            minutes = None
            try:
                minutes = self.write_minutes(startup_id, round_no)
            except Exception:
                log.exception("startup: couldn't write the meeting minutes")
            text = self.digest(startup, posted, summary, people, minutes)

            try:
                self.begin_work(startup_id, round_no, minutes)
            except Exception:
                log.exception("startup: couldn't start the work")
            if self.notify_mode == "meeting":
                if self.notify and startup.get("notify_channel") and startup.get("notify_chat"):
                    try:
                        self.notify(startup["notify_channel"], startup["notify_chat"], text)
                    except Exception:
                        log.exception("startup: couldn't send the meeting summary")
            # Otherwise Agent Tim sends a summary every N minutes (the supervisor), never once a day.
            return text
        finally:
            self.live.pop(startup_id, None)
            lock.release()

    def playbook(self, person, limit=1500):
        """The C-level / specialist skill matching this agent's title, trimmed to keep prompts small."""
        slug = playbook_slug(person.title)
        skill = next((s for s in getattr(self.gateway, "skills", []) if s.slug == slug), None) if slug else None
        return skill.instructions[:limit] if skill else ""

    # Routed by the kind of work, not the prompt text (prompts mention people as @Name).
    ROUTING_HINT = "Analyze the business strategy and plan the next steps step by step."

    CODING_HINT = "Write the Python code to implement this feature and fix the failing test."
    TECH_TITLES = re.compile(r"\b(cto|engineer|developer|qa|data|analyst|architect|devops|security|ciso)\b", re.I)

    def model_for(self, person):
        """The model an agent thinks with: the one set for them, else the best for their kind of work."""
        if person.model:
            return person.model
        try:
            hint = self.CODING_HINT if self.TECH_TITLES.search(person.title) else self.ROUTING_HINT
            return self.gateway.router().route(hint).model.alias
        except Exception:
            return None

    def checker_model(self, avoid=None):
        """Agent Tim checks on a different model than the one that did the work (a model shouldn't grade itself)."""
        try:
            decision = self.gateway.router().route(self.ROUTING_HINT)
        except Exception:
            return None
        ranking = [decision.model] + decision.fallbacks
        return next((m.alias for m in ranking if m.alias != avoid and "agent" not in getattr(m, "caps", ())), None) \
            or decision.model.alias

    def model_choices(self):
        """The models an agent can be set to (chat models and the local coding agents)."""
        try:
            models = self.gateway.router().models
        except Exception:
            return []
        media = {"video", "image", "speech", "transcription"}
        return [{"alias": m.alias, "id": m.id, "agent": "agent" in m.caps} for m in models if not (set(m.caps) & media)]

    def _ask(self, prompt, label="Startup Mode", model=None, avoid=None):
        try:
            router = self.gateway.router()
            pinned = router.find(model) if model else None
            decision = router.route(self.ROUTING_HINT)
        except Exception as e:
            log.warning("startup: no model: %s", e)
            return None
        candidates = ([pinned] if pinned else []) + [decision.model] + decision.fallbacks
        if avoid:
            candidates = [m for m in candidates if m.alias != avoid] or candidates
        seen, ordered = set(), []
        for m in candidates:
            if m.id not in seen:
                seen.add(m.id)
                ordered.append(m)
        for model in ordered[:2]:
            try:
                with labelled(label):
                    return self.gateway.llm.complete(model, "", [{"role": "user", "content": prompt}]).strip()
            except LLMError as e:
                log.warning("startup: %s failed: %s", model.alias, e)
        return None

    @staticmethod
    def digest(startup, posted, summary, people=None, minutes=None):
        """The message the founder gets when a meeting is over: summary, then the action items."""
        people = people or PEOPLE
        who = ", ".join(people[m["role"]].first for m in posted)
        actions = minutes_section(minutes, "Action items")
        todo = f"\n\n✅ *Action items*\n{actions}" if actions and "None" not in actions[:12] else ""
        return (f"🚀 *{startup['name']}*, meeting {startup['rounds']} is over ({who})\n\n{summary}{todo}"
                "\n\n_/startup to see your startups and plans._")

    def loop(self, tick=30, sleep=time.sleep):
        while True:
            try:
                self.supervisor.maybe_tick()  # every minute: Tim checks every project
                for startup_id in list(self.autopilot_waiting):
                    self.next_goal(startup_id)
            except Exception:
                log.exception("startup: the supervisor failed")
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
        return {**{k: startup[k] for k in ("id", "name", "pitch", "status", "rounds", "next_run", "min_minutes",
                                           "max_minutes", "created", "updated")},
                "kind": startup.get("kind") or "startup", "sources": startup.get("sources") or [],
                "live_url": (startup.get("config") or {}).get("live_url") or None,
                "launch_stage": next((s["stage"] for s in reversed(pipeline_view(startup))
                                      if s["status"] in ("done", "running", "waiting", "failed")), None)}

    def detail(self, startup_id):
        startup = self.store.get(startup_id)
        if not startup:
            return None
        current = {p.key for p in team_of(startup)} | {CEO.key}
        people = {k: {"name": p.name, "title": p.title, "emoji": p.emoji, "former": k not in current}
                  for k, p in people_of(startup).items()}
        return {**startup, "now": self.clock(), "team": [person_dict(p) for p in team_of(startup)], "people": people,
                "presets": ROLE_PRESETS, "messages": self.store.messages(startup_id),
                "meeting": self.live.get(startup_id),
                "pipeline": pipeline_view(startup), "launch_running": startup_id in self.launch.running,
                "sprint": (startup.get("pipeline") or {}).get("sprint"),
                "last_summary": (self.store.summaries(startup_id, 1) or [None])[0],
                "rhythm": self.rhythm(startup),
                "model_choices": self.model_choices(),
                "memory": self.memory.all(startup_id),
                "working": sorted(set((self.work.working.get(startup_id) or {}).values())),
                "providers": [{"id": k, **v} for k, v in PROVIDERS.items()]}

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
        if verb == "say":
            number, _, text = rest.strip().partition(" ")
            target = self._by_index(number)
            if not target or not text.strip():
                return "🤔 Use `/startup say 1 <your message to the agents>` (send `/startup` for the list)."
            try:
                result = self.post_founder(target["id"], text)
            except ValueError as e:
                return f"🤔 {e}"
            when = "They'll answer in this meeting." if result["live"] else "They'll pick it up in the next meeting."
            return f"📣 Told the *{target['name']}* agents. {when}"
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
                "\n`/startup team <n>` · `/startup hire <n> Name | Title | what they own` · `/startup fire <n> Name`"
                "\n`/startup say <n> <message>` talk to the agents")

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
