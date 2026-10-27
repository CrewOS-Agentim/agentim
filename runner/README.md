# agentim runner

Lets agentim (the gateway and the Mac app) use models running on your own computer, either natively or in Docker. It uses only the Python standard library.

| | |
|---|---|
| **One API for every backend** | Ollama, LM Studio, llama.cpp, vLLM and Docker Model Runner are all available through `GET /v1/models` and `POST /v1/chat/completions`, with streaming. |
| **Memory check** | `/v1/system` reports the host's RAM (or the container's limit) and any GPUs. Before any download, `/v1/models/check` and `/v1/models/pull` look up the model's real size (from the Ollama registry, or Hugging Face GGUF files) and **refuse models that won't fit** (HTTP 409). |
| **LTX Desktop bridge** | When the runner runs natively on the Mac with LTX Desktop open, `ltx/video` and `ltx/image` show up as models. Ask for a video in chat and it plays in the app. |
| **Pairing** | Every call needs `Authorization: Bearer <token>`. A token is generated on first start and printed with the URL to enter in the app. |

## Run natively (needed for LTX, and for the Apple GPU)

```sh
python3 runner.py
```

It prints something like:

```
agentim runner 0.1.0 on port 8765 (native)
Memory: 48.0 GB total, 13.0 GB available
  ollama    http://localhost:11434    up
  ltx       up

In AgentHub → Settings → Local servers, add:
  URL:   http://192.168.1.20:8765
  Token: …
```

## Run in Docker

```sh
docker compose up -d                    # runner only; uses Ollama / Docker Model Runner on the host
docker compose --profile ollama up -d   # also runs Ollama in a container (GPU on Linux + NVIDIA)
docker compose logs runner              # shows the URL and token
```

Inside a container, the memory check uses the container's memory: on a Mac, that's the Docker VM's allocation. On a Mac, containers can't use the Apple GPU, so run Ollama natively or use Docker Model Runner and keep only the runner in Docker. LTX needs the native runner, because a container can't see the LTX process. As an alternative, set `LTX_URL` and `LTX_TOKEN` yourself.

## Configuration

| Variable | Default |
|---|---|
| `RUNNER_PORT` | `8765` |
| `RUNNER_TOKEN` | generated and saved in `~/.agenthub-runner/token` |
| `OLLAMA_URL`, `LMSTUDIO_URL`, `LLAMACPP_URL`, `VLLM_URL`, `DOCKER_MODEL_RUNNER_URL` | the usual localhost ports (`host.docker.internal` inside Docker) |
| `RUNNER_DISABLE` | comma-separated backends to skip, e.g. `vllm,llamacpp` |
| `LTX_URL`, `LTX_TOKEN` | auto-discovered from the running LTX Desktop |

## Memory rule

The estimate is: needed = weights × 1.2 + 512 MB (KV cache, activations, runtime). That is compared with:

- **The limit for one model:** about 75% of unified memory on Apple silicon, or 90% of RAM (or the container limit) elsewhere. Over it → `too_large`.
- **Free memory right now.** Over it → `tight`. The pull is allowed, with a warning.
- **Free disk space.** Not enough → `not_enough_disk`.

`force: true` overrides the refusal.

## API

```
GET    /health                       no auth
GET    /v1/system                    host, memory, GPUs, backends, LTX
GET    /v1/models                    every model across backends (+ ltx/video, ltx/image)
POST   /v1/chat/completions          OpenAI format; model = "<backend>/<name>"
POST   /v1/models/check              {"model": "qwen3:4b" | "hf.co/user/repo:Q4_K_M"}
POST   /v1/models/pull               same body; SSE progress; 409 if it won't fit
DELETE /v1/models/ollama/<name>
GET    /files/<id>                   generated media (unguessable ids, supports Range)
```

Tests: `python3 -m unittest test_runner`
