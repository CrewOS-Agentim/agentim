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
            if path == "/v1/startup":
                if self.authorized():
                    if not gateway.startup:
                        return self.send_json(404, {"error": "startup mode unavailable"})
                    self.send_json(200, gateway.startup.snapshot())
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
            if url.path in ("/v1/startup", "/v1/startup/run"):
                if not self.authorized():
                    return
                startup = gateway.startup
                if not startup:
                    return self.send_json(404, {"error": "startup mode unavailable"})
                if url.path == "/v1/startup/run":
                    threading.Thread(target=startup.run_round, daemon=True).start()
                    return self.send_json(202, {"started": True})
                body = self.read_json()
                try:
                    if body.get("enabled") is False:
                        startup.stop()
                    else:
                        current = startup.store.get() or {}
                        startup.start(body.get("idea") or current.get("idea", ""),
                                      min_minutes=body.get("min_minutes", current.get("min_minutes", 10)),
                                      max_minutes=body.get("max_minutes", current.get("max_minutes", 30)))
                except ValueError as e:
                    return self.send_json(400, {"error": str(e)})
                return self.send_json(200, startup.snapshot())
            if url.path != "/v1/messages":
                return self.send_json(404, {"error": "not found"})
            if self.authorized():
                # Synchronous: used by the demo script and the iOS app. Same rules as a real channel.
                body = self.read_json()
                replies = gateway.handle("api", body.get("chat_id", "default"), "api", body.get("text", ""))
                self.send_json(200, {"replies": [{"text": r.text, "media": [
                    {"kind": k, "url": u} for k, u in r.media]} for r in replies]})

    return Handler


def serve(gateway, channels, catalog, port):
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(gateway, channels, catalog))
    log.info("gateway API on :%d", port)
    server.serve_forever()
