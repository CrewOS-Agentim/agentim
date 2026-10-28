"""Gateway HTTP API: health, status, the WhatsApp webhook, and a message endpoint for the app and demos."""

import json
import logging
import secrets
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from . import __version__

log = logging.getLogger("agentim.server")


def make_handler(gateway, channels, catalog):
    config = gateway.config

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def send_json(self, status, payload):
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def authorized(self):
            expected = f"Bearer {config.api_token}"
            if config.api_token and secrets.compare_digest(self.headers.get("Authorization", ""), expected):
                return True
            self.send_json(401, {"error": "missing or wrong token"})
            return False

        def read_json(self):
            length = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(length) or b"{}")

        def log_message(self, fmt, *args):
            log.debug("%s %s", self.address_string(), fmt % args)

        def do_GET(self):
            path = urllib.parse.urlparse(self.path).path
            if path == "/health":
                return self.send_json(200, {"ok": True, "version": __version__})
            if path.startswith("/v1/startups"):
                if self.authorized():
                    self.startups_get(path)
                return
            if path != "/v1/status":
                return self.send_json(404, {"error": "not found"})
            if self.authorized():
                self.send_json(200, {
                    "version": __version__,
                    "channels": {c.name: c.status for c in channels.values()},
                    "agents": [{"name": a.name, "emoji": a.emoji, "summary": a.summary} for a in config.agents],
                    "skills": [{"name": s.name, "slug": s.slug, "summary": s.summary} for s in gateway.skills],
                    "models": [{"id": m.id, "alias": m.alias, "local": m.local} for m in catalog()],
                })

        def do_POST(self):
            url = urllib.parse.urlparse(self.path)
            if url.path == "/webhooks/whatsapp":
                secret = urllib.parse.parse_qs(url.query).get("secret", [""])[0]
                if not config.webhook_secret or not secrets.compare_digest(secret, config.webhook_secret):
                    return self.send_json(401, {"error": "bad webhook secret"})
                channel = channels.get("whatsapp")
                handled = channel.on_webhook(self.read_json()) if channel else False
                return self.send_json(200, {"handled": handled})
            if url.path.startswith("/v1/startups"):
                if self.authorized():
                    self.startups_post(url.path)
                return
            if url.path != "/v1/messages":
                return self.send_json(404, {"error": "not found"})
            if self.authorized():
                # Synchronous: used by the demo script and the iOS app. Same rules as a real channel.
                body = self.read_json()
                replies = gateway.handle("api", body.get("chat_id", "default"), "api", body.get("text", ""))
                self.send_json(200, {"replies": [{"text": r.text, "media": [
                    {"kind": k, "url": u} for k, u in r.media]} for r in replies]})

        def do_DELETE(self):
            path = urllib.parse.urlparse(self.path).path
            parts = path.strip("/").split("/")
            if len(parts) != 3 or parts[:2] != ["v1", "startups"]:
                return self.send_json(404, {"error": "not found"})
            if self.authorized() and self.startup_mode():
                gateway.startup.delete(parts[2])
                self.send_json(200, {"deleted": parts[2]})

        # ---- Startup Mode API (the Mac app's Startups section)

        def startup_mode(self):
            if gateway.startup:
                return True
            self.send_json(404, {"error": "startup mode unavailable"})
            return False

        def startups_get(self, path):
            if not self.startup_mode():
                return
            parts = path.strip("/").split("/")  # v1/startups[/id]
            if len(parts) == 2:
                return self.send_json(200, gateway.startup.listing())
            detail = gateway.startup.detail(parts[2]) if len(parts) == 3 else None
            self.send_json(200, detail) if detail else self.send_json(404, {"error": "no such startup"})

        def startups_post(self, path):
            if not self.startup_mode():
                return
            startup, parts, body = gateway.startup, path.strip("/").split("/"), self.read_json()
            try:
                if len(parts) == 2:  # create: pitch → follow-up questions
                    created = startup.create(body.get("pitch", ""), body.get("name"),
                                             min_minutes=body.get("min_minutes", 10), max_minutes=body.get("max_minutes", 30),
                                             team=body.get("team"))
                    return self.send_json(201, startup.detail(created["id"]))
                startup_id = parts[2]
                if not startup.store.get(startup_id):
                    return self.send_json(404, {"error": "no such startup"})
                action = parts[3] if len(parts) == 4 else ""
                if action == "answers":
                    if body.get("skip"):
                        startup.skip_questions(startup_id)
                    else:
                        startup.answer(startup_id, body.get("answers", []))
                elif action == "team":
                    startup.set_team(startup_id, body.get("team"))
                elif action == "run":
                    threading.Thread(target=startup.run_round, args=(startup_id,), daemon=True).start()
                    return self.send_json(202, {"started": True})
                elif action == "":
                    startup.update(startup_id, **body)
                else:
                    return self.send_json(404, {"error": "not found"})
                self.send_json(200, startup.detail(startup_id))
            except ValueError as e:
                self.send_json(400, {"error": str(e)})

    return Handler


def serve(gateway, channels, catalog, port):
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(gateway, channels, catalog))
    log.info("gateway API on :%d", port)
    server.serve_forever()
