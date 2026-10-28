#!/usr/bin/env python3
"""agentim MCP bridge (stdio ↔ the gateway's /mcp endpoint), for Claude Desktop, Claude Code and other
apps that launch local MCP servers.

    python3 agentim_mcp.py            # reads JSON-RPC lines on stdin, writes responses on stdout

The token comes from AGENTIM_TOKEN or the installed stack's .env; the gateway URL from AGENTIM_URL
(default http://localhost:8780/mcp). Standard library only.
"""

import json
import os
import sys
import urllib.error
import urllib.request

ENV_FILE = os.path.expanduser("~/Library/Application Support/agentim/stack/.env")


def read_env(path=ENV_FILE):
    values = {}
    try:
        with open(path) as f:
            for line in f:
                key, sep, value = line.strip().partition("=")
                if sep and not key.startswith("#"):
                    values[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def settings(environ=os.environ, env_file=ENV_FILE):
    env = read_env(env_file)
    token = environ.get("AGENTIM_TOKEN") or env.get("AGENTIM_API_TOKEN") or env.get("RUNNER_TOKEN", "")
    url = environ.get("AGENTIM_URL") or f"http://localhost:{env.get('AGENTIM_PORT', '8780')}/mcp"
    return url, token


def forward(message, url, token, opener=urllib.request.urlopen):
    """Posts one JSON-RPC message; returns the response dict, or None for notifications."""
    request = urllib.request.Request(url, data=json.dumps(message).encode(), method="POST", headers={
        "Content-Type": "application/json", "Accept": "application/json, text/event-stream",
        "Authorization": f"Bearer {token}"})
    try:
        with opener(request, timeout=1800) as resp:
            body = resp.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as e:
        problem = "agentim rejected the token (check AGENTIM_API_TOKEN in .env)" if e.code == 401 else f"HTTP {e.code}"
    except (urllib.error.URLError, OSError) as e:
        problem = f"agentim isn't running at {url} ({getattr(e, 'reason', e)}). Open the agentim app or start the stack."
    if isinstance(message, dict) and message.get("id") is not None:
        return {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32000, "message": problem}}
    return None


def main(stdin=sys.stdin, stdout=sys.stdout):
    url, token = settings()
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            response = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
        else:
            response = forward(message, url, token)
        if response is not None:
            stdout.write(json.dumps(response) + "\n")
            stdout.flush()


if __name__ == "__main__":
    main()
