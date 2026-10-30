#!/usr/bin/env python3
"""agentim runner: lets agentim (the gateway and the Mac app) use models on this computer.

Runs natively (`python3 runner.py`) or in Docker. Standard library only.

- Aggregates local backends (Ollama, LM Studio, llama.cpp, vLLM, Docker Model
  Runner) behind one OpenAI-compatible API: `GET /v1/models`, `POST /v1/chat/completions`.
- Reports this host's memory and checks a model fits before pulling it.
- Bridges LTX Desktop (video/image generation) into chat when run natively on the Mac.
"""

import hashlib
import json
import os
import platform
import re
import secrets
import shlex
import shutil
import socket
import ssl
import struct
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
REPOS_DIR = os.path.join(STATE_DIR, "repos")  # GitHub repos cloned for Startups & Ideas
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


# ---------------------------------------------------------------- LoRA adapters

GGUF_SCALARS = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f", 7: "<?", 10: "<Q", 11: "<q", 12: "<d"}


def gguf_metadata(data):
    """Key/values from the start of a GGUF file. Stops quietly where `data` ends (big arrays come later)."""
    if data[:4] != b"GGUF":
        raise ValueError("not a GGUF file")
    pos = 16  # magic, version, tensor count
    meta = {}

    def string():
        nonlocal pos
        (n,) = struct.unpack_from("<Q", data, pos)
        if pos + 8 + n > len(data):
            raise IndexError
        pos += 8 + n
        return data[pos - n:pos].decode("utf-8", "replace")

    def value(kind):
        nonlocal pos
        if kind == 8:
            return string()
        if kind == 9:
            inner, n = struct.unpack_from("<IQ", data, pos)
            pos += 12
            items = [value(inner) for _ in range(n)]
            return items if n <= 16 else None
        fmt = GGUF_SCALARS[kind]
        (v,) = struct.unpack_from(fmt, data, pos)
        pos += struct.calcsize(fmt)
        return v

    try:
        (count,) = struct.unpack_from("<Q", data, pos)
        pos += 8
        for _ in range(count):
            key = string()
            (kind,) = struct.unpack_from("<I", data, pos)
            pos += 4
            meta[key] = value(kind)
    except (IndexError, KeyError, struct.error):
        pass
    return meta


def hf_headers(token):
    return {"Authorization": f"Bearer {token}"} if token else {}


def hf_file_url(repo, path):
    return f"https://huggingface.co/{repo}/resolve/main/{urllib.parse.quote(path)}"


def hf_head_bytes(repo, path, token=None, length=1 << 20):
    req = urllib.request.Request(hf_file_url(repo, path), headers={**hf_headers(token), "Range": f"bytes=0-{length - 1}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return resp.read(length)


def parse_adapter_ref(text):
    """'owner/repo', 'owner/repo/file.gguf' or a huggingface.co link -> (repo, path or None)."""
    text = re.sub(r"^(https?://)?(www\.)?(huggingface\.co|hf\.co)/", "", (text or "").strip())
    text = re.sub(r"/(blob|resolve|tree)/[^/]+", "", text).split("?")[0]
    parts = [p for p in text.split("/") if p]
    if len(parts) < 2 or not all(re.fullmatch(r"[\w.\-]+", p) for p in parts) or ".." in parts:
        raise ValueError("Use a Hugging Face repo like owner/name (or a link to one).")
    return "/".join(parts[:2]), "/".join(parts[2:]) or None


def base_repo(base, token=None):
    """The original Hugging Face repo behind an installed model ('hf.co/unsloth/Qwen3.5-9B-GGUF' -> 'Qwen/Qwen3.5-9B')."""
    registry, repo, _ = parse_ollama_ref(base)
    if registry != "hf.co":
        return None
    card = (http_json(f"https://huggingface.co/api/models/{repo}", hf_headers(token)) or {}).get("cardData") or {}
    declared = card.get("base_model")
    if isinstance(declared, list):
        declared = declared[0] if declared else None
    return declared or repo


def search_adapters(base, token=None, limit=20):
    """LoRA adapters Hugging Face lists for the model behind `base`, most downloaded first."""
    root = base_repo(base, token)
    if not root:
        return {"base_repo": None, "adapters": []}
    url = (f"https://huggingface.co/api/models?filter=base_model:adapter:{urllib.parse.quote(root)}"
           f"&sort=downloads&limit={limit}&full=true")
    adapters = []
    for m in http_json(url, hf_headers(token), timeout=30) or []:
        files = [f["rfilename"] for f in m.get("siblings", [])]
        # Many "adapter" repos are really merged GGUF models; a GGUF counts only when its file says it's a LoRA.
        fmt = ("safetensors" if any(f.endswith("adapter_model.safetensors") for f in files)
               else "gguf" if any(f.lower().endswith(".gguf") and re.search(r"lora|adapter", f, re.I) for f in files)
               else None)
        if fmt:
            adapters.append({"repo": m["id"], "downloads": m.get("downloads", 0), "likes": m.get("likes", 0), "format": fmt})
    return {"base_repo": root, "adapters": adapters}


def resolve_adapter(ref, token=None):
    """Which files in the repo are the adapter: a GGUF LoRA (checked in its header) or PEFT safetensors + config."""
    repo, path = parse_adapter_ref(ref)
    tree = http_json(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true", hf_headers(token), timeout=30) or []
    sizes = {f["path"]: f.get("size", 0) for f in tree if f.get("type") == "file"}
    if path and path not in sizes and not any(p.startswith(path.rstrip("/") + "/") for p in sizes):
        raise ValueError(f"{path} isn't in {repo}.")
    ggufs = [p for p in sizes if p.lower().endswith(".gguf") and (not path or p == path)]

    def precision(p):  # full precision first: adapters are small and quantizing them costs quality
        lower = p.lower()
        return next((i for i, k in enumerate(("f16", "bf16", "q8_0", "f32")) if k in lower), 9), sizes[p]

    for p in sorted(ggufs, key=precision)[:6]:
        meta = gguf_metadata(hf_head_bytes(repo, p, token))
        if meta.get("general.type") == "adapter":
            return {"repo": repo, "format": "gguf", "files": {os.path.basename(p): p}, "size_bytes": sizes[p],
                    "architecture": meta.get("general.architecture"),
                    "base_model": meta.get("general.base_model.0.repo_url") or meta.get("general.base_model.0.name"),
                    "lora_alpha": meta.get("adapter.lora.alpha")}

    folder = path.rstrip("/") if path and not path.lower().endswith(".gguf") else ""
    configs = sorted((p for p in sizes if p.endswith("adapter_config.json") and p.startswith(folder)), key=lambda p: p.count("/"))
    for config in configs:
        weights = os.path.join(os.path.dirname(config), "adapter_model.safetensors")
        if weights in sizes:
            cfg = http_json(hf_file_url(repo, config), hf_headers(token), timeout=30) or {}
            return {"repo": repo, "format": "safetensors",
                    "files": {"adapter_model.safetensors": weights, "adapter_config.json": config},
                    "size_bytes": sizes[weights] + sizes[config], "architecture": None,
                    "base_model": cfg.get("base_model_name_or_path"), "rank": cfg.get("r"), "lora_alpha": cfg.get("lora_alpha")}
    if ggufs:
        raise ValueError(f"The GGUF files in {repo} are full models (a LoRA merged into its base), not adapters. "
                         "Pull it as a model instead.")
    raise ValueError(f"No LoRA adapter in {repo}: it needs a GGUF adapter or adapter_model.safetensors + adapter_config.json.")


def hf_base(base):
    """An installed model's Hugging Face GGUF: 'ollama/hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M' -> ('unsloth/Qwen3.5-9B-GGUF', 'Q4_K_M')."""
    registry, repo, quant = parse_ollama_ref((base or "").removeprefix("ollama/"))
    if registry != "hf.co":
        raise ValueError("LoRA adapters work on Hugging Face GGUF models (hf.co/…); this one is from the Ollama library.")
    return repo, quant


def base_gguf_info(repo, quant, token=None):
    """Architecture and download size of the base GGUF, read from its header on Hugging Face."""
    tree = http_json(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=true", hf_headers(token), timeout=30) or []
    files = sorted((f for f in tree if f.get("type") == "file" and f["path"].lower().endswith(".gguf")
                    and quant.lower() in f["path"].lower() and "mmproj" not in f["path"].lower()), key=lambda f: f["path"])
    if not files:
        raise ValueError(f"No {quant} GGUF in {repo}.")
    meta = gguf_metadata(hf_head_bytes(repo, files[0]["path"], token))
    return {"architecture": meta.get("general.architecture"), "size_bytes": sum(f.get("size", 0) for f in files)}


def short_name(name):
    name = re.sub(r"[^a-z0-9._-]+", "-", (name or "").rstrip("/").split("/")[-1].lower()).strip("-.")
    return re.sub(r"[-_.]?gguf$", "", name)


def adapter_matches(adapter, base_info, root):
    """True when the adapter names this base, False when it's another architecture or names another model, else None."""
    def norm(text):
        return re.sub(r"[^a-z0-9]", "", (text or "").lower())
    if adapter.get("architecture") and base_info.get("architecture") \
            and norm(adapter["architecture"]) != norm(base_info["architecture"]):
        return False
    declared, root = norm(short_name(adapter.get("base_model"))), norm(short_name(root))
    if declared and root:
        return declared in root or root in declared
    return None


def adapter_model_name(repo, base):
    """'acme/brand-voice-lora' on 'hf.co/unsloth/Qwen3.5-9B-GGUF:Q4_K_M' -> 'lora/brand-voice-lora:qwen3.5-9b'."""
    return f"lora/{short_name(repo)[:60]}:{short_name(parse_ollama_ref(base)[1])[:60]}"


def download_hf_file(repo, path, token, progress):
    """Downloads into LORA_DIR (kept for reuse) and returns the local path."""
    local = os.path.join(LORA_DIR, repo.replace("/", "__"), path)
    os.makedirs(os.path.dirname(local), exist_ok=True)
    req = urllib.request.Request(hf_file_url(repo, path), headers=hf_headers(token))
    with urllib.request.urlopen(req, timeout=60) as resp, open(local + ".part", "wb") as out:
        total, done = int(resp.headers.get("Content-Length") or 0), 0
        while chunk := resp.read(1 << 20):
            out.write(chunk)
            done += len(chunk)
            progress(done, total)
    os.replace(local + ".part", local)
    return local


class LoRAServer:
    """LoRA adapters on llama.cpp's llama-server, natively on the GPU (Metal). One process for the base model in use,
    with every adapter for that base loaded and picked per request. It sleeps after 10 idle minutes."""

    def __init__(self):
        self.lock = threading.RLock()
        self.proc, self.base, self.paths = None, None, []

    @staticmethod
    def binary():
        return shutil.which("llama-server", path=os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin")

    @staticmethod
    def registry():
        return os.path.join(LORA_DIR, "adapters.json")

    def adapters(self):
        try:
            with open(self.registry()) as f:
                return json.load(f)
        except (OSError, ValueError):
            return []

    def save(self, items):
        os.makedirs(LORA_DIR, exist_ok=True)
        with open(self.registry() + ".tmp", "w") as f:
            json.dump(items, f, indent=2)
        os.replace(self.registry() + ".tmp", self.registry())

    def find(self, name):
        return next((a for a in self.adapters() if a["name"] == name), None)

    def add(self, entry):
        with self.lock:
            self.save([a for a in self.adapters() if a["name"] != entry["name"]] + [entry])

    def remove(self, name):
        with self.lock:
            entry = self.find(name)
            if not entry:
                return False
            rest = [a for a in self.adapters() if a["name"] != name]
            self.save(rest)
            if self.base == entry["base"]:
                self.stop()
            if not any(a["path"] == entry["path"] for a in rest):
                try:
                    os.remove(entry["path"])
                except OSError:
                    pass
            return True

    @staticmethod
    def pid_file():
        return os.path.join(LORA_DIR, "llama-server.pid")

    def stop(self):
        with self.lock:
            if self.proc and self.proc.poll() is None:
                self.proc.terminate()
                try:
                    self.proc.wait(10)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            else:
                self.stop_leftover()
            self.proc, self.base, self.paths = None, None, []
            try:
                os.remove(self.pid_file())
            except OSError:
                pass

    def stop_leftover(self):
        """A llama-server started before the runner restarted still holds the port: stop it."""
        try:
            with open(self.pid_file()) as f:
                pid = int(f.read().strip())
            command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout
            if "llama-server" in command:
                os.kill(pid, 15)
                time.sleep(1)
        except (OSError, ValueError):
            pass

    def running(self):
        return bool(self.proc and self.proc.poll() is None)

    def ensure(self, base, token=None, timeout=3600, waiting=None):
        """llama-server running for `base` with all its adapters; returns the adapter files in id order.
        The first start downloads the base GGUF from Hugging Face (llama.cpp keeps it in its cache)."""
        with self.lock:
            paths = [a["path"] for a in self.adapters() if a["base"] == base]
            if self.running() and self.base == base and self.paths == paths:
                return paths
            self.stop()
            binary = self.binary()
            if not binary:
                raise RuntimeError("llama.cpp isn't installed on this Mac. Run: brew install llama.cpp")
            repo, quant = hf_base(base)
            os.makedirs(LORA_DIR, exist_ok=True)
            cmd = [binary, "-hf", f"{repo}:{quant}", "--host", "127.0.0.1", "--port", str(LORA_PORT), "-ngl", "all",
                   "-c", "16384", "--jinja", "--sleep-idle-seconds", "600", "--lora-init-without-apply"]
            if paths:
                cmd += ["--lora", ",".join(paths)]
            env = {**os.environ, **({"HF_TOKEN": token} if token else {})}
            log_path = os.path.join(LORA_DIR, "llama-server.log")
            with open(log_path, "ab") as log:
                self.proc = subprocess.Popen(cmd, stdout=log, stderr=log, env=env, start_new_session=True)
            with open(self.pid_file(), "w") as f:
                f.write(str(self.proc.pid))
            self.base, self.paths = base, paths
            deadline = time.time() + timeout
            while time.time() < deadline:
                if self.proc.poll() is not None:
                    with open(log_path, errors="replace") as f:
                        tail = " ".join(line.strip() for line in f.readlines()[-6:])
                    self.proc, self.base, self.paths = None, None, []
                    raise RuntimeError(f"llama-server stopped: {tail[-400:]}")
                try:
                    if (http_json(f"http://127.0.0.1:{LORA_PORT}/health", timeout=2) or {}).get("status") == "ok":
                        return paths
                except Exception:
                    pass
                if waiting:
                    waiting()
                time.sleep(2)
            self.stop()
            raise RuntimeError("llama-server didn't start in time.")

    def chat_body(self, name, body):
        """The request for llama-server: this adapter at full strength, the others off."""
        entry = self.find(name)
        if not entry:
            raise ValueError(f"No LoRA model '{name}'.")
        paths = self.ensure(entry["base"])
        index = paths.index(entry["path"])
        # Thinking models (Qwen3.5) would spend the reply on hidden reasoning the chat never shows: answer directly.
        template = {"enable_thinking": False, **(body.get("chat_template_kwargs") or {})}
        return {**body, "model": name, "chat_template_kwargs": template,
                "lora": [{"id": i, "scale": 1.0 if i == index else 0.0} for i in range(len(paths))]}

    def converter(self, status):
        """llama.cpp's convert_lora_to_gguf.py from the installed llama-server's own commit, in its own Python env."""
        binary = self.binary()
        if not binary:
            raise RuntimeError("llama.cpp isn't installed on this Mac. Run: brew install llama.cpp")
        out = subprocess.run([binary, "--version"], capture_output=True, text=True, timeout=30)
        match = re.search(r"commit ([0-9a-f]{7,40})", out.stdout + out.stderr)
        if not match:
            raise RuntimeError("Couldn't tell which llama.cpp version is installed.")
        root = os.path.join(LORA_DIR, "convert", match.group(1))
        python, script = os.path.join(root, "venv", "bin", "python"), os.path.join(root, "convert_lora_to_gguf.py")
        if os.path.exists(os.path.join(root, ".ready-2")):
            return python, script
        status("Getting llama.cpp's converter (first time only)")
        os.makedirs(root, exist_ok=True)
        archive = os.path.join(root, "src.tar.gz")
        urllib.request.urlretrieve(f"https://codeload.github.com/ggml-org/llama.cpp/tar.gz/{match.group(1)}", archive)
        import tarfile
        with tarfile.open(archive) as tar:
            for member in tar.getmembers():
                rel = member.name.split("/", 1)[-1]
                # The scripts, plus the packages they import (newer llama.cpp splits the converter into conversion/).
                if (rel.endswith(".py") and "/" not in rel) or rel.startswith(("gguf-py/", "conversion/")):
                    member.name = rel
                    tar.extract(member, root, filter="data")
        os.remove(archive)
        status("Setting up Python for the converter (first time only, a few minutes)")
        subprocess.run([sys.executable, "-m", "venv", os.path.join(root, "venv")], check=True, timeout=300)
        subprocess.run([python, "-m", "pip", "install", "-q", os.path.join(root, "gguf-py"), "numpy", "safetensors",
                        "torch", "sentencepiece", "transformers", "huggingface_hub", "protobuf"],
                       check=True, timeout=3600, capture_output=True)
        open(os.path.join(root, ".ready-2"), "w").close()
        return python, script

    def convert(self, folder, root_repo, token, status):
        """PEFT safetensors -> a GGUF adapter next to them."""
        python, script = self.converter(status)
        status("Converting the adapter to GGUF")
        out = os.path.join(folder, "adapter-f16.gguf")
        env = {**os.environ, **({"HF_TOKEN": token} if token else {})}
        run = subprocess.run([python, script, folder, "--outfile", out, "--outtype", "f16", "--base-model-id", root_repo],
                             capture_output=True, text=True, timeout=3600, env=env)
        if run.returncode != 0 or not os.path.exists(out):
            raise RuntimeError("Converting failed: " + (run.stderr or run.stdout).strip()[-400:])
        return out


LORA_DIR = os.path.join(STATE_DIR, "lora")
LORA_PORT = int(os.environ.get("AGENTIM_LORA_PORT", "8791"))
LORA = LoRAServer()


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
    if "codex" in LOCAL_AGENTS.available():
        # ChatGPT through the founder's ChatGPT login (`codex exec`, in tmux): no OpenAI API key needed.
        for model in chatgpt_login_models(LOCAL_AGENTS.env):
            models.append({"id": f"chatgpt/{model}", "object": "model", "owned_by": "chatgpt-login", "backend": "chatgpt",
                           "kind": "chatgpt", "name": f"ChatGPT {'' if model == 'default' else model + ' '}(your ChatGPT login)"})
    if "claude-code" in LOCAL_AGENTS.available():
        # Claude through the founder's Claude login (`claude -p`, in tmux): no API key needed.
        for alias, label in CLAUDE_LOGIN_MODELS.items():
            models.append({"id": f"claude/{alias}", "object": "model", "owned_by": "claude-login", "backend": "claude",
                           "kind": "claude", "name": f"{label} (your Claude login)"})
    if not IN_CONTAINER:
        for a in LORA.adapters():
            models.append({"id": a["name"], "object": "model", "owned_by": "lora", "backend": "lora", "kind": "chat",
                           "name": a.get("display"), "parameter_size": a.get("parameter_size")})
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


def load_model(model, keep_alive="10m"):
    """Loads a model into memory now (so the first chat answers quickly): an empty Ollama generate."""
    name = (model or "").split("/", 1)[1] if (model or "").startswith("ollama/") else (model or "")
    if not name:
        raise RuntimeError("Which model?")
    req = urllib.request.Request(f"{BACKENDS['ollama']}/api/generate", method="POST",
                                 data=json.dumps({"model": name, "keep_alive": keep_alive}).encode(),
                                 headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=180).read()
    return name


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

    def command(self, name, prompt, mode=None):
        spec = self.COMMANDS[name]
        return [self.binary(name)] + [prompt if part == "{prompt}" else part for part in spec[mode or self.mode()]]

    def allowed_path(self, path):
        """Inside a workspace, or one of the GitHub repos agentim cloned."""
        path = os.path.realpath(path)
        roots = self.workspaces() + [os.path.realpath(REPOS_DIR)]
        return any(path == r or path.startswith(r + os.sep) for r in roots)

    def run_task(self, name, prompt, timeout=None, cwd=None, mode=None):
        """Runs a task with a local coding agent. `cwd` must be inside a workspace (or a cloned repo); `mode`
        "edit" is used only when the caller confirmed it (the app's "Build it")."""
        if name not in self.available():
            raise RuntimeError(f"{name} isn't enabled on this Mac (AGENTIM_LOCAL_AGENTS) or isn't installed.")
        if not prompt.strip():
            raise RuntimeError("Tell the agent what to do.")
        if cwd:
            cwd = os.path.realpath(os.path.expanduser(cwd))
            if not self.allowed_path(cwd):
                raise RuntimeError(f"{cwd} isn't in AGENTIM_WORKSPACES.")
        else:
            cwd = self.workspace_for(prompt)
        timeout = timeout or int(self.env.get("AGENTIM_LOCAL_AGENTS_TIMEOUT", "900"))
        cmd = self.command(name, prompt, mode)
        if self.use_tmux():
            return self.run_in_tmux(name, cmd, cwd, timeout)
        result = self.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        output = (result.stdout or "").strip() or (result.stderr or "").strip()
        if result.returncode != 0:
            raise RuntimeError(f"{self.COMMANDS[name]['name']} exited with {result.returncode}: {output[-800:]}")
        return output, cwd

    def tmux(self):
        """tmux's full path (the runner's own PATH may not include Homebrew)."""
        for folder in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]:
            path = os.path.join(folder, "tmux")
            if os.path.exists(path):
                return path
        return self.which("tmux")

    def use_tmux(self):
        """On by default whenever tmux is installed (AGENTIM_LOCAL_AGENTS_TMUX=0 turns it off)."""
        setting = (self.env.get("AGENTIM_LOCAL_AGENTS_TMUX") or "auto").lower()
        return setting not in ("0", "false", "no", "off") and bool(self.tmux())

    def chat(self, model, prompt, timeout=600):
        """Claude through the founder's Claude login: `claude -p --model <model>`, read-only, in an empty folder,
        in a tmux session when tmux is installed. Returns the answer."""
        if "claude-code" not in self.available():
            raise RuntimeError("Claude Code isn't installed or enabled on this Mac (AGENTIM_LOCAL_AGENTS).")
        if model not in CLAUDE_LOGIN_MODELS:
            raise RuntimeError(f"Unknown Claude model {model!r}.")
        os.makedirs(CLAUDE_CHAT_DIR, exist_ok=True)
        cmd = [self.binary("claude-code"), "-p", prompt, "--model", model, "--permission-mode", "plan",
               "--output-format", "text"]
        if self.use_tmux():
            return self.run_in_tmux("claude-code", cmd, CLAUDE_CHAT_DIR, timeout)[0]
        if (self.env.get("AGENTIM_LOCAL_AGENTS_TMUX") or "auto").lower() not in ("0", "false", "no", "off"):
            raise RuntimeError("Claude runs in a background terminal (tmux): install it with `brew install tmux` "
                               "(or set AGENTIM_LOCAL_AGENTS_TMUX=0 to run it directly).")
        result = self.run(cmd, cwd=CLAUDE_CHAT_DIR, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        output = (result.stdout or "").strip() or (result.stderr or "").strip()
        if result.returncode != 0:
            raise RuntimeError(f"Claude exited with {result.returncode}: {output[-800:]}")
        return output

    def chatgpt(self, model, prompt, timeout=600):
        """ChatGPT through the founder's ChatGPT login: `codex exec`, read-only, in an empty folder, in a tmux
        session when tmux is installed. Returns Codex's final message (not its progress log)."""
        if "codex" not in self.available():
            raise RuntimeError("Codex isn't installed or enabled on this Mac (AGENTIM_LOCAL_AGENTS).")
        os.makedirs(CLAUDE_CHAT_DIR, exist_ok=True)
        answer = os.path.join(FILES_DIR, f"chatgpt-{uuid.uuid4().hex[:8]}.txt")
        os.makedirs(FILES_DIR, exist_ok=True)
        cmd = [self.binary("codex"), "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral",
               "--color", "never", "-o", answer] + ([] if model == "default" else ["-m", model]) + [prompt]
        try:
            if self.use_tmux():
                output = self.run_in_tmux("codex", cmd, CLAUDE_CHAT_DIR, timeout)[0]
            elif (self.env.get("AGENTIM_LOCAL_AGENTS_TMUX") or "auto").lower() not in ("0", "false", "no", "off"):
                raise RuntimeError("ChatGPT runs in a background terminal (tmux): install it with `brew install tmux` "
                                   "(or set AGENTIM_LOCAL_AGENTS_TMUX=0 to run it directly).")
            else:
                result = self.run(cmd, cwd=CLAUDE_CHAT_DIR, capture_output=True, text=True, timeout=timeout,
                                  stdin=subprocess.DEVNULL)
                output = (result.stdout or "").strip() or (result.stderr or "").strip()
                if result.returncode != 0:
                    raise RuntimeError(f"Codex exited with {result.returncode}: {output[-800:]}")
            final = open(answer).read().strip() if os.path.exists(answer) else ""
            return final or output
        finally:
            if os.path.exists(answer):
                os.remove(answer)

    def run_in_tmux(self, name, cmd, cwd, timeout):
        session = f"agentim-{name}-{uuid.uuid4().hex[:6]}"
        log_file = os.path.join(FILES_DIR, f"{session}.log")
        os.makedirs(FILES_DIR, exist_ok=True)
        quoted = " ".join(shlex.quote(c) for c in cmd)
        script = f"{quoted} > {shlex.quote(log_file)} 2>&1; echo $? > {shlex.quote(log_file)}.exit"
        self.run([self.tmux() or "tmux", "new-session", "-d", "-s", session, "-c", cwd, script], check=True)
        deadline = self.clock() + timeout
        while self.clock() < deadline:
            if os.path.exists(log_file + ".exit"):
                output = open(log_file).read().strip()
                code = open(log_file + ".exit").read().strip()
                if code != "0":
                    raise RuntimeError(f"{self.COMMANDS[name]['name']} exited with {code}: {output[-800:]}")
                return output, cwd
            time.sleep(2)
        self.run([self.tmux() or "tmux", "kill-session", "-t", session])
        raise RuntimeError(f"{self.COMMANDS[name]['name']} didn't finish in {timeout} s (tmux session {session}).")


LOCAL_AGENTS = LocalAgents()

CLAUDE_LOGIN_MODELS = {"opus": "Claude Opus", "sonnet": "Claude Sonnet", "haiku": "Claude Haiku"}


def chatgpt_login_models(env=None, config_path=os.path.expanduser("~/.codex/config.toml")):
    """The ChatGPT models to offer through the ChatGPT login (Codex): AGENTIM_CHATGPT_MODELS, else the model in
    Codex's own config, else Codex's default."""
    env = env if env is not None else os.environ
    listed = [m.strip() for m in (env.get("AGENTIM_CHATGPT_MODELS") or "").split(",") if m.strip()]
    if listed:
        return listed
    try:
        for line in open(config_path):
            match = re.match(r'^\s*model\s*=\s*"([^"]+)"', line)
            if match:
                return [match.group(1)]
    except OSError:
        pass
    return ["default"]
CLAUDE_CHAT_DIR = os.path.join(STATE_DIR, "claude-chat")  # an empty folder: plain chats never read your code


def claude_chat_prompt(messages):
    """An OpenAI-style conversation → one prompt for `claude -p`."""
    system = "\n\n".join(m["content"] for m in messages if m.get("role") == "system" and isinstance(m.get("content"), str))
    turns = [m for m in messages if m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str)]
    history = "\n\n".join(f"{'User' if m['role'] == 'user' else 'Assistant'}: {m['content']}" for m in turns[:-1])
    last = turns[-1]["content"] if turns else ""
    return ((f"{system}\n\n" if system else "") + (f"The conversation so far:\n{history}\n\n" if history else "")
            + (f"Reply to the user's last message:\n{last}" if history else last))


# ---------------------------------------------------------------- projects (Startups & Ideas)

class Projects:
    """What the agents should know about a codebase: a local folder or a GitHub repo (cloned under REPOS_DIR)."""

    REPO = re.compile(r"^(?:https?://github\.com/)?([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$")
    SKIP = {".git", "node_modules", ".build", "build", "dist", "DerivedData", "__pycache__", ".venv", "venv",
            ".next", "Pods", "target", ".idea", ".claude"}
    MANIFESTS = ["package.json", "pyproject.toml", "requirements.txt", "go.mod", "Cargo.toml", "Package.swift",
                 "project.yml", "Gemfile", "pom.xml", "build.gradle", "docker-compose.yml", "Dockerfile", "Makefile"]

    def __init__(self, agents=None, run=subprocess.run, which=shutil.which):
        self.agents, self.run, self.which = agents or LOCAL_AGENTS, run, which

    def checkout(self, repo):
        """Clones (or fast-forwards) a GitHub repo and returns its folder. Uses gh when available (private repos)."""
        match = self.REPO.match(repo.strip())
        if not match:
            raise RuntimeError(f"{repo!r} isn't a GitHub repo (use owner/name).")
        owner, name = match.groups()
        path = os.path.join(REPOS_DIR, owner, name)
        if os.path.isdir(os.path.join(path, ".git")):
            self.run(["git", "-C", path, "pull", "--ff-only", "--quiet"], capture_output=True, timeout=120)
            return path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        if self.which("gh"):
            cmd = ["gh", "repo", "clone", f"{owner}/{name}", path, "--", "--depth", "50"]
        else:
            cmd = ["git", "clone", "--depth", "50", f"https://github.com/{owner}/{name}.git", path]
        result = self.run(cmd, capture_output=True, text=True, timeout=600)
        if result.returncode != 0:
            raise RuntimeError(f"Couldn't clone {owner}/{name}: {(result.stderr or '').strip()[-300:]}")
        return path

    def create(self, name):
        """A new, empty project folder (a git repo) for a startup that has no code yet."""
        slug = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")[:40] or "startup"
        path, n = os.path.join(REPOS_DIR, "startups", slug), 2
        while os.path.exists(path):
            path, n = os.path.join(REPOS_DIR, "startups", f"{slug}-{n}"), n + 1
        os.makedirs(path)
        self.run(["git", "init", "--quiet", path], capture_output=True, timeout=30)
        return path

    def run_command(self, folder, command, timeout=900):
        """Runs the founder's own test or deploy command in a project folder, with their login shell (so CLIs like
        vercel, fly or npm are on PATH and use their own saved logins). Returns the exit code and the output's tail."""
        if not command.strip():
            raise RuntimeError("No command to run.")
        started = time.time()
        try:
            result = self.run(["/bin/zsh", "-lc", command], cwd=folder, capture_output=True, text=True,
                              timeout=min(int(timeout), 3600), stdin=subprocess.DEVNULL)
            code, output = result.returncode, (result.stdout or "") + (result.stderr or "")
        except subprocess.TimeoutExpired:
            code, output = 124, f"Stopped after {timeout} s."
        return {"folder": folder, "exit_code": code, "output": output.strip()[-6000:],
                "seconds": round(time.time() - started, 1)}

    # ---- versions: commits, semver tags and a changelog, so progress is easy to follow

    VERSION = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")

    def git(self, folder, *args, timeout=60):
        result = self.run(["git", "-C", folder, *args], capture_output=True, text=True, timeout=timeout)
        return result.returncode, (result.stdout or "").strip(), (result.stderr or "").strip()

    def version(self, folder):
        """The latest vX.Y.Z tag, or None."""
        code, out, _ = self.git(folder, "tag", "--list", "v*", "--sort=-v:refname")
        return next((t for t in out.splitlines() if self.VERSION.match(t.strip())), None) if code == 0 else None

    @classmethod
    def bumped(cls, current, bump):
        if not current:
            return "v0.1.0"
        major, minor, patch = (int(x) for x in cls.VERSION.match(current).groups())
        if bump == "major":
            return f"v{major + 1}.0.0"
        if bump == "patch":
            return f"v{major}.{minor}.{patch + 1}"
        return f"v{major}.{minor + 1}.0"

    def commit(self, folder, message, bump="minor", body=""):
        """Commits everything in the project folder with `message`, tags the next version and adds it to
        CHANGELOG.md. Returns {"committed": False} when nothing changed."""
        if not os.path.isdir(os.path.join(folder, ".git")):
            self.git(folder, "init", "--quiet")
        code, status, _ = self.git(folder, "status", "--porcelain")
        if code != 0 or not status.strip():
            return {"committed": False, "version": self.version(folder)}
        version = self.bumped(self.version(folder), bump)
        changed = len(status.splitlines())
        path = os.path.join(folder, "CHANGELOG.md")
        old = open(path).read() if os.path.exists(path) else "# Changelog\n\nEvery version agentim builds, newest first.\n"
        head, _, rest = old.partition("\n## ")
        entry = (f"## {version} · {time.strftime('%Y-%m-%d %H:%M')}\n\n- {message}\n"
                 + "".join(f"- {line}\n" for line in body.splitlines()[:6] if line.strip()) + "\n")
        open(path, "w").write(head.rstrip() + "\n\n" + entry + (("## " + rest) if rest else ""))
        self.git(folder, "add", "-A")
        identity = []
        if self.git(folder, "config", "user.email")[0] != 0:  # no git identity on this Mac: sign as agentim
            identity = ["-c", "user.name=agentim", "-c", "user.email=agentim@localhost"]
        full = message + (f"\n\n{body.strip()}" if body.strip() else "") + f"\n\nVersion: {version}"
        code, _, err = self.git(folder, *identity, "commit", "--quiet", "-m", full)
        if code != 0:
            raise RuntimeError(f"git commit failed: {err[-300:]}")
        self.git(folder, *identity, "tag", "-a", version, "-m", f"{version}: {message}")
        sha = self.git(folder, "rev-parse", "--short", "HEAD")[1]
        return {"committed": True, "version": version, "sha": sha, "files": changed}

    def history(self, folder, limit=40):
        """Commits, newest first, with the version tag on each (if any)."""
        code, out, _ = self.git(folder, "log", f"-{int(limit)}", "--pretty=format:%h\x1f%s\x1f%ct\x1f%D")
        if code != 0:
            return []
        commits = []
        for line in out.splitlines():
            sha, subject, ts, refs = (line.split("\x1f") + ["", "", "0", ""])[:4]
            tags = [r.strip()[5:] for r in refs.split(",") if r.strip().startswith("tag: ")]
            commits.append({"sha": sha, "subject": subject, "ts": int(ts or 0),
                            "version": next((t for t in tags if self.VERSION.match(t)), None)})
        return commits

    def remote(self, folder):
        code, url, _ = self.git(folder, "remote", "get-url", "origin")
        return url if code == 0 else ""

    def create_github(self, folder, name, private=True):
        """Creates a GitHub repo for the project with the founder's gh login and pushes the history and tags."""
        if not self.which("gh"):
            raise RuntimeError("Install the GitHub CLI (brew install gh) and run gh auth login first.")
        if not re.match(r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$", name or ""):
            raise RuntimeError("Use a repo name like my-startup (or owner/my-startup).")
        if self.remote(folder):
            raise RuntimeError(f"This project already has a remote: {self.remote(folder)}")
        if not self.git(folder, "rev-parse", "HEAD")[0] == 0:
            raise RuntimeError("Build a first version before creating the repo.")
        result = self.run(["gh", "repo", "create", name, "--private" if private else "--public", "--source", folder,
                           "--remote", "origin", "--push"], capture_output=True, text=True, timeout=180)
        if result.returncode != 0:
            raise RuntimeError(f"gh repo create failed: {(result.stderr or result.stdout).strip()[-400:]}")
        self.git(folder, "push", "--quiet", "origin", "--tags", timeout=180)
        url = self.remote(folder)
        return {"url": re.sub(r"\.git$", "", url.replace("git@github.com:", "https://github.com/")), "private": private}

    def push(self, folder):
        """Pushes the current branch and its version tags (never forced)."""
        if not self.remote(folder):
            raise RuntimeError("No GitHub repo yet: create one first.")
        code, _, err = self.git(folder, "push", "--quiet", "--follow-tags", "origin", "HEAD", timeout=180)
        if code != 0:
            raise RuntimeError(f"git push failed: {err[-400:]}")
        return {"pushed": True}

    # ---- results: what changed, and pull requests

    @staticmethod
    def github_repo(url):
        """'git@github.com:acme/shop.git' or 'https://github.com/acme/shop' -> 'acme/shop' (None for other hosts)."""
        match = re.match(r"^(?:git@github\.com:|(?:https|ssh)://(?:[^@/]+@)?github\.com/)([\w.-]+/[\w.-]+?)(?:\.git)?/?$", url or "")
        return match.group(1) if match else None

    def changes(self, folder, base=None):
        """Changed files with lines added/removed: uncommitted work (plus new files), or everything since `base`."""
        code, out, _ = self.git(folder, "diff", "--numstat", f"{base}...HEAD" if base else "HEAD")
        files = []
        for line in out.splitlines() if code == 0 else []:
            added, removed, path = (line.split("\t") + ["", "", ""])[:3]
            files.append({"path": path, "status": "modified", "added": int(added) if added.isdigit() else None,
                          "removed": int(removed) if removed.isdigit() else None})
        if not base:
            code, out, _ = self.git(folder, "ls-files", "--others", "--exclude-standard")
            for path in out.splitlines() if code == 0 else []:
                try:
                    with open(os.path.join(folder, path), "rb") as f:
                        data = f.read(1 << 20)
                    lines = None if b"\0" in data[:8192] else data.count(b"\n") + (0 if data.endswith(b"\n") or not data else 1)
                except OSError:
                    lines = None
                files.append({"path": path, "status": "added", "added": lines, "removed": 0})
        return files[:200]

    def default_branch(self, folder):
        code, out, _ = self.git(folder, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
        if code == 0 and "/" in out:
            return out.split("/", 1)[1]
        for name in ("main", "master"):
            if self.git(folder, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{name}")[0] == 0:
                return name
        return "main"

    @staticmethod
    def branch_name(title):
        slug = re.sub(r"[^a-z0-9]+", "-", (title or "").lower()).strip("-")[:40].strip("-") or "change"
        return f"agentim/{slug}-{time.strftime('%m%d-%H%M')}"

    def pull_request(self, folder, title, body=""):
        """Puts the agent's changes on a new branch (never the default one), pushes it (never forced) and opens a
        pull request with the founder's gh login. Returns its link, branch and changed files."""
        if not self.which("gh"):
            raise RuntimeError("Install the GitHub CLI (brew install gh) and run gh auth login first.")
        repo = self.github_repo(self.remote(folder))
        if not repo:
            raise RuntimeError("This folder has no GitHub remote (origin), so there's nowhere to open a pull request.")
        title = (title or "").strip().splitlines()[0][:120] if (title or "").strip() else "Changes from agentim"
        base = self.default_branch(folder)
        code, branch, _ = self.git(folder, "rev-parse", "--abbrev-ref", "HEAD")
        if code != 0 or branch in ("HEAD", base):
            branch = self.branch_name(title)
            code, _, err = self.git(folder, "switch", "--quiet", "-c", branch)
            if code != 0:
                raise RuntimeError(f"git switch failed: {err[-300:]}")
        if self.git(folder, "status", "--porcelain")[1].strip():
            identity = [] if self.git(folder, "config", "user.email")[0] == 0 else \
                ["-c", "user.name=agentim", "-c", "user.email=agentim@localhost"]
            self.git(folder, "add", "-A")
            message = title + (f"\n\n{body.strip()}" if body.strip() else "") + "\n\nMade with agentim"
            code, _, err = self.git(folder, *identity, "commit", "--quiet", "-m", message)
            if code != 0:
                raise RuntimeError(f"git commit failed: {err[-300:]}")
        self.git(folder, "fetch", "--quiet", "origin", base, timeout=120)
        ahead = self.git(folder, "rev-list", "--count", f"origin/{base}..HEAD")[1]
        if ahead in ("", "0"):
            raise RuntimeError(f"Nothing to put in a pull request: no changes on top of {base}.")
        code, _, err = self.git(folder, "push", "--quiet", "-u", "origin", branch, timeout=180)
        if code != 0:
            raise RuntimeError(f"git push failed: {err[-400:]}")
        result = self.run(["gh", "pr", "create", "--repo", repo, "--base", base, "--head", branch, "--title", title,
                           "--body", (body.strip() or title) + "\n\n_Opened from agentim._"],
                          cwd=folder, capture_output=True, text=True, timeout=120)
        url = next((line for line in reversed((result.stdout or "").splitlines()) if "/pull/" in line), "")
        if not url:  # already open for this branch: show that one
            view = self.run(["gh", "pr", "view", branch, "--repo", repo, "--json", "url", "-q", ".url"],
                            cwd=folder, capture_output=True, text=True, timeout=60)
            url = (view.stdout or "").strip()
        if not url:
            raise RuntimeError(f"gh pr create failed: {(result.stderr or result.stdout).strip()[-400:]}")
        number = re.search(r"/pull/(\d+)", url)
        return {"url": url.strip(), "number": int(number.group(1)) if number else None, "repo": repo, "branch": branch,
                "base": base, "sha": self.git(folder, "rev-parse", "HEAD")[1],
                "files": self.changes(folder, base=f"origin/{base}")}

    @staticmethod
    def check(url, opener=urllib.request.urlopen):
        """Is the live URL answering? (http/https only)."""
        if not str(url).startswith(("http://", "https://")):
            return {"ok": False, "error": "Not an http(s) URL."}
        started = time.time()
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "agentim-live-check"})
            # Homebrew's Python ships without CA certificates; macOS keeps them in /etc/ssl/cert.pem.
            cafile = "/etc/ssl/cert.pem" if os.path.exists("/etc/ssl/cert.pem") else None
            kwargs = {"context": ssl.create_default_context(cafile=cafile)} if opener is urllib.request.urlopen else {}
            with opener(req, timeout=20, **kwargs) as resp:
                status = resp.status
        except urllib.error.HTTPError as e:
            status = e.code
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": str(e)[:200]}
        return {"ok": 200 <= status < 400, "status": status, "ms": int((time.time() - started) * 1000)}

    def resolve(self, source):
        """A source dict → its folder: {"type": "dir", "path": …} or {"type": "github", "repo": "owner/name"}."""
        if source.get("type") == "github":
            return self.checkout(source.get("repo", ""))
        path = os.path.realpath(os.path.expanduser(source.get("path", "")))
        if not os.path.isdir(path):
            raise RuntimeError(f"{path} isn't a folder on this Mac.")
        if not self.agents.allowed_path(path):
            raise RuntimeError(f"{path} isn't in AGENTIM_WORKSPACES (add it from the app).")
        return path

    def tree(self, root, depth=2, limit=60):
        lines = []
        for current, dirs, files in os.walk(root):
            level = current[len(root):].count(os.sep)
            dirs[:] = sorted(d for d in dirs if d not in self.SKIP and not d.startswith("."))
            if level >= depth:
                dirs[:] = []
            indent = "  " * level
            if current != root:
                lines.append(f"{indent[:-2]}{os.path.basename(current)}/")
            for name in sorted(f for f in files if not f.startswith("."))[:12]:
                lines.append(f"{indent}{name}")
            if len(lines) >= limit:
                break
        return lines[:limit]

    def summary(self, path, max_chars=1400):
        """README start, stack (manifests), structure and recent commits, kept short for small models."""
        name = os.path.basename(path.rstrip("/"))
        parts = [f"## {name} ({path})"]
        readme = next((os.path.join(path, f) for f in ("README.md", "README", "readme.md", "README.rst")
                       if os.path.isfile(os.path.join(path, f))), None)
        if readme:
            text = open(readme, errors="replace").read(1500)
            text = re.sub(r"<[^>]+>|!\[[^\]]*\]\([^)]*\)", "", text)
            parts.append("README: " + " ".join(text.split())[:500])
        stack = [m for m in self.MANIFESTS if os.path.exists(os.path.join(path, m))]
        if stack:
            parts.append("Stack files: " + ", ".join(stack))
        parts.append("Structure:\n" + "\n".join(self.tree(path)[:30]))
        log = self.run(["git", "-C", path, "log", "--oneline", "-8"], capture_output=True, text=True, timeout=20)
        if log.returncode == 0 and log.stdout.strip():
            parts.append("Recent commits:\n" + log.stdout.strip())
        return "\n".join(parts)[:max_chars]

    def context(self, sources, max_chars=3000):
        """Summaries of every source; problems are reported inline instead of failing the whole call."""
        out, folders = [], []
        for source in sources:
            try:
                path = self.resolve(source)
                folders.append({**source, "folder": path})
                out.append(self.summary(path, max_chars=max_chars // max(1, len(sources))))
            except Exception as e:
                folders.append({**source, "error": str(e)})
                out.append(f"## {source.get('repo') or source.get('path')}: unavailable ({e})")
        return {"context": "\n\n".join(out)[:max_chars], "folders": folders}


PROJECTS = Projects()


class GitHubResearch:
    """Finds engineers on GitHub and reads their public work, with the founder's `gh` login.

    Public profile fields, recent repos and recent commit messages only. Emails are never read or returned:
    GitHub's terms don't allow using them for unsolicited outreach (recruiting included)."""

    PROFILE = ("login", "name", "bio", "company", "location", "blog", "twitter_username", "hireable", "public_repos",
               "followers", "avatar_url", "html_url", "created_at")

    def __init__(self, run=subprocess.run, which=shutil.which):
        self.run, self.which = run, which

    def api(self, path, **params):
        if not self.which("gh"):
            raise RuntimeError("Install the GitHub CLI (brew install gh) and run gh auth login.")
        args = ["gh", "api", "-X", "GET", path] + [x for k, v in params.items() for x in ("-f", f"{k}={v}")]
        result = self.run(args, capture_output=True, text=True, timeout=60)
        if result.returncode != 0:
            raise RuntimeError(f"GitHub: {(result.stderr or result.stdout).strip()[-300:]}")
        return json.loads(result.stdout or "null")

    def search(self, query, limit=10):
        limit = max(1, min(int(limit or 10), 15))
        found = self.api("search/users", q=query, per_page=limit)
        return [self.profile(item["login"]) for item in (found or {}).get("items", [])[:limit]]

    def profile(self, login):
        user = self.api(f"users/{login}") or {}
        profile = {k: user.get(k) for k in self.PROFILE}  # no "email", on purpose
        repos = self.api(f"users/{login}/repos", sort="pushed", per_page=12) or []
        profile["repos"] = [{"name": r["name"], "description": (r.get("description") or "")[:200],
                             "language": r.get("language"), "stars": r.get("stargazers_count", 0),
                             "pushed_at": r.get("pushed_at"), "url": r.get("html_url"), "topics": r.get("topics", [])[:6]}
                            for r in repos if not r.get("fork")][:8]
        events = self.api(f"users/{login}/events/public", per_page=40) or []
        commits = []
        for event in events:
            if event.get("type") != "PushEvent":
                continue
            for commit in (event.get("payload") or {}).get("commits", [])[:3]:
                commits.append({"repo": event["repo"]["name"], "message": (commit.get("message") or "").splitlines()[0][:140],
                                "at": event.get("created_at")})
        profile["commits"] = commits[:12]
        return profile


GITHUB = GitHubResearch()


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
        if path == "/v1/projects/context":
            if IN_CONTAINER:
                return self.error(404, "Projects are read by the runner on the Mac.")
            return self.send_json(200, PROJECTS.context(body.get("sources", []), int(body.get("max_chars", 3000))))
        if path == "/v1/projects/task":
            # One coding-agent task in one project folder: plan (read-only) or build (edit, confirmed in the app).
            if IN_CONTAINER:
                return self.error(404, "Projects are read by the runner on the Mac.")
            try:
                folder = PROJECTS.resolve(body.get("source", {}))
                mode = "edit" if body.get("mode") == "edit" and body.get("confirmed") is True else "read"
                timeout = min(int(body.get("timeout") or 0), 3600) or None
                output, cwd = LOCAL_AGENTS.run_task(body.get("agent", "claude-code"), body.get("prompt", ""),
                                                    cwd=folder, mode=mode, timeout=timeout)
                changed = ""
                if mode == "edit":
                    stat = subprocess.run(["git", "-C", cwd, "diff", "--stat"], capture_output=True, text=True, timeout=30)
                    new = subprocess.run(["git", "-C", cwd, "status", "--short", "--untracked-files=all"],
                                         capture_output=True, text=True, timeout=30)
                    added = [line[3:] for line in new.stdout.splitlines() if line.startswith("??")]
                    changed = (stat.stdout.strip() + (f"\nNew files ({len(added)}): " + ", ".join(added[:25])
                                                      if added else "")).strip()[-1500:]
                # Structured results for the app's result card: each file, the repo and branch (for links).
                code, branch, _ = PROJECTS.git(cwd, "rev-parse", "--abbrev-ref", "HEAD")
                return self.send_json(200, {"folder": cwd, "mode": mode, "output": output[-6000:], "changed": changed,
                                            "files": PROJECTS.changes(cwd) if mode == "edit" else [],
                                            "repo": PROJECTS.github_repo(PROJECTS.remote(cwd)),
                                            "branch": branch if code == 0 else None})
            except subprocess.TimeoutExpired:
                return self.error(504, "The coding agent took too long and was stopped.")
            except Exception as e:
                return self.error(400, str(e))
        if path == "/v1/recruit/search":
            # Recruiting: engineers on GitHub and their public work (never emails).
            if IN_CONTAINER:
                return self.error(404, "Recruiting research runs on the Mac (it uses your gh login).")
            try:
                query = str(body.get("q") or "").strip()
                if not query:
                    return self.error(400, "What should I search for?")
                return self.send_json(200, {"candidates": GITHUB.search(query, body.get("limit") or 10)})
            except Exception as e:
                return self.error(400, str(e))
        if path in ("/v1/projects/commit", "/v1/projects/history", "/v1/projects/github", "/v1/projects/push",
                    "/v1/projects/pr"):
            # Versions: commit + tag + changelog, the log, and (confirmed by the founder) GitHub.
            if IN_CONTAINER:
                return self.error(404, "Projects are run by the runner on the Mac.")
            try:
                folder = PROJECTS.resolve(body.get("source", {}))
                if path == "/v1/projects/commit":
                    return self.send_json(200, PROJECTS.commit(folder, body.get("message") or "chore: update",
                                                               body.get("bump", "minor"), body.get("body", "")))
                if path == "/v1/projects/history":
                    return self.send_json(200, {"commits": PROJECTS.history(folder), "version": PROJECTS.version(folder),
                                                "remote": PROJECTS.remote(folder)})
                if body.get("confirmed") is not True:
                    return self.error(400, "GitHub actions need the founder's confirmation.")
                if path == "/v1/projects/github":
                    return self.send_json(200, PROJECTS.create_github(folder, body.get("name", ""),
                                                                      body.get("private", True) is not False))
                if path == "/v1/projects/pr":
                    return self.send_json(200, PROJECTS.pull_request(folder, body.get("title", ""), body.get("body", "")))
                return self.send_json(200, PROJECTS.push(folder))
            except Exception as e:
                return self.error(400, str(e))
        if path in ("/v1/projects/create", "/v1/projects/run", "/v1/projects/check"):
            # The launch pipeline: a new project folder, the founder's own test/deploy command, a live check.
            if IN_CONTAINER:
                return self.error(404, "Projects are run by the runner on the Mac.")
            try:
                if path == "/v1/projects/create":
                    return self.send_json(200, {"folder": PROJECTS.create(body.get("name", ""))})
                if path == "/v1/projects/check":
                    return self.send_json(200, PROJECTS.check(body.get("url", "")))
                if body.get("confirmed") is not True:
                    return self.error(400, "Running a command needs the founder's confirmation.")
                folder = PROJECTS.resolve(body.get("source", {}))
                return self.send_json(200, PROJECTS.run_command(folder, body.get("command", ""), body.get("timeout") or 900))
            except Exception as e:
                return self.error(400, str(e))
        if path == "/v1/models/load":
            try:
                return self.send_json(200, {"loaded": load_model(body.get("model"))})
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
        if path == "/v1/adapters/search":
            return self.adapter_search(body)
        if path == "/v1/adapters/check":
            return self.adapter_check(body)
        if path == "/v1/adapters/create":
            return self.adapter_create(body)
        self.error(404, "Not found")

    def do_DELETE(self):
        path = urllib.parse.urlparse(self.path).path
        if not self.authorized():
            return
        if path.startswith("/v1/models/lora/") and not IN_CONTAINER:
            name = urllib.parse.unquote(path[len("/v1/models/"):])
            return self.send_json(200, {"deleted": name}) if LORA.remove(name) else self.error(404, f"No LoRA model '{name}'.")
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
        if backend == "claude":
            return self.claude_login_chat(name, body)
        if backend == "chatgpt":
            return self.chatgpt_login_chat(name, body)
        if backend == "lora" and not IN_CONTAINER:
            try:
                return self.relay(f"http://127.0.0.1:{LORA_PORT}/v1", "llama-server", LORA.chat_body(model, body))
            except Exception as e:
                return self.error(502, f"Couldn't start the LoRA model: {e}")
        if backend not in BACKENDS or not name:
            return self.error(400, f"Unknown model '{model}'. Use an id from GET /v1/models.")
        body["model"] = name
        return self.relay(openai_base(backend), backend, body)

    def relay(self, base_url, backend, body):
        """Streams an OpenAI-compatible server's reply straight through."""
        req = urllib.request.Request(
            f"{base_url}/chat/completions", data=json.dumps(body).encode(), method="POST",
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

    def chatgpt_login_chat(self, model, body):
        """A chat answered by ChatGPT through the founder's ChatGPT login (no OpenAI API key)."""
        if IN_CONTAINER:
            return self.error(404, "ChatGPT through your login runs on the Mac.")
        try:
            text = LOCAL_AGENTS.chatgpt(model, claude_chat_prompt(body.get("messages", [])))
        except subprocess.TimeoutExpired:
            return self.error(504, "ChatGPT took too long and was stopped.")
        except Exception as e:
            return self.error(502, str(e))
        if not body.get("stream"):
            return self.send_json(200, {"object": "chat.completion", "model": f"chatgpt/{model}", "choices": [
                {"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}]})
        self.start_sse()
        self.sse({"object": "chat.completion.chunk", "choices": [{"index": 0, "delta": {"content": text}}]})
        self.wfile.write(b"data: [DONE]\n\n")

    def claude_login_chat(self, model, body):
        """A chat answered by Claude through the founder's Claude login (no API key)."""
        if IN_CONTAINER:
            return self.error(404, "Claude through your login runs on the Mac.")
        try:
            text = LOCAL_AGENTS.chat(model, claude_chat_prompt(body.get("messages", [])))
        except subprocess.TimeoutExpired:
            return self.error(504, "Claude took too long and was stopped.")
        except Exception as e:
            return self.error(502, str(e))
        if not body.get("stream"):
            return self.send_json(200, {"object": "chat.completion", "model": f"claude/{model}", "choices": [
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

    # ---- LoRA adapters: a Hugging Face adapter on top of a Hugging Face GGUF model becomes its own model (llama-server)

    def adapter_search(self, body):
        try:
            hf_base(body.get("base"))
            return self.send_json(200, search_adapters(body["base"].removeprefix("ollama/"), body.get("hf_token")))
        except Exception as e:
            return self.error(400, str(e))

    def adapter_plan(self, body):
        """What would be created: the adapter's files, whether it fits the base, the new model's name."""
        if IN_CONTAINER:
            raise ValueError("LoRA models run natively on the Mac: use the Mac's runner, not the Docker one.")
        base, token = body.get("base", "").removeprefix("ollama/"), body.get("hf_token")
        repo, quant = hf_base(base)
        adapter = resolve_adapter(body.get("adapter"), token)
        info = base_gguf_info(repo, quant, token)
        root = None
        try:
            root = base_repo(base, token)
        except Exception:
            pass
        name = body.get("name") or adapter_model_name(adapter["repo"], base)
        free = shutil.disk_usage(STATE_DIR if os.path.exists(STATE_DIR) else "/").free
        return {**adapter, "base": base, "base_repo": root, "base_architecture": info["architecture"],
                "base_size_bytes": info["size_bytes"], "matches": adapter_matches(adapter, info, root), "name": name,
                "model": name, "exists": LORA.find(name) is not None, "llama_cpp": LORA.binary() is not None,
                "enough_disk": adapter["size_bytes"] * 3 + 512 * MB < free}

    def adapter_check(self, body):
        try:
            return self.send_json(200, self.adapter_plan(body))
        except urllib.error.HTTPError as e:
            return self.error(404, f"Hugging Face said {e.code}: is the repo right (and public, or is your token set)?")
        except Exception as e:
            return self.error(400, str(e))

    def adapter_create(self, body):
        """Streams progress like a pull: download, convert if needed, load it with its base, then a one-token test."""
        try:
            plan = self.adapter_plan(body)
        except Exception as e:
            return self.error(400, str(e))
        if not plan["llama_cpp"]:
            return self.error(409, "llama.cpp isn't installed on this Mac. Run: brew install llama.cpp")
        if plan["matches"] is False and not body.get("force"):
            return self.error(409, f"This adapter looks made for {plan.get('base_model') or plan.get('architecture')}, "
                                   f"not {plan['base_repo'] or plan['base']}.")
        if not plan["enough_disk"]:
            return self.error(409, "Not enough disk space for this adapter.")
        token, name = body.get("hf_token"), plan["name"]
        self.start_sse()

        def status(text):
            self.sse({"status": text})

        try:
            local = {}
            for target, path in plan["files"].items():
                def progress(done, total, target=target):
                    if total and (done == total or done % (8 * MB) < MB):
                        self.sse({"status": f"Downloading {target}", "completed": done, "total": total})
                local[target] = download_hf_file(plan["repo"], path, token, progress)
            if plan["format"] == "gguf":
                adapter_path = next(iter(local.values()))
            else:
                adapter_path = LORA.convert(os.path.dirname(local["adapter_model.safetensors"]),
                                            plan["base_repo"] or plan.get("base_model"), token, status)
            LORA.add({"name": name, "repo": plan["repo"], "base": plan["base"], "path": adapter_path,
                      "format": plan["format"], "created": int(time.time()),
                      "display": f"{plan['repo'].split('/')[-1]} · LoRA on {short_name(plan['base_repo'] or plan['base'])}"})
            waited = [time.time()]

            def waiting():
                if time.time() - waited[0] > 10:
                    waited[0] = time.time()
                    status(f"Loading {short_name(plan['base_repo'] or plan['base'])} with the adapter "
                           f"(the first time downloads the base, {plan['base_size_bytes'] / 2**30:.1f} GB)")
            status("Starting llama-server on the GPU")
            try:
                LORA.ensure(plan["base"], token, waiting=waiting)
                status("Testing it")
                http_json(f"http://127.0.0.1:{LORA_PORT}/v1/chat/completions", {"Content-Type": "application/json"},
                          json.dumps(LORA.chat_body(name, {"messages": [{"role": "user", "content": "Hi"}],
                                                           "max_tokens": 1})).encode(), method="POST", timeout=900)
            except Exception:
                LORA.remove(name)  # it doesn't load: don't leave a broken model in the list
                raise
            self.sse({"status": "success", "model": name})
        except Exception as e:
            message = e.read().decode(errors="replace")[:300] if isinstance(e, urllib.error.HTTPError) else str(e)
            self.sse({"error": f"Couldn't add the adapter: {message}"})
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


def use_system_certificates():
    """Homebrew's Python ships without CA certificates; macOS keeps them in /etc/ssl/cert.pem (Hugging Face, GitHub…)."""
    paths = ssl.get_default_verify_paths()
    if not (paths.cafile and os.path.exists(paths.cafile)) and os.path.exists("/etc/ssl/cert.pem"):
        context = ssl.create_default_context(cafile="/etc/ssl/cert.pem")
        urllib.request.install_opener(urllib.request.build_opener(urllib.request.HTTPSHandler(context=context)))
        os.environ.setdefault("SSL_CERT_FILE", "/etc/ssl/cert.pem")


def main():
    global TOKEN
    TOKEN = load_token()
    use_system_certificates()
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
