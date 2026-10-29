"""The Recruiter: finds engineers on GitHub, reads their public work, and drafts a personal message for each.

Research only: the founder sends the messages (on LinkedIn, by hand). GitHub's terms don't allow using information
from GitHub for unsolicited emails (recruiting included) and LinkedIn doesn't allow automated messaging, so emails are
never collected and nothing is sent automatically.
"""

import json
import logging
import re
import threading
import time
import uuid

log = logging.getLogger("agentim.recruit")

STATUSES = ("new", "shortlisted", "contacted", "replied", "skipped")


def query_prompt(role):
    return f"""You are a technical recruiter. Turn this role into ONE GitHub user search query (GitHub search syntax: \
language:, location:, followers:>N, repos:>N, plus a keyword if useful). Prefer active, credible engineers \
(followers:>20 is a good floor).

Role: {role}

Reply with only the query, e.g.: language:swift location:berlin followers:>30"""


def clean_query(text):
    line = (text or "").strip().strip("`").splitlines()[0] if (text or "").strip() else ""
    line = re.sub(r"^(query\s*:\s*)", "", line, flags=re.I).strip().strip("`\"'")
    return line[:200]


def evidence(candidate):
    repos = "\n".join(f"- {r['name']} ({r.get('language') or '?'}, ★{r.get('stars', 0)}): {r.get('description') or ''}"
                      for r in candidate.get("repos", [])[:6]) or "- (no public repos)"
    commits = "\n".join(f"- {c['repo']}: {c['message']}" for c in candidate.get("commits", [])[:8]) or "- (no recent public commits)"
    return (f"{candidate.get('name') or candidate['login']} (@{candidate['login']}), {candidate.get('location') or 'location unknown'}"
            f"{', ' + candidate['company'] if candidate.get('company') else ''}. Bio: {candidate.get('bio') or '-'}\n"
            f"Repos:\n{repos}\nRecent commits:\n{commits}")


def assess_prompt(startup, role, candidate, persona=""):
    return f"""You are the recruiter for "{startup['name']}" ({startup['pitch']}). {persona}
The role: {role}

A candidate's public GitHub work:
{evidence(candidate)}

Judge the fit only from this evidence (no guessing about the person beyond it). Then write two short, warm, specific \
messages from the founder that mention ONE concrete thing from their repos or commits (name the repo or the commit), \
say why it's relevant to the role, and ask for a 15-minute call. No flattery, no buzzwords, no fake urgency.

Reply exactly in this format:
SCORE: <0–10>
WHY: <one sentence: the evidence that fits (or doesn't)>
NOTE: <a LinkedIn connection note, under 280 characters>
MESSAGE: <a longer message, under 120 words>"""


def parse_assessment(text):
    def field(name, until):
        m = re.search(rf"^\W*{name}\W*:\s*(.+?)(?=^\W*(?:{until})\W*:|\Z)", text or "", re.I | re.M | re.S)
        return m.group(1).strip() if m else ""
    score = re.search(r"SCORE\W*:\s*(\d+(?:\.\d+)?)", text or "", re.I)
    note = field("NOTE", "MESSAGE")
    return {"score": max(0.0, min(10.0, float(score.group(1)))) if score else 0.0,
            "why": field("WHY", "NOTE|MESSAGE"), "note": note[:300], "message": field("MESSAGE", "$^")[:1200]}


def linkedin_search_url(candidate):
    """A LinkedIn people search for the founder to open (name + company), never a scraped profile."""
    from urllib.parse import quote
    words = " ".join(x for x in (candidate.get("name") or candidate["login"], candidate.get("company") or "") if x)
    return f"https://www.linkedin.com/search/results/people/?keywords={quote(words.strip().lstrip('@'))}"


class CandidateStore:
    def __init__(self, db, lock):
        self.db, self.lock = db, lock
        with self.lock, self.db:
            self.db.execute("""CREATE TABLE IF NOT EXISTS startup_candidates (
                id TEXT PRIMARY KEY, startup_id TEXT, role TEXT, login TEXT, profile TEXT, score REAL, why TEXT,
                note TEXT, message TEXT, status TEXT, created REAL, updated REAL)""")

    COLUMNS = ["id", "startup_id", "role", "login", "profile", "score", "why", "note", "message", "status", "created", "updated"]

    def add(self, startup_id, role, candidate, assessment):
        row = {"id": uuid.uuid4().hex[:10], "startup_id": startup_id, "role": role, "login": candidate["login"],
               "profile": json.dumps(candidate), "score": assessment["score"], "why": assessment["why"],
               "note": assessment["note"], "message": assessment["message"], "status": "new",
               "created": time.time(), "updated": time.time()}
        with self.lock, self.db:
            self.db.execute(f"INSERT INTO startup_candidates VALUES ({', '.join('?' * len(self.COLUMNS))})",
                            [row[c] for c in self.COLUMNS])
        return row

    def all(self, startup_id):
        with self.lock:
            rows = self.db.execute(f"SELECT {', '.join(self.COLUMNS)} FROM startup_candidates WHERE startup_id = ? "
                                   "ORDER BY score DESC, created DESC", (startup_id,)).fetchall()
        out = []
        for r in rows:
            item = dict(zip(self.COLUMNS, r))
            item["profile"] = json.loads(item["profile"] or "{}")
            item["linkedin"] = linkedin_search_url(item["profile"])
            out.append(item)
        return out

    def logins(self, startup_id):
        with self.lock:
            return {r[0] for r in self.db.execute("SELECT login FROM startup_candidates WHERE startup_id = ?", (startup_id,))}

    def update(self, startup_id, candidate_id, **fields):
        fields["updated"] = time.time()
        sets = ", ".join(f"{k} = ?" for k in fields)
        with self.lock, self.db:
            self.db.execute(f"UPDATE startup_candidates SET {sets} WHERE id = ? AND startup_id = ?",
                            [*fields.values(), candidate_id, startup_id])

    def delete_startup(self, startup_id):
        with self.lock, self.db:
            self.db.execute("DELETE FROM startup_candidates WHERE startup_id = ?", (startup_id,))


class Recruiter:
    def __init__(self, mode, store: CandidateStore):
        self.mode, self.store = mode, store
        self.running = {}  # startup id → the role being sourced

    def recruiter(self, startup):
        """The team's recruiter (if one was hired), for their persona and model."""
        from .startup import team_of
        return next((p for p in team_of(startup) if re.search(r"recruit|talent|people|chro", p.title, re.I)), None)

    def start(self, startup_id, role, limit=8):
        startup = self.mode.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        role = (role or "").strip()
        if len(role) < 5:
            raise ValueError("Describe the role, e.g. \"Senior iOS engineer, Swift, Europe\".")
        if startup_id in self.running:
            raise ValueError("The recruiter is already searching.")
        self.running[startup_id] = role
        threading.Thread(target=self.run, args=(startup_id, role, limit), daemon=True).start()
        return {"started": role}

    def run(self, startup_id, role, limit):
        say = lambda text: self.mode.store.add_message(startup_id, max(self.mode.store.get(startup_id)["rounds"], 1),  # noqa: E731
                                                       who, text)
        startup = self.mode.store.get(startup_id)
        person = self.recruiter(startup)
        who = person.key if person else "ceo"
        try:
            model = self.mode.model_for(person) if person else None
            query = clean_query(self.mode._ask(query_prompt(role), f"Recruiting · {startup['name']} · search", model=model))
            if not query:
                raise ValueError("No model could turn the role into a search.")
            say(f"🔎 **Sourcing**: {role}\n\nSearching GitHub for `{query}`…")
            found = self.mode.gateway.claude.call("/v1/recruit/search", {"q": query, "limit": limit}, timeout=300)
            seen = self.store.logins(startup_id)
            added = []
            persona = f"Your persona: {person.persona}" if person and person.persona else ""
            for candidate in found.get("candidates", []):
                if candidate["login"] in seen:
                    continue
                reply = self.mode._ask(assess_prompt(startup, role, candidate, persona),
                                       f"Recruiting · {startup['name']} · @{candidate['login']}", model=model)
                if not reply:
                    continue
                added.append(self.store.add(startup_id, role, candidate, parse_assessment(reply)))
            top = sorted(added, key=lambda c: -c["score"])[:5]
            lines = "\n".join(f"- **{json.loads(c['profile']).get('name') or c['login']}** (@{c['login']}), {c['score']:.0f}/10: {c['why']}"
                              for c in top) or "- No new candidates for that search."
            say(f"🧑‍💻 **{len(added)} candidates** for {role}\n\n{lines}\n\n_Messages are drafted in the Hiring tab: "
                "review, copy, and send them yourself on LinkedIn._")
        except Exception as e:  # noqa: BLE001
            log.exception("recruit: failed")
            say(f"🔎 Sourcing stopped: {e}")
        finally:
            self.running.pop(startup_id, None)

    def set_status(self, startup_id, candidate_id, status=None, note=None, message=None):
        fields = {}
        if status is not None:
            if status not in STATUSES:
                raise ValueError(f"Status is one of: {', '.join(STATUSES)}.")
            fields["status"] = status
        if note is not None:
            fields["note"] = str(note)[:300]
        if message is not None:
            fields["message"] = str(message)[:1200]
        if fields:
            self.store.update(startup_id, candidate_id, **fields)
        return self.board(startup_id)

    def board(self, startup_id):
        return {"candidates": self.store.all(startup_id), "searching": self.running.get(startup_id)}
