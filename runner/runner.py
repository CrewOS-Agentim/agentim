#!/usr/bin/env python3
"""AgentHub Runner: lets the AgentHub iOS app use models running on this computer.

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
    """Weights + KV cache/activations (~20%) + runtime overhead. Same rule as the iOS app."""
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
    if LTX.available():
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
        endpoint = self.endpoint()
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
        model = body.get("model", "")
        backend, _, name = model.partition("/")
        if backend == "ltx":
            return self.ltx_chat(name, body)
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
            # Relay line by line so tokens reach the phone as they're generated.
            for line in upstream:
                self.wfile.write(line)
                self.wfile.flush()

    def ltx_chat(self, kind, body):
        prompt = next((m["content"] for m in reversed(body.get("messages", [])) if m.get("role") == "user"), "")
        self.start_sse()

        def chunk(text):
            self.sse({"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": text}}]})

        chunk(f"Rendering {kind} with LTX Desktop… ")
        try:
            # Absolute URL built from the address the phone used to reach us.
            url = f"http://{self.headers.get('Host', 'localhost')}{publish_file(LTX.generate(kind, prompt))}"
            chunk(f"done.\n\n[{kind}]({url})")
        except Exception as e:
            chunk(f"failed: {e}")
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
    print(f"AgentHub Runner {VERSION} on port {port} ({'container' if IN_CONTAINER else 'native'})")
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
