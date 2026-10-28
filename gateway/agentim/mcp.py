"""MCP server: lets Claude (Desktop, Code) and ChatGPT use agentim as a connector.

Speaks the Model Context Protocol over Streamable HTTP with plain JSON responses, at /mcp (Bearer
token) and at /mcp/<AGENTIM_MCP_SECRET> for clients that can't send headers (ChatGPT connectors through
a tunnel). Local apps such as Claude Desktop use the stdio bridge in mcp/agentim_mcp.py.
"""

import base64
import json
import logging
import threading
import urllib.request
import uuid

from . import __version__

log = logging.getLogger("agentim.mcp")

PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"]
INSTRUCTIONS = (
    "agentim (Agent Tim 🐙) runs AI agents on the user's own Mac: local Hugging Face models in Docker, "
    "LTX for images and video, built-in skills, and Startup Mode where a team of agent employees works on "
    "a startup. Use ask_agentim to get an answer from the user's local models or agents, generate_image / "
    "generate_video for media, and the startup tools to create and follow startups.")


def _text(value):
    return [{"type": "text", "text": value if isinstance(value, str) else json.dumps(value, indent=2, ensure_ascii=False)}]


def _tool(name, title, description, properties=None, required=(), read_only=False):
    return {"name": name, "title": title, "description": description,
            "inputSchema": {"type": "object", "properties": properties or {}, "required": list(required)},
            "annotations": {"readOnlyHint": read_only, "openWorldHint": False}}


STARTUP_REF = {"type": "string", "description": "The startup's id, its number in list_startups (1, 2, …) or its name."}

TOOLS = [
    _tool("ask_agentim", "Ask agentim",
          "Send a message to agentim and get the answer from the user's local models (routed automatically to "
          "the best one). Start the message with @alias to pick a model or /skill-slug to use a skill "
          "(see list_skills). Pass conversation to keep context across calls.",
          {"message": {"type": "string", "description": "What to ask."},
           "agent": {"type": "string", "description": "Optional agent name or slug from list_agents."},
           "conversation": {"type": "string", "description": "Optional id to continue a conversation."}},
          ["message"]),
    _tool("generate_image", "Generate an image",
          "Make an image with LTX on the user's Mac (opens LTX Desktop if needed; about a minute or two).",
          {"prompt": {"type": "string", "description": "What the image shows."}}, ["prompt"]),
    _tool("generate_video", "Generate a video",
          "Make a short video with LTX on the user's Mac (several minutes). Returns a link on the user's Mac.",
          {"prompt": {"type": "string", "description": "What happens in the video."}}, ["prompt"]),
    _tool("list_agents", "List agents", "The user's agentim agents (personas with their own skills).", read_only=True),
    _tool("list_skills", "List skills", "Skills you can use with ask_agentim as /skill-slug.", read_only=True),
    _tool("list_models", "List models", "Models agentim can use right now (🏠 local, ☁️ cloud).", read_only=True),
    _tool("list_startups", "List startups", "The user's Startup Mode startups with their status.", read_only=True),
    _tool("get_startup", "Get a startup",
          "A startup's pitch, interview questions and answers, team, current plan and recent team messages.",
          {"startup": STARTUP_REF}, ["startup"], read_only=True),
    _tool("create_startup", "Create a startup",
          "Start a startup from a pitch. Agent Tim replies with follow-up questions; answer them with "
          "answer_startup_questions (or skip) and the agent team starts meeting every 10–30 minutes.",
          {"pitch": {"type": "string", "description": "The startup pitch, a sentence or two."},
           "name": {"type": "string", "description": "Optional name."}}, ["pitch"]),
    _tool("answer_startup_questions", "Answer a startup's questions",
          "Answer Agent Tim's follow-up questions for a startup, in order. Set skip to start the team now.",
          {"startup": STARTUP_REF,
           "answers": {"type": "array", "items": {"type": "string"}, "description": "Answers, in question order."},
           "skip": {"type": "boolean", "description": "Skip the remaining questions."}}, ["startup"]),
    _tool("run_startup_meeting", "Run a team meeting",
          "Call the startup's team into a meeting now. It takes a few minutes; read the result with get_startup.",
          {"startup": STARTUP_REF}, ["startup"]),
]


class ToolError(Exception):
    pass


class MCPServer:
    def __init__(self, gateway, catalog, fetch=None):
        self.gateway, self.catalog = gateway, catalog
        self.fetch = fetch or self._fetch

    # ---- JSON-RPC

    def handle(self, message):
        """One JSON-RPC message → response dict, or None for notifications."""
        if not isinstance(message, dict) or message.get("jsonrpc") != "2.0" or "method" not in message:
            return self._error(message.get("id") if isinstance(message, dict) else None, -32600, "Invalid request")
        method, params, msg_id = message["method"], message.get("params") or {}, message.get("id")
        if msg_id is None:
            return None  # notifications/initialized, notifications/cancelled, …
        try:
            if method == "initialize":
                asked = params.get("protocolVersion")
                return self._result(msg_id, {
                    "protocolVersion": asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": "agentim", "title": "agentim 🐙", "version": __version__},
                    "instructions": INSTRUCTIONS})
            if method == "ping":
                return self._result(msg_id, {})
            if method == "tools/list":
                return self._result(msg_id, {"tools": TOOLS})
            if method == "tools/call":
                return self._result(msg_id, self.call(params.get("name"), params.get("arguments") or {}))
            if method in ("resources/list", "prompts/list"):
                return self._result(msg_id, {method.split("/")[0]: []})
            return self._error(msg_id, -32601, f"Method not found: {method}")
        except Exception as e:
            log.exception("mcp: %s failed", method)
            return self._error(msg_id, -32603, str(e))

    def handle_body(self, body):
        """A POSTed body: one message or a batch. Returns (status, payload or None)."""
        if isinstance(body, list):
            responses = [r for r in (self.handle(m) for m in body) if r is not None]
            return (200, responses) if responses else (202, None)
        response = self.handle(body)
        return (200, response) if response is not None else (202, None)

    @staticmethod
    def _result(msg_id, result):
        return {"jsonrpc": "2.0", "id": msg_id, "result": result}

    @staticmethod
    def _error(msg_id, code, message):
        return {"jsonrpc": "2.0", "id": msg_id, "error": {"code": code, "message": message}}

    # ---- tools

    def call(self, name, args):
        tool = getattr(self, f"tool_{name}", None) if name in {t["name"] for t in TOOLS} else None
        if not tool:
            return {"content": _text(f"Unknown tool: {name}"), "isError": True}
        try:
            return {"content": tool(**{k: v for k, v in args.items() if v is not None}), "isError": False}
        except ToolError as e:
            return {"content": _text(str(e)), "isError": True}
        except TypeError as e:
            return {"content": _text(f"Bad arguments: {e}"), "isError": True}

    def _chat(self, text, conversation=None, agent=None):
        chat_id = f"mcp-{conversation or uuid.uuid4().hex}"
        if agent:
            match = self._agent(agent)
            self.gateway.store.set_agent(f"api:{chat_id}", match.slug)
        return self.gateway.handle("api", chat_id, "api", text)

    def _agent(self, ref):
        ref = ref.strip().lower()
        for a in self.gateway.config.agents:
            if ref in (a.slug, a.name.lower()):
                return a
        raise ToolError(f"No agent called {ref}. Try list_agents.")

    def tool_ask_agentim(self, message, conversation=None, agent=None):
        if not message.strip():
            raise ToolError("message is empty")
        replies = self._chat(message, conversation, agent)
        return self._content(replies)

    def tool_generate_image(self, prompt):
        return self._content(self._chat(f"/image {prompt}"), embed_images=True)

    def tool_generate_video(self, prompt):
        return self._content(self._chat(f"/video {prompt}"))

    def tool_list_agents(self):
        return _text([{"name": a.name, "slug": a.slug, "emoji": a.emoji, "summary": a.summary}
                      for a in self.gateway.config.agents])

    def tool_list_skills(self):
        return _text([{"slug": s.slug, "name": s.name, "summary": s.summary} for s in self.gateway.skills])

    def tool_list_models(self):
        models = self.catalog()
        if not models:
            return _text("No models are ready yet (they may still be downloading).")
        return _text([{"alias": m.alias, "id": m.id, "local": m.local} for m in models])

    # ---- startups

    def _startups(self):
        if not self.gateway.startup:
            raise ToolError("Startup Mode isn't available on this gateway.")
        return self.gateway.startup

    def _startup(self, ref):
        mode = self._startups()
        startups = mode.store.all()
        ref = str(ref).strip()
        for s in startups:
            if ref == s["id"] or ref.lower() == s["name"].lower():
                return s
        if ref.isdigit() and 1 <= int(ref) <= len(startups):
            return startups[int(ref) - 1]
        raise ToolError(f"No startup {ref!r}. Try list_startups.")

    def tool_list_startups(self):
        listing = self._startups().listing()
        return _text([{"number": i, "id": s["id"], "name": s["name"], "status": s["status"], "meetings": s["rounds"],
                       "pitch": s["pitch"]} for i, s in enumerate(listing["startups"], 1)] or "No startups yet.")

    def tool_get_startup(self, startup):
        d = self._startups().detail(self._startup(startup)["id"])
        people = d["people"]
        return _text({
            "id": d["id"], "name": d["name"], "status": d["status"], "meetings": d["rounds"], "pitch": d["pitch"],
            "interview": [{"question": q, "answer": d["answers"][i] if i < len(d["answers"]) else None}
                          for i, q in enumerate(d["questions"])],
            "team": [f"{p['emoji']} {p['name']}, {p['title']}" for p in d["team"]] + ["🐙 Agent Tim, CEO"],
            "plan": d["plan"],
            "recent_messages": [f"{people.get(m['role'], {}).get('name', m['role'])}: {m['content']}"
                                for m in d["messages"][-10:]]})

    def tool_create_startup(self, pitch, name=None):
        mode = self._startups()
        try:
            created = mode.create(pitch, name)
        except ValueError as e:
            raise ToolError(str(e))
        questions = "\n".join(f"{i}. {q}" for i, q in enumerate(created["questions"], 1))
        return _text(f"Created {created['name']} (id {created['id']}). Agent Tim's follow-up questions:\n{questions}\n\n"
                     "Answer them with answer_startup_questions (or skip=true) to start the team.")

    def tool_answer_startup_questions(self, startup, answers=None, skip=False):
        mode, target = self._startups(), self._startup(startup)
        if answers:
            target = mode.answer(target["id"], target["answers"] + [str(a) for a in answers])  # adds to earlier answers
        if skip and target["status"] == "interview":
            target = mode.skip_questions(target["id"])
        if target["status"] == "interview":
            left = target["questions"][len(target["answers"]):]
            return _text(f"Saved. {len(left)} questions left:\n" + "\n".join(f"- {q}" for q in left))
        team = ", ".join(f"{p['emoji']} {p['name']} ({p['title']})" for p in mode.detail(target["id"])["team"])
        return _text(f"🚀 {target['name']} is running. The team ({team}) meets every "
                     f"{target['min_minutes']}–{target['max_minutes']} minutes; the first meeting is in about a minute.")

    def tool_run_startup_meeting(self, startup):
        mode, target = self._startups(), self._startup(startup)
        if target["status"] == "interview":
            raise ToolError("Answer or skip the follow-up questions first.")
        threading.Thread(target=mode.run_round, args=(target["id"],), daemon=True).start()
        return _text(f"The {target['name']} team is meeting now. It takes a few minutes; then use get_startup.")

    # ---- replies → MCP content

    def _content(self, replies, embed_images=False):
        content = []
        for reply in replies:
            text = reply.text.strip()
            links = [f"{kind}: {url}" for kind, url in reply.media]
            if text or links:
                content += _text("\n".join([text] + links).strip())
            if embed_images:
                for kind, url in reply.media:
                    if kind != "image":
                        continue
                    try:
                        data, mime = self.fetch(url)
                        content.append({"type": "image", "data": base64.b64encode(data).decode(), "mimeType": mime})
                    except Exception as e:
                        log.warning("mcp: couldn't embed %s: %s", url, e)
        return content or _text("(no answer)")

    @staticmethod
    def _fetch(url):
        # Media links point at the Mac's localhost; from inside Docker that's host.docker.internal.
        for candidate in (url, url.replace("://localhost:", "://host.docker.internal:")):
            try:
                with urllib.request.urlopen(candidate, timeout=30) as resp:
                    return resp.read(), resp.headers.get_content_type() or "image/png"
            except OSError:
                continue
        raise OSError(f"can't fetch {url}")
