#!/usr/bin/env python3
"""agentim runner: lets agentim (the gateway and the Mac app) use models on this computer.

Runs natively (`python3 runner.py`) or in Docker. Standard library only.

- Aggregates local backends (Ollama, LM Studio, llama.cpp, vLLM, Docker Model
  Runner) behind one OpenAI-compatible API: `GET /v1/models`, `POST /v1/chat/completions`.
- Reports this host's memory and checks a model fits before pulling it.
- Bridges LTX Desktop (video/image generation) into chat when run natively on the Mac.
"""

import json
import os
import platform
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.1.0"
MB = 1024 * 1024
IN_CONTAINER = os.path.exists("/.dockerenv") or os.environ.get("RUNNER_IN_CONTAINER") == "1"
STATE_DIR = os.path.expanduser(os.environ.get("RUNNER_STATE_DIR", "~/.agenthub-runner"))
FILES_DIR = os.path.join(STATE_DIR, "files")


# ---------------------------------------------------------------- config

def default_backends():
    host = "host.docker.internal" if IN_CONTAINER else "localhost"
    return {
        "ollama": os.environ.get("OLLAMA_URL", f"http://{host}:11434"),
        "lmstudio": os.environ.get("LMSTUDIO_URL", f"http://{host}:1234/v1"),
        "llamacpp": os.environ.get("LLAMACPP_URL", f"http://{host}:8080/v1"),
        "vllm": os.environ.get("VLLM_URL", f"http://{host}:8000/v1"),
        "docker": os.environ.get(
            "DOCKER_MODEL_RUNNER_URL",
            "http://model-runner.docker.internal/engines/v1" if IN_CONTAINER else "http://localhost:12434/engines/v1"),
    }


BACKENDS = {k: v.rstrip("/") for k, v in default_backends().items() if v}
for name in filter(None, os.environ.get("RUNNER_DISABLE", "").split(",")):
    BACKENDS.pop(name.strip(), None)


def load_token():
    """Pairing token the app sends as `Authorization: Bearer`. Generated once and kept."""
    if os.environ.get("RUNNER_TOKEN"):
        return os.environ["RUNNER_TOKEN"]
    path = os.path.join(STATE_DIR, "token")
    if os.path.exists(path):
        return open(path).read().strip()
    os.makedirs(STATE_DIR, exist_ok=True)
    token = secrets.token_urlsafe(24)
    with open(path, "w") as f:
        f.write(token)
    os.chmod(path, 0o600)
    return token


# ---------------------------------------------------------------- memory

def host_memory():
    """(total, available, ceiling) in bytes. The ceiling is the most one model may use."""
    system = platform.system()
    if system == "Darwin":
        total = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"]))
        out = subprocess.check_output(["vm_stat"]).decode()
        page = int(re.search(r"page size of (\d+)", out).group(1))
        pages = lambda key: int(re.search(rf"{key}:\s+(\d+)", out).group(1)) if re.search(rf"{key}:\s+(\d+)", out) else 0
        available = (pages("Pages free") + pages("Pages inactive") + pages("Pages purgeable")
                     + pages("Pages speculative")) * page
        # Apple silicon lets the GPU wire roughly 75% of unified memory.
        return total, available, int(total * 0.75)

    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            key, value = line.split(":", 1)
            info[key] = int(value.split()[0]) * 1024
    total, available = info["MemTotal"], info.get("MemAvailable", info["MemFree"])
    # Respect a container memory limit when one is set.
    for path in ("/sys/fs/cgroup/memory.max", "/sys/fs/cgroup/memory/memory.limit_in_bytes"):
        try:
            limit = open(path).read().strip()
            if limit.isdigit() and int(limit) < total:
                total = int(limit)
                available = min(available, total)
        except OSError:
            pass
    return total, available, int(total * 0.9)


def gpus():
    if shutil.which("nvidia-smi"):
        try:
            out = subprocess.check_output(
                ["nvidia-smi", "--query-gpu=name,memory.total,memory.free", "--format=csv,noheader,nounits"],
                timeout=5).decode()
            return [{"name": n.strip(), "memory_bytes": int(t) * MB, "free_bytes": int(f) * MB}
                    for n, t, f in (line.split(",") for line in out.strip().splitlines())]
        except Exception:
            return []
    if platform.system() == "Darwin" and platform.machine() == "arm64":
        return [{"name": "Apple silicon (unified memory)", "memory_bytes": None, "free_bytes": None}]
    return []


def required_bytes(weight_bytes):
    """Weights + KV cache/activations (~20%) + runtime overhead. Same rule as the Mac app."""
    return int(weight_bytes * 1.2) + 512 * MB


def assess(weight_bytes, total=None, available=None, ceiling=None, free_disk=None):
    if total is None:
        total, available, ceiling = host_memory()
    if free_disk is None:
        free_disk = shutil.disk_usage(STATE_DIR if os.path.exists(STATE_DIR) else "/").free
    required = required_bytes(weight_bytes)
    vram = max((g["memory_bytes"] or 0 for g in gpus()), default=0)
    if required > ceiling:
        verdict = "too_large"
    elif weight_bytes + 512 * MB > free_disk:
        verdict = "not_enough_disk"
    elif required > available:
        verdict = "tight"
    else:
        verdict = "fits"
    return {
        "verdict": verdict,
        "can_pull": verdict in ("fits", "tight"),
        "weight_bytes": weight_bytes,
        "required_bytes": required,
        "available_bytes": available,
        "ceiling_bytes": ceiling,
        "total_bytes": total,
        "free_disk_bytes": free_disk,
        # On NVIDIA hosts, whether the whole model fits in VRAM (otherwise it runs partly on CPU).
        "fits_gpu": (required <= vram) if vram else None,
    }


# ---------------------------------------------------------------- model sizes

def http_json(url, headers=None, data=None, method=None, timeout=15):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read() or b"null")


def parse_ollama_ref(ref):
    """'qwen3:0.6b' -> ('registry.ollama.ai', 'library/qwen3', '0.6b'); 'hf.co/a/b:Q4_K_M' -> ('hf.co', 'a/b', 'Q4_K_M')."""
    name, _, tag = ref.partition(":")
    if name.startswith(("hf.co/", "huggingface.co/")):
        return "hf.co", name.split("/", 1)[1], tag or "Q4_K_M"
    if "/" not in name:
        name = f"library/{name}"
    return "registry.ollama.ai", name, tag or "latest"


def weight_size(ref, hf_token=None):
    """Download size of an Ollama reference, looked up before pulling anything."""
    registry, repo, tag = parse_ollama_ref(ref)
    if registry == "hf.co":
        headers = {"Authorization": f"Bearer {hf_token}"} if hf_token else {}
        files = http_json(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true", headers)
        return gguf_size(files, tag)
    manifest = http_json(
        f"https://registry.ollama.ai/v2/{repo}/manifests/{tag}",
        {"Accept": "application/vnd.docker.distribution.manifest.v2+json"})
    return sum(layer["size"] for layer in manifest["layers"])


def gguf_size(files, quant):
    quant = quant.lower()
    matches = [f for f in files if f.get("path", "").lower().endswith(".gguf") and quant in f["path"].lower()]
    if not matches:
        raise ValueError(f"no .gguf file matching '{quant}'")
    return sum(f.get("size", 0) for f in matches)


# ---------------------------------------------------------------- backends

def backend_status():
    """Probes every backend in parallel so a few dead ones don't stall the app."""
    status = {}

    def probe(name, url):
        try:
            http_json(f"{url}/api/version" if name == "ollama" else f"{url}/models", timeout=1.5)
            status[name] = {"url": url, "healthy": True}
        except Exception:
            status[name] = {"url": url, "healthy": False}

    threads = [threading.Thread(target=probe, args=item) for item in BACKENDS.items()]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return {name: status[name] for name in BACKENDS}


NOT_CHAT = re.compile(r"whisper|kokoro|piper|\btts\b|-tts|embed|rerank|speaches|silero", re.I)


def is_chat_model(model_id):
    """Speech, embedding and reranking models can't hold a conversation; never offer them as chat."""
    return not NOT_CHAT.search(model_id)


def list_models():
    models = []
    for name, info in backend_status().items():
        if not info["healthy"]:
            continue
        try:
            if name == "ollama":
                loaded = {m["name"] for m in http_json(f"{info['url']}/api/ps").get("models", [])}
                for m in http_json(f"{info['url']}/api/tags").get("models", []):
                    details = m.get("details", {})
                    models.append({
                        "id": f"ollama/{m['name']}", "object": "model", "owned_by": "ollama", "backend": "ollama",
                        "kind": "chat", "size_bytes": m.get("size"), "family": details.get("family"),
                        "parameter_size": details.get("parameter_size"), "loaded": m["name"] in loaded})
            else:
                for m in http_json(f"{info['url']}/models").get("data", []):
                    models.append({"id": f"{name}/{m['id']}", "object": "model", "owned_by": name,
                                   "backend": name, "kind": "chat"})
        except Exception as e:
            print(f"[runner] listing {name} failed: {e}", file=sys.stderr)
    models = [m for m in models if is_chat_model(m["id"])]
    for name in LOCAL_AGENTS.available():
        models.append({"id": f"local/{name}", "object": "model", "owned_by": name, "backend": "local", "kind": "agent",
                       "name": LocalAgents.COMMANDS[name]["name"]})
    if LTX.available() or LTX.installed():
        models += [
            {"id": "ltx/video", "object": "model", "owned_by": "ltx", "backend": "ltx", "kind": "video"},
            {"id": "ltx/image", "object": "model", "owned_by": "ltx", "backend": "ltx", "kind": "image"},
        ]
    return models


def openai_base(backend):
    url = BACKENDS[backend]
    return f"{url}/v1" if backend == "ollama" else url


# ---------------------------------------------------------------- LTX Desktop bridge

class LTXBridge:
    """Finds the LTX Desktop backend (localhost, random port, token in its environment).

    Only works when the runner runs natively on the same Mac, or when LTX_URL and
    LTX_TOKEN are given explicitly.
    """

    def __init__(self):
        self.lock = threading.Lock()

    def endpoint(self):
        if os.environ.get("LTX_URL"):
            return os.environ["LTX_URL"].rstrip("/"), os.environ.get("LTX_TOKEN", "")
        if IN_CONTAINER or platform.system() != "Darwin":
            return None
        try:
            pid = subprocess.check_output(["pgrep", "-f", "backend/ltx2_server"]).decode().split()[0]
            env = subprocess.check_output(["ps", "-E", "-p", pid, "-o", "command="]).decode()
            token = re.search(r"LTX_AUTH_TOKEN=(\S+)", env).group(1)
            listening = subprocess.check_output(["lsof", "-nP", "-a", "-p", pid, "-iTCP", "-sTCP:LISTEN"]).decode()
            port = re.search(r"127\.0\.0\.1:(\d+) \(LISTEN\)", listening).group(1)
            return f"http://127.0.0.1:{port}", token
        except Exception:
            return None

    APP_PATHS = ["/Applications/LTX Desktop.app", os.path.expanduser("~/Applications/LTX Desktop.app")]

    def installed(self):
        """LTX Desktop is on this Mac (it can be opened on demand), even if it isn't running."""
        if os.environ.get("LTX_URL") or IN_CONTAINER or platform.system() != "Darwin":
            return False
        return any(os.path.isdir(path) for path in self.APP_PATHS)

    def ensure_running(self, wait=180, sleep=time.sleep):
        """Opens LTX Desktop if it's installed but closed, then waits for its backend."""
        if self.available():
            return self.endpoint()
        if not self.installed():
            raise RuntimeError("LTX Desktop isn't installed on this Mac. Get it from ltx.studio, then try again.")
        app = next(path for path in self.APP_PATHS if os.path.isdir(path))
        print("[runner] opening LTX Desktop", file=sys.stderr)
        subprocess.run(["open", "-g", app], check=False)
        deadline = time.time() + wait
        while time.time() < deadline:
            if self.available():
                return self.endpoint()
            sleep(3)
        raise RuntimeError("LTX Desktop didn't start in time. Open it once, let it finish loading, then try again.")

    def available(self):
        endpoint = self.endpoint()
        if not endpoint:
            return False
        try:
            urllib.request.urlopen(urllib.request.Request(
                f"{endpoint[0]}/health", headers={"Authorization": f"Bearer {endpoint[1]}"}), timeout=2)
            return True
        except Exception:
            return False

    def generate(self, kind, prompt):
        """Blocks until LTX finishes. Returns the local path of the result."""
        endpoint = self.ensure_running() if not os.environ.get("LTX_URL") else self.endpoint()
        if not endpoint:
            raise RuntimeError("LTX Desktop isn't running on this computer.")
        base, token = endpoint
        if kind == "image":
            path, body = "/api/generate-image", {"prompt": prompt, "width": 1280, "height": 720, "numSteps": 8, "numImages": 1}
        else:
            path, body = "/api/generate", {"prompt": prompt, "resolution": "720p", "model": "fast",
                                           "duration": 4, "fps": 24, "audio": True, "aspectRatio": "16:9"}
        req = urllib.request.Request(base + path, data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
        with self.lock:
            try:
                result = json.loads(urllib.request.urlopen(req, timeout=1800).read())
            except urllib.error.HTTPError as e:
                if e.code == 409:
                    raise RuntimeError("LTX Desktop is busy with another generation. Try again when it finishes.")
                raise RuntimeError(f"LTX HTTP {e.code}: {e.read()[:200]!r}")
        if result.get("status") != "complete":
            raise RuntimeError(f"LTX didn't finish: {result}")
        return result["image_paths"][0] if kind == "image" else result["video_path"]


LTX = LTXBridge()


# ---------------------------------------------------------------- task log (Status page)

class TaskLog:
    """Every model request this runner handles: what's running now and the recent history (kept on disk)."""

    def __init__(self, path=None, keep=500, clock=time.time):
        self.path, self.keep, self.clock = path, keep, clock
        self.lock = threading.Lock()
        self.running = {}
        self.history = []
        if path and os.path.exists(path):
            try:
                with open(path) as f:
                    self.history = [json.loads(line) for line in f if line.strip()][-keep:]
            except (OSError, ValueError):
                self.history = []

    def start(self, model, label, preview=""):
        task = {"id": uuid.uuid4().hex[:12], "model": model, "label": label or "Chat",
                "preview": " ".join(preview.split())[:90], "started": self.clock()}
        with self.lock:
            self.running[task["id"]] = task
        return task["id"]

    def finish(self, task_id, error=None):
        with self.lock:
            task = self.running.pop(task_id, None)
            if not task:
                return None
            task.update(ended=self.clock(), ok=error is None, error=(error or "")[:200] or None)
            task["seconds"] = round(task["ended"] - task["started"], 2)
            self.history.append(task)
            self.history = self.history[-self.keep:]
            if self.path:
                try:
                    os.makedirs(os.path.dirname(self.path), exist_ok=True)
                    with open(self.path, "a") as f:
                        f.write(json.dumps(task) + "\n")
                    if sum(1 for _ in open(self.path)) > 2 * self.keep:  # trim now and then
                        with open(self.path, "w") as f:
                            f.writelines(json.dumps(t) + "\n" for t in self.history)
                except OSError:
                    pass
        return task

    def snapshot(self, limit=200):
        now = self.clock()
        with self.lock:
            running = [{**t, "seconds": round(now - t["started"], 1)} for t in self.running.values()]
            recent = list(reversed(self.history))[:limit]
        return {"running": sorted(running, key=lambda t: t["started"]), "recent": recent, "now": now}


TASKS = TaskLog(os.path.join(STATE_DIR, "tasks.jsonl"))


# ---------------------------------------------------------------- memory: what's loaded, unload, stop LTX

def loaded_models():
    """Models Ollama has in memory right now (they unload by themselves after OLLAMA_KEEP_ALIVE)."""
    if "ollama" not in BACKENDS:
        return []
    try:
        data = http_json(f"{BACKENDS['ollama']}/api/ps")
    except Exception:
        return []
    return [{"id": f"ollama/{m['name']}", "name": m["name"], "size_bytes": m.get("size"),
             "vram_bytes": m.get("size_vram"), "until": m.get("expires_at")} for m in data.get("models", [])]


def unload_models(model=None):
    """Frees memory now: asks Ollama to drop the model(s) (keep_alive 0). They load again on the next chat."""
    unloaded = []
    for m in loaded_models():
        if model and model not in (m["id"], m["name"]):
            continue
        req = urllib.request.Request(f"{BACKENDS['ollama']}/api/generate", method="POST",
                                     data=json.dumps({"model": m["name"], "keep_alive": 0}).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=60).read()
            unloaded.append(m["id"])
        except Exception as e:
            print(f"[runner] couldn't unload {m['name']}: {e}", file=sys.stderr)
    return unloaded


def stop_ltx(run=subprocess.run):
    """Quits LTX Desktop to free its GPU memory (the runner opens it again when a video or image is asked for)."""
    if IN_CONTAINER or platform.system() != "Darwin":
        return False
    was_running = LTX.available()
    run(["osascript", "-e", 'tell application "LTX Desktop" to quit'], capture_output=True, timeout=30)
    return was_running


# ---------------------------------------------------------------- local coding agents

class LocalAgents:
    """Hands a task to a coding agent installed on this Mac (Claude Code, OpenAI Codex, Gemini CLI).

    Off unless AGENTIM_LOCAL_AGENTS lists the ones to allow (e.g. "claude-code,codex"). They only run in
    folders listed in AGENTIM_WORKSPACES (":"-separated), read-only unless AGENTIM_LOCAL_AGENTS_MODE=edit,
    and each agent keeps its own permission system. With AGENTIM_LOCAL_AGENTS_TMUX=1 (and tmux installed)
    each run happens in a tmux session you can watch: `tmux attach -t agentim-…`.
    """

    # {prompt} is replaced by the task; the agent's own sandbox/permission flags do the enforcing.
    COMMANDS = {
        "claude-code": {"bin": "claude", "name": "Claude Code",
                        "read": ["-p", "{prompt}", "--permission-mode", "plan", "--output-format", "text"],
                        "edit": ["-p", "{prompt}", "--permission-mode", "acceptEdits", "--output-format", "text"]},
        "codex": {"bin": "codex", "name": "OpenAI Codex",
                  "read": ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "{prompt}"],
                  "edit": ["exec", "--sandbox", "workspace-write", "--skip-git-repo-check", "{prompt}"]},
        "gemini": {"bin": "gemini", "name": "Gemini CLI",
                   "read": ["-p", "{prompt}"], "edit": ["-p", "{prompt}", "--approval-mode", "auto_edit"]},
    }
    SEARCH_PATH = [os.path.expanduser("~/.local/bin"), "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    ENV_FILE = os.environ.get("AGENTIM_ENV_FILE") or os.path.expanduser(
        "~/Library/Application Support/agentim/stack/.env")
    KEYS = ("AGENTIM_LOCAL_AGENTS", "AGENTIM_WORKSPACES", "AGENTIM_LOCAL_AGENTS_MODE", "AGENTIM_LOCAL_AGENTS_TMUX",
            "AGENTIM_LOCAL_AGENTS_TIMEOUT")

    def __init__(self, env=None, which=shutil.which, run=subprocess.run, clock=time.time):
        self.fixed_env, self.which, self.run, self.clock = env, which, run, clock

    @property
    def env(self):
        """Settings from the process environment, overridden by the stack's .env (so edits apply right away)."""
        if self.fixed_env is not None:
            return self.fixed_env
        values = {k: os.environ[k] for k in self.KEYS if k in os.environ}
        try:
            with open(self.ENV_FILE) as f:
                for line in f:
                    key, sep, value = line.strip().partition("=")
                    if sep and key in self.KEYS:
                        values[key] = value.strip().strip('"').strip("'")
        except OSError:
            pass
        return values

    def allowed(self):
        raw = self.env.get("AGENTIM_LOCAL_AGENTS", "").strip().lower()
        if raw in ("", "off", "0", "false", "no"):
            return []
        names = list(self.COMMANDS) if raw in ("on", "all", "1", "true", "yes") else [n.strip() for n in raw.split(",")]
        return [n for n in names if n in self.COMMANDS]

    def binary(self, name):
        return self.which(self.COMMANDS[name]["bin"], path=os.pathsep.join(self.SEARCH_PATH))

    def available(self):
        if IN_CONTAINER:
            return []
        return [n for n in self.allowed() if self.binary(n)]

    def workspaces(self):
        return [os.path.realpath(os.path.expanduser(w)) for w in self.env.get("AGENTIM_WORKSPACES", "").split(":") if w.strip()]

    def workspace_for(self, prompt):
        """The workspace named in the prompt (by folder name or path), else the first one."""
        spaces = self.workspaces()
        if not spaces:
            raise RuntimeError("No workspace set. Add AGENTIM_WORKSPACES=/path/to/project to .env.")
        for space in spaces:
            if space in prompt or os.path.basename(space) in prompt.split():
                return space
        return spaces[0]

    def mode(self):
        return "edit" if self.env.get("AGENTIM_LOCAL_AGENTS_MODE", "read").lower() == "edit" else "read"

    def command(self, name, prompt):
        spec = self.COMMANDS[name]
        return [self.binary(name)] + [prompt if part == "{prompt}" else part for part in spec[self.mode()]]

    def run_task(self, name, prompt, timeout=None):
        if name not in self.available():
            raise RuntimeError(f"{name} isn't enabled on this Mac (AGENTIM_LOCAL_AGENTS) or isn't installed.")
        if not prompt.strip():
            raise RuntimeError("Tell the agent what to do.")
        cwd = self.workspace_for(prompt)
        timeout = timeout or int(self.env.get("AGENTIM_LOCAL_AGENTS_TIMEOUT", "900"))
        cmd = self.command(name, prompt)
        if self.env.get("AGENTIM_LOCAL_AGENTS_TMUX") in ("1", "true", "yes") and self.which("tmux"):
            return self.run_in_tmux(name, cmd, cwd, timeout)
        result = self.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        output = (result.stdout or "").strip() or (result.stderr or "").strip()
        if result.returncode != 0:
            raise RuntimeError(f"{self.COMMANDS[name]['name']} exited with {result.returncode}: {output[-800:]}")
        return output, cwd

    def run_in_tmux(self, name, cmd, cwd, timeout):
        session = f"agentim-{name}-{uuid.uuid4().hex[:6]}"
        log_file = os.path.join(FILES_DIR, f"{session}.log")
        os.makedirs(FILES_DIR, exist_ok=True)
        quoted = " ".join(shlex.quote(c) for c in cmd)
        script = f"{quoted} > {shlex.quote(log_file)} 2>&1; echo $? > {shlex.quote(log_file)}.exit"
        self.run(["tmux", "new-session", "-d", "-s", session, "-c", cwd, script], check=True)
        deadline = self.clock() + timeout
        while self.clock() < deadline:
            if os.path.exists(log_file + ".exit"):
                output = open(log_file).read().strip()
                code = open(log_file + ".exit").read().strip()
                if code != "0":
                    raise RuntimeError(f"{self.COMMANDS[name]['name']} exited with {code}: {output[-800:]}")
                return output, cwd
            time.sleep(2)
        self.run(["tmux", "kill-session", "-t", session])
        raise RuntimeError(f"{self.COMMANDS[name]['name']} didn't finish in {timeout} s (tmux session {session}).")


LOCAL_AGENTS = LocalAgents()


class ClaudeSessions:
    """Existing Claude Code sessions (~/.claude/projects/*/<session>.jsonl), only for folders in AGENTIM_WORKSPACES
    and only when Claude Code is enabled as a local agent. Reads the conversation text (no tool output or thinking);
    continuing a session runs `claude --resume <id>` in its folder with the local agents' permission mode."""

    ID = re.compile(r"^[0-9a-f-]{8,64}$")

    def __init__(self, agents=None, root=None):
        self.agents = agents or LOCAL_AGENTS
        self.root = root or os.path.expanduser("~/.claude/projects")

    def enabled(self):
        return "claude-code" in self.agents.available()

    def in_workspace(self, cwd):
        cwd = os.path.realpath(cwd or "")
        return any(cwd == w or cwd.startswith(w + os.sep) for w in self.agents.workspaces())

    @staticmethod
    def encoded(path):
        """Claude Code names a project folder after its path: /Users/me/code.app → -Users-me-code-app."""
        return re.sub(r"[^A-Za-z0-9-]", "-", path)

    def files(self, workspaces_only=False):
        try:
            names = os.listdir(self.root)
        except OSError:
            return []
        if workspaces_only:
            # Skip other projects without opening their (often large) transcripts.
            prefixes = [self.encoded(w) for w in self.agents.workspaces()]
            names = [n for n in names if any(n == p or n.startswith(p + "-") for p in prefixes)]
        folders = [os.path.join(self.root, d) for d in names]
        found = [os.path.join(f, n) for f in folders if os.path.isdir(f) for n in os.listdir(f) if n.endswith(".jsonl")]
        return sorted(found, key=os.path.getmtime, reverse=True)

    @staticmethod
    def text_of(content):
        if isinstance(content, str):
            return content
        return "\n".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")

    def parse(self, path, keep_messages=False):
        info = {"id": os.path.basename(path)[:-6], "cwd": None, "title": None, "updated": os.path.getmtime(path),
                "messages": 0, "first_prompt": None, "branch": None}
        messages = []
        cwds = {}
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    record = json.loads(line)
                except ValueError:
                    continue
                kind = record.get("type")
                if record.get("cwd"):
                    cwds[record["cwd"]] = cwds.get(record["cwd"], 0) + 1
                info["branch"] = record.get("gitBranch") or info["branch"]
                if kind == "custom-title" and record.get("customTitle"):
                    info["title"] = record["customTitle"]
                elif kind == "ai-title" and record.get("aiTitle") and not info["title"]:
                    info["title"] = record["aiTitle"]
                if kind not in ("user", "assistant") or record.get("isSidechain") or record.get("isMeta"):
                    continue
                text = self.text_of((record.get("message") or {}).get("content")).strip()
                if not text or text.startswith("<"):  # tool results, command wrappers, system reminders
                    continue
                info["messages"] += 1
                if kind == "user" and not info["first_prompt"]:
                    info["first_prompt"] = text[:200]
                if keep_messages:
                    messages.append({"role": kind, "text": text, "time": record.get("timestamp")})
        # Claude Code files a session under the folder it belongs to (and resumes it from there); a session may
        # have started somewhere else (e.g. ~) before moving into the project.
        folder = os.path.basename(os.path.dirname(path))
        owner = next((c for c in cwds if self.encoded(c) == folder), None)
        info["cwd"] = owner or (max(cwds, key=cwds.get) if cwds else None)
        return (info, messages) if keep_messages else info

    def list(self, limit=20):
        if not self.enabled():
            raise RuntimeError("Enable Claude Code first: AGENTIM_LOCAL_AGENTS=claude-code and AGENTIM_WORKSPACES in .env.")
        sessions = []
        for path in self.files(workspaces_only=True):
            info = self.parse(path)
            if info["messages"] and self.in_workspace(info["cwd"]):
                sessions.append(info)
                if len(sessions) >= limit:
                    break
        return sessions

    def find(self, session_id):
        if not self.ID.match(session_id or ""):
            raise RuntimeError("That isn't a session id.")
        path = next((p for p in self.files() if os.path.basename(p) == f"{session_id}.jsonl"), None)
        if not path:
            raise RuntimeError("No such Claude Code session.")
        return path

    def read(self, session_id, last=20, max_chars=1500):
        if not self.enabled():
            raise RuntimeError("Enable Claude Code first: AGENTIM_LOCAL_AGENTS=claude-code and AGENTIM_WORKSPACES in .env.")
        info, messages = self.parse(self.find(session_id), keep_messages=True)
        if not self.in_workspace(info["cwd"]):
            raise RuntimeError("That session is outside AGENTIM_WORKSPACES.")
        for m in messages:
            m["text"] = m["text"][:max_chars] + ("…" if len(m["text"]) > max_chars else "")
        return {**info, "messages_shown": messages[-last:]}

    def continue_session(self, session_id, prompt, timeout=None):
        session = self.read(session_id, last=1)
        if not prompt.strip():
            raise RuntimeError("Tell Claude Code what to do next.")
        binary = self.agents.binary("claude-code")
        mode = "acceptEdits" if self.agents.mode() == "edit" else "plan"
        cmd = [binary, "-p", prompt, "--resume", session_id, "--permission-mode", mode, "--output-format", "text"]
        timeout = timeout or int(self.agents.env.get("AGENTIM_LOCAL_AGENTS_TIMEOUT", "900"))
        result = self.agents.run(cmd, cwd=session["cwd"], capture_output=True, text=True, timeout=timeout,
                                 stdin=subprocess.DEVNULL)
        output = (result.stdout or "").strip() or (result.stderr or "").strip()
        if result.returncode != 0:
            raise RuntimeError(f"Claude Code exited with {result.returncode}: {output[-800:]}")
        return {"id": session_id, "cwd": session["cwd"], "reply": output}


CLAUDE_SESSIONS = ClaudeSessions()


def publish_file(path):
    """Copies a result into the files dir under an unguessable name and returns its URL path."""
    os.makedirs(FILES_DIR, exist_ok=True)
    name = f"{uuid.uuid4().hex}{os.path.splitext(path)[1].lower()}"
    shutil.copyfile(path, os.path.join(FILES_DIR, name))
    return f"/files/{name}"


# ---------------------------------------------------------------- HTTP

TOKEN = None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = f"AgentHubRunner/{VERSION}"

    # ---- helpers
    def send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def error(self, status, message):
        self.task_error = message  # a failed chat shows as failed in the task log
        self.send_json(status, {"error": {"message": message}})

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def authorized(self):
        if secrets.compare_digest(self.headers.get("Authorization", ""), f"Bearer {TOKEN}"):
            return True
        self.error(401, "Missing or wrong runner token.")
        return False

    def start_sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def sse(self, payload):
        self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
        self.wfile.flush()

    def log_message(self, fmt, *args):
        sys.stderr.write(f"[runner] {self.address_string()} {fmt % args}\n")

    # ---- routes
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/health":
            return self.send_json(200, {"ok": True, "version": VERSION})
        if path.startswith("/files/"):
            return self.serve_file(path[len("/files/"):])
        if not self.authorized():
            return
        if path == "/v1/system":
            total, available, ceiling = host_memory()
            return self.send_json(200, {
                "hostname": socket.gethostname(), "os": f"{platform.system()} {platform.machine()}",
                "version": VERSION, "in_container": IN_CONTAINER,
                "memory": {"total_bytes": total, "available_bytes": available, "ceiling_bytes": ceiling},
                "gpus": gpus(), "backends": backend_status(), "ltx": LTX.available()})
        if path == "/v1/models":
            return self.send_json(200, {"object": "list", "data": list_models()})
        if path == "/v1/tasks":
            return self.send_json(200, TASKS.snapshot())
        if path == "/v1/models/loaded":
            return self.send_json(200, {"models": loaded_models(), "ltx_running": LTX.available()})
        if (path == "/v1/claude/sessions" or path.startswith("/v1/claude/sessions/")) and IN_CONTAINER:
            return self.error(404, "Claude Code sessions are only on the Mac's native runner.")
        if path == "/v1/claude/sessions" or path.startswith("/v1/claude/sessions/"):
            session_id = path[len("/v1/claude/sessions/"):] if path.startswith("/v1/claude/sessions/") else ""
            try:
                if session_id:
                    return self.send_json(200, CLAUDE_SESSIONS.read(session_id))
                return self.send_json(200, {"sessions": CLAUDE_SESSIONS.list()})
            except Exception as e:
                return self.error(400, str(e))
        self.error(404, "Not found")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not self.authorized():
            return
        try:
            body = self.body()
        except ValueError:
            return self.error(400, "Body must be JSON.")
        if path == "/v1/chat/completions":
            return self.chat(body)
        if path.startswith("/v1/claude/sessions/") and IN_CONTAINER:
            return self.error(404, "Claude Code sessions are only on the Mac's native runner.")
        if path.startswith("/v1/claude/sessions/") and path.endswith("/continue"):
            session_id = path[len("/v1/claude/sessions/"):-len("/continue")]
            try:
                return self.send_json(200, CLAUDE_SESSIONS.continue_session(session_id, body.get("prompt", "")))
            except Exception as e:
                return self.error(400, str(e))
        if path == "/v1/models/unload":
            return self.send_json(200, {"unloaded": unload_models(body.get("model"))})
        if path == "/v1/ltx/stop":
            return self.send_json(200, {"stopped": stop_ltx()})
        if path == "/v1/models/check":
            return self.check(body)
        if path == "/v1/models/pull":
            return self.pull(body)
        self.error(404, "Not found")

    def do_DELETE(self):
        path = urllib.parse.urlparse(self.path).path
        if not self.authorized():
            return
        prefix = "/v1/models/ollama/"
        if not path.startswith(prefix):
            return self.error(400, "Only Ollama models can be deleted from the app.")
        name = urllib.parse.unquote(path[len(prefix):])
        try:
            http_json(f"{BACKENDS['ollama']}/api/delete", {"Content-Type": "application/json"},
                      json.dumps({"model": name}).encode(), method="DELETE")
            self.send_json(200, {"deleted": name})
        except Exception as e:
            self.error(502, f"Delete failed: {e}")

    # ---- handlers
    def chat(self, body):
        """Records the request in the task log (Status page), then answers it."""
        prompt = next((m.get("content") for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "")
        label = urllib.parse.unquote(self.headers.get("X-Agentim-Task", "")) or (
            "Mac app chat" if "agentim" in self.headers.get("User-Agent", "") else "API request")
        task_id = TASKS.start(body.get("model", ""), label, prompt if isinstance(prompt, str) else "")
        self.task_error = None
        try:
            return self.answer_chat(body)
        except Exception as e:
            self.task_error = str(e)
            raise
        finally:
            TASKS.finish(task_id, self.task_error)

    def answer_chat(self, body):
        model = body.get("model", "")
        backend, _, name = model.partition("/")
        if backend == "ltx":
            return self.ltx_chat(name, body)
        if backend == "local":
            return self.local_agent_chat(name, body)
        if backend not in BACKENDS or not name:
            return self.error(400, f"Unknown model '{model}'. Use an id from GET /v1/models.")
        body["model"] = name
        req = urllib.request.Request(
            f"{openai_base(backend)}/chat/completions", data=json.dumps(body).encode(), method="POST",
            headers={"Content-Type": "application/json"})
        try:
            upstream = urllib.request.urlopen(req, timeout=600)
        except urllib.error.HTTPError as e:
            return self.error(e.code, e.read().decode(errors="replace")[:500])
        except Exception as e:
            return self.error(502, f"{backend} is unreachable: {e}")
        with upstream:
            self.send_response(200)
            self.send_header("Content-Type", upstream.headers.get("Content-Type", "application/json"))
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            # Relay line by line so tokens reach the client as they're generated.
            for line in upstream:
                self.wfile.write(line)
                self.wfile.flush()

    def render_media(self, kind, body):
        """Runs LTX and returns the reply text with a link to the result (or why it failed)."""
        prompt = next((m["content"] for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "")
        try:
            # Absolute URL built from the address the caller used to reach us.
            url = f"http://{self.headers.get('Host', 'localhost')}{publish_file(LTX.generate(kind, prompt))}"
            return f"Rendered your {kind} with LTX Desktop.\n\n[{kind}]({url})"
        except Exception as e:
            return f"Couldn't render the {kind}: {e}"

    def local_agent_chat(self, name, body):
        """Runs the task with a local coding agent and returns its final answer as a chat completion."""
        prompt = next((m["content"] for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "")
        try:
            output, cwd = LOCAL_AGENTS.run_task(name, prompt)
            mode = "read-only" if LOCAL_AGENTS.mode() == "read" else "can edit files"
            text = f"{output}\n\n_— {LocalAgents.COMMANDS[name]['name']} in {cwd} ({mode})_"
        except subprocess.TimeoutExpired:
            text = f"{LocalAgents.COMMANDS[name]['name']} took too long and was stopped."
        except Exception as e:
            text = f"Couldn't run {name}: {e}"
        if not body.get("stream"):
            return self.send_json(200, {"object": "chat.completion", "model": f"local/{name}", "choices": [
                {"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}]})
        self.start_sse()
        self.sse({"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": text}}]})
        self.wfile.write(b"data: [DONE]\n\n")

    def ltx_chat(self, kind, body):
        if not body.get("stream"):
            # Plain JSON completion, like any OpenAI-compatible server (the gateway uses this).
            return self.send_json(200, {"object": "chat.completion", "model": f"ltx/{kind}", "choices": [
                {"index": 0, "message": {"role": "assistant", "content": self.render_media(kind, body)},
                 "finish_reason": "stop"}]})

        self.start_sse()

        def chunk(text):
            self.sse({"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": text}}]})

        chunk(f"Rendering {kind} with LTX Desktop… ")
        chunk(self.render_media(kind, body))
        self.wfile.write(b"data: [DONE]\n\n")

    def check(self, body):
        model = body.get("model", "")
        try:
            size = weight_size(model, body.get("hf_token"))
        except Exception as e:
            return self.error(404, f"Couldn't find '{model}': {e}")
        self.send_json(200, {"model": model, **assess(size)})

    def pull(self, body):
        model = body.get("model", "")
        if "ollama" not in BACKENDS:
            return self.error(400, "Pulling needs Ollama.")
        try:
            assessment = assess(weight_size(model, body.get("hf_token")))
        except Exception as e:
            return self.error(404, f"Couldn't find '{model}': {e}")
        if not assessment["can_pull"] and not body.get("force"):
            return self.send_json(409, {"error": {"message": "Not enough memory or disk for this model."}, **assessment})

        req = urllib.request.Request(
            f"{BACKENDS['ollama']}/api/pull", data=json.dumps({"model": model, "stream": True}).encode(),
            method="POST", headers={"Content-Type": "application/json"})
        try:
            upstream = urllib.request.urlopen(req, timeout=3600)
        except Exception as e:
            return self.error(502, f"Ollama is unreachable: {e}")
        self.start_sse()
        with upstream:
            for line in upstream:
                if line.strip():
                    self.sse(json.loads(line))
        self.wfile.write(b"data: [DONE]\n\n")

    def serve_file(self, name):
        if not re.fullmatch(r"[0-9a-f]{32}\.[a-z0-9]{2,5}", name):
            return self.error(404, "Not found")
        path = os.path.join(FILES_DIR, name)
        if not os.path.exists(path):
            return self.error(404, "Not found")
        types = {".mp4": "video/mp4", ".mov": "video/quicktime", ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp"}
        size = os.path.getsize(path)
        start, end = 0, size - 1
        # AVPlayer requires byte-range support to play video.
        match = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("Range", ""))
        if match:
            start = int(match.group(1) or 0)
            end = int(match.group(2)) if match.group(2) else size - 1
        self.send_response(206 if match else 200)
        self.send_header("Content-Type", types.get(os.path.splitext(name)[1], "application/octet-stream"))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if match:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                data = f.read(min(1 << 20, remaining))
                if not data:
                    break
                self.wfile.write(data)
                remaining -= len(data)


def lan_addresses():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))
            return [s.getsockname()[0]]
    except OSError:
        return []


def main():
    global TOKEN
    TOKEN = load_token()
    port = int(os.environ.get("RUNNER_PORT", "8765"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    total, available, _ = host_memory()
    print(f"agentim runner {VERSION} on port {port} ({'container' if IN_CONTAINER else 'native'})")
    print(f"Memory: {total / 2**30:.1f} GB total, {available / 2**30:.1f} GB available")
    for name, info in backend_status().items():
        print(f"  {name:9} {info['url']:45} {'up' if info['healthy'] else 'down'}")
    print(f"  ltx       {'up' if LTX.available() else 'not found (run natively on the Mac with LTX Desktop open)'}")
    hosts = lan_addresses() + [f"{socket.gethostname().split('.')[0]}.local"]
    print("\nIn AgentHub → Settings → Local servers, add:")
    for host in hosts:
        print(f"  URL:   http://{host}:{port}")
    print(f"  Token: {TOKEN}\n")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
