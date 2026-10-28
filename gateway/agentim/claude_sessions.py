"""Existing Claude Code sessions on the Mac, through the native runner (which enforces the workspace scope).

Chat: `/claude` lists them, `/claude <n>` shows the latest messages, `/claude <n> <message>` continues the session.
"""

import json
import logging
import os
import time
import urllib.error
import urllib.request

log = logging.getLogger("agentim.claude")


class ClaudeSessions:
    def __init__(self, config, opener=urllib.request.urlopen):
        self.config, self.opener = config, opener

    def call(self, path, body=None, timeout=30):
        """Tries each runner; the native one on the Mac is the one that can see the sessions."""
        problem = "No runner on this Mac answered. Install the always-on helpers (install.sh)."
        for base in self.config.runner_urls:
            data = json.dumps(body).encode() if body is not None else None
            req = urllib.request.Request(f"{base}{path}", data=data, method="POST" if body is not None else "GET",
                                         headers={"Authorization": f"Bearer {self.config.runner_token}",
                                                  "Content-Type": "application/json"})
            try:
                with self.opener(req, timeout=timeout) as resp:
                    return json.loads(resp.read())
            except urllib.error.HTTPError as e:
                try:
                    problem = json.loads(e.read()).get("error", {}).get("message") or problem
                except Exception:
                    problem = f"HTTP {e.code}"
                if e.code == 400:  # the native runner answered with a real reason
                    break
            except (urllib.error.URLError, OSError):
                continue
        raise RuntimeError(problem)

    def list(self):
        return self.call("/v1/claude/sessions")["sessions"]

    def read(self, session_id):
        return self.call(f"/v1/claude/sessions/{session_id}")

    def continue_session(self, session_id, prompt):
        return self.call(f"/v1/claude/sessions/{session_id}/continue", {"prompt": prompt}, timeout=1200)

    # ---- chat

    @staticmethod
    def label(session):
        title = session.get("title") or (session.get("first_prompt") or "untitled")[:60]
        folder = os.path.basename(session.get("cwd") or "")
        ago = max(0, int((time.time() - session.get("updated", time.time())) / 60))
        when = f"{ago} min ago" if ago < 60 else f"{ago // 60} h ago" if ago < 2880 else f"{ago // 1440} days ago"
        return f"*{title}* · {folder} · {when}"

    def command(self, arg):
        arg = arg.strip()
        number, _, prompt = arg.partition(" ")
        try:
            sessions = self.list()
            if not arg:
                if not sessions:
                    return "🤖 No Claude Code sessions in your workspaces yet."
                lines = [f"{i}. {self.label(s)}" for i, s in enumerate(sessions[:10], 1)]
                return ("🤖 *Claude Code sessions*\n" + "\n".join(lines) +
                        "\n\n`/claude <n>` read · `/claude <n> <message>` continue")
            if not number.isdigit() or not 1 <= int(number) <= len(sessions):
                return "🤔 Which one? Send `/claude` for the numbered list."
            session = sessions[int(number) - 1]
            if not prompt.strip():
                detail = self.read(session["id"])
                lines = [f"{'🧑' if m['role'] == 'user' else '🤖'} {m['text'][:400]}" for m in detail["messages_shown"][-6:]]
                return f"🤖 {self.label(session)}\n\n" + "\n\n".join(lines)
            result = self.continue_session(session["id"], prompt)
            return f"🤖 Claude Code ({os.path.basename(result['cwd'])}):\n\n{result['reply']}"
        except RuntimeError as e:
            return f"🙈 {e}"
