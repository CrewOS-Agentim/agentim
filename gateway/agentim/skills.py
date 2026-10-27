"""SKILL.md loading and matching (same format as the iOS app)."""

import os
from dataclasses import dataclass, field


@dataclass
class Skill:
    name: str
    summary: str = ""
    instructions: str = ""
    triggers: list = field(default_factory=list)
    always: bool = False

    @property
    def slug(self):
        return "".join(c for c in self.name.lower().replace(" ", "-") if c.isalnum() or c == "-")

    def invoked(self, message):
        return f"/{self.slug}" in message.lower()

    def triggered(self, message):
        lower = message.lower()
        return self.always or any(t and t.lower() in lower for t in self.triggers)


def parse(markdown):
    lines = markdown.splitlines()
    if not lines or lines[0].strip() != "---":
        return None
    try:
        end = next(i for i, line in enumerate(lines[1:], 1) if line.strip() == "---")
    except StopIteration:
        return None
    fields = {}
    for line in lines[1:end]:
        key, sep, value = line.partition(":")
        if sep:
            fields[key.strip().lower()] = value.strip().strip("\"'")
    if not fields.get("name"):
        return None
    return Skill(
        name=fields["name"], summary=fields.get("description", ""),
        instructions="\n".join(lines[end + 1:]).strip(),
        triggers=[t.strip() for t in fields.get("triggers", "").split(",") if t.strip()],
        always=fields.get("always") == "true")


def load_dir(path):
    skills = []
    if not os.path.isdir(path):
        return skills
    for name in sorted(os.listdir(path)):
        if name.endswith(".md"):
            with open(os.path.join(path, name)) as f:
                skill = parse(f.read())
            if skill:
                skills.append(skill)
    return skills


def active(skills, agent_skill_slugs, message):
    """Slash commands work for any skill; trigger words only for skills the agent has."""
    chosen = []
    for skill in skills:
        attached = skill.slug in agent_skill_slugs
        if skill.invoked(message) or (attached and skill.triggered(message)):
            chosen.append(skill)
    return chosen


def system_prompt(agent_prompt, chosen):
    parts = [agent_prompt] if agent_prompt else []
    parts += [f"## Skill: {s.name}\n{s.instructions}" for s in chosen]
    return "\n\n".join(parts)
