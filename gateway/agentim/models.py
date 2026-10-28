"""Model catalog: runner models (local Hugging Face in Docker, LTX) + optional cloud, and default pulls."""

import json
import re
import logging
import threading
import time
import urllib.request

from .router import CLOUD_MODELS, model_from_runner

log = logging.getLogger("agentim.models")

NOT_CHAT = re.compile(r"whisper|kokoro|piper|\btts\b|-tts|embed|rerank|speaches|silero", re.I)


class RunnerAPI:
    def __init__(self, url, token):
        self.url, self.token = url, token

    def _request(self, path, body=None, timeout=15):
        req = urllib.request.Request(
            f"{self.url}{path}", data=json.dumps(body).encode() if body is not None else None,
            method="POST" if body is not None else "GET",
            headers={"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        return urllib.request.urlopen(req, timeout=timeout)

    def models(self):
        with self._request("/v1/models") as resp:
            return json.loads(resp.read())["data"]

    def check(self, ref):
        with self._request("/v1/models/check", {"model": ref}) as resp:
            return json.loads(resp.read())

    def pull(self, ref):
        """Blocks until the pull finishes; returns the last status line."""
        last = {}
        with self._request("/v1/models/pull", {"model": ref}, timeout=7200) as resp:
            for line in resp:
                line = line.decode().strip()
                if line.startswith("data:") and line[5:].strip() not in ("", "[DONE]"):
                    last = json.loads(line[5:])
        return last


class Catalog:
    """Caches the model list; refreshes from the runners every `ttl` seconds."""

    def __init__(self, config, api_factory=RunnerAPI, ttl=30):
        self.config = config
        self.apis = [api_factory(url, config.runner_token) for url in config.runner_urls]
        self.ttl = ttl
        self.cached, self.fetched_at = [], 0.0
        self.lock = threading.Lock()

    def cloud(self):
        models = []
        if self.config.anthropic_key:
            models += CLOUD_MODELS["anthropic"]
        if self.config.openai_key:
            models += CLOUD_MODELS["openai"]
        return models

    def __call__(self):
        with self.lock:
            if time.time() - self.fetched_at > self.ttl:
                self.cached, self.fetched_at = self.refresh(), time.time()
            return list(self.cached)

    def refresh(self):
        models = []
        for api in self.apis:
            try:
                # Older runners may list speech/embedding models; they can't chat.
                models += [model_from_runner(info, api.url) for info in api.models()
                           if info.get("kind") in ("video", "image", "agent") or not NOT_CHAT.search(info["id"])]
            except Exception as e:
                log.warning("runner %s unavailable: %s", api.url, e)
        seen, unique = set(), []
        for model in models + self.cloud():
            if model.id not in seen:
                seen.add(model.id)
                unique.append(model)
        return unique

    def invalidate(self):
        with self.lock:
            self.fetched_at = 0


def ensure_defaults(api, refs, installed_ids):
    """Pulls each default model that isn't installed, skipping ones the memory check rejects."""
    results = {}
    for ref in refs:
        if f"ollama/{ref}" in installed_ids:
            results[ref] = "installed"
            continue
        try:
            check = api.check(ref)
        except Exception as e:
            results[ref] = f"check failed: {e}"
            continue
        if not check.get("can_pull"):
            results[ref] = f"skipped: {check.get('verdict')}"
            log.warning("not pulling %s: %s", ref, check.get("verdict"))
            continue
        log.info("pulling %s (%.1f GB)", ref, check.get("weight_bytes", 0) / 2**30)
        status = api.pull(ref)
        results[ref] = "pulled" if status.get("status") == "success" else f"pull failed: {status}"
    return results


def bootstrap(config, catalog, retry_every=20, sleep=time.sleep):
    """Background job: wait for the first runner, then pull the default Hugging Face models."""
    if not config.default_models or not catalog.apis:
        return
    api = catalog.apis[0]
    while True:
        try:
            installed = {m["id"] for m in api.models()}
            break
        except Exception as e:
            log.info("waiting for runner at %s: %s", api.url, e)
            sleep(retry_every)
    log.info("default models: %s", ensure_defaults(api, config.default_models, installed))
    catalog.invalidate()
