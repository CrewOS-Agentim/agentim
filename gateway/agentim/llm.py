"""Non-streaming completions: channels send whole messages."""

import json
import re
import urllib.error
import urllib.request


class LLMError(Exception):
    pass


def post(url, body, headers, timeout):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", **headers})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise LLMError(f"HTTP {e.code}: {e.read().decode(errors='replace')[:300]}") from e
    except (urllib.error.URLError, TimeoutError) as e:
        raise LLMError(str(e)) from e
    except ValueError as e:  # not JSON, e.g. a server that streamed anyway
        raise LLMError(f"unreadable response: {e}") from e


def strip_thinking(text):
    """Qwen3/DeepSeek-style <think>…</think> blocks aren't for the chat."""
    return re.sub(r"<think>.*?</think>", "", text, flags=re.S).strip()


class LLM:
    def __init__(self, config):
        self.config = config

    def complete(self, model, system, messages):
        timeout = 1800 if model.is_media else 600
        if model.backend == "anthropic":
            data = post("https://api.anthropic.com/v1/messages",
                        {"model": model.name, "system": system, "messages": messages, "max_tokens": 2048},
                        {"x-api-key": self.config.anthropic_key, "anthropic-version": "2023-06-01"}, timeout)
            return "".join(b.get("text", "") for b in data.get("content", []))

        if model.backend == "openai":
            url, headers = "https://api.openai.com/v1/chat/completions", {"Authorization": f"Bearer {self.config.openai_key}"}
        else:
            url, headers = f"{model.runner_url}/v1/chat/completions", {"Authorization": f"Bearer {self.config.runner_token}"}
        full = ([{"role": "system", "content": system}] if system else []) + messages
        # Media models only need the last prompt.
        if model.is_media:
            full = [messages[-1]]
        data = post(url, {"model": model.name, "messages": full, "stream": False}, headers, timeout)
        if "choices" in data:
            return strip_thinking(data["choices"][0]["message"].get("content") or "")
        raise LLMError(f"unexpected response: {str(data)[:200]}")
