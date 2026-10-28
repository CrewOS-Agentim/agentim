"""Launch: take a startup (or idea) from design to code to deployment to live.

Each startup has a configuration (project folder, stack, test and deploy commands, live URL) and a pipeline of
five stages. Claude Code on the Mac does the design (read-only) and the build (edits, after the founder confirms);
the runner on the Mac runs the test and deploy commands (deploy only after the founder confirms) and checks that
the live URL answers. Every stage reports into the agents room, and the team meets after the design and after
going live.
"""

import re
import threading
import time

STAGES = ("design", "build", "test", "deploy", "live")
# Stages that change code or the outside world: the founder confirms them in the app.
NEEDS_CONFIRMATION = {"build", "test", "deploy"}

PROVIDERS = {
    "none": {"name": "Not yet", "command": ""},
    "vercel": {"name": "Vercel", "command": "npx --yes vercel deploy --prod --yes"},
    "netlify": {"name": "Netlify", "command": "npx --yes netlify-cli deploy --prod"},
    "cloudflare": {"name": "Cloudflare Pages", "command": "npx --yes wrangler pages deploy"},
    "fly": {"name": "Fly.io", "command": "fly deploy"},
    "docker": {"name": "Docker on this Mac", "command": "docker compose up -d --build"},
    "custom": {"name": "Custom command", "command": ""},
}

CONFIG_DEFAULTS = {"folder": "", "stack": "", "deploy": "none", "deploy_command": "", "test_command": "",
                   "live_url": "", "team_reviews": True}

EMOJI = {"design": "📐", "build": "🛠️", "test": "🧪", "deploy": "🚀", "live": "🌍"}
URL = re.compile(r"https?://[^\s'\"<>()\[\]`]+")


def normalize_config(current, fields):
    """Merges the editable fields into the config; strings are trimmed and capped."""
    config = {**CONFIG_DEFAULTS, **(current or {})}
    for key, default in CONFIG_DEFAULTS.items():
        if key not in (fields or {}) or fields[key] is None:
            continue
        value = fields[key]
        config[key] = bool(value) if isinstance(default, bool) else str(value).strip()[:500]
    if config["deploy"] not in PROVIDERS:
        raise ValueError(f"Deploy to one of: {', '.join(PROVIDERS)}.")
    if config["live_url"] and not config["live_url"].startswith(("http://", "https://")):
        raise ValueError("The live URL starts with https://")
    return config


def deploy_command(config):
    return (config.get("deploy_command") or PROVIDERS.get(config.get("deploy"), {}).get("command") or "").strip()


def live_url_from(output):
    """The URL a deploy printed: the last production-looking one, else the last one."""
    urls = [u.rstrip(".,;:") for u in URL.findall(output or "")]
    urls = [u for u in urls if "localhost" not in u or len(urls) == 1]
    good = [u for u in urls if not any(w in u for w in ("inspect", "dashboard", "docs.", "/settings"))]
    return (good or urls or [""])[-1]


def status_line(startup):
    """One paragraph for the team brief: where the launch stands."""
    config, pipeline = startup.get("config") or {}, startup.get("pipeline") or {}
    if not pipeline and not config.get("folder"):
        return ""
    stages = ", ".join(f"{s} {pipeline.get(s, {}).get('status', 'not started')}" for s in STAGES)
    where = PROVIDERS.get(config.get("deploy"), PROVIDERS["none"])["name"]
    failed = next((pipeline[s] for s in STAGES if pipeline.get(s, {}).get("status") == "failed"), None)
    return (f"Launch pipeline (stack: {config.get('stack') or 'not chosen'}; deploy: {where}"
            + (f"; live at {config['live_url']}" if config.get("live_url") else "") + f"): {stages}."
            + (f" The last failure: {failed.get('output', '')[-300:]}" if failed else ""))


class Launch:
    def __init__(self, mode):
        self.mode = mode  # StartupMode: store, gateway (runner client), live, run_round, clock
        self.running = set()
        self.guard = threading.Lock()

    @property
    def store(self):
        return self.mode.store

    def runner(self, path, body, timeout=60):
        return self.mode.gateway.claude.call(path, body, timeout=timeout)

    # ---- config and state

    def configure(self, startup_id, fields):
        startup = self._get(startup_id)
        config = normalize_config(startup.get("config"), fields)
        self.store.save_launch(startup_id, config=config)
        return config

    def _get(self, startup_id):
        startup = self.store.get(startup_id)
        if not startup:
            raise KeyError(startup_id)
        return startup

    def _set(self, startup_id, stage, status, output=None, **extra):
        pipeline = dict(self._get(startup_id).get("pipeline") or {})
        entry = {**pipeline.get(stage, {}), "status": status, "at": self.mode.clock(), **extra}
        if output is not None:
            entry["output"] = output[-4000:]
        pipeline[stage] = entry
        self.store.save_launch(startup_id, pipeline=pipeline)
        return entry

    def _say(self, startup_id, text):
        startup = self._get(startup_id)
        self.store.add_message(startup_id, startup["rounds"] + 1, "claude-code", text)

    # ---- starting a stage

    def start(self, startup_id, stage, confirmed=False):
        startup = self._get(startup_id)
        if stage not in STAGES:
            raise ValueError(f"Pick a stage: {', '.join(STAGES)}.")
        if stage in NEEDS_CONFIRMATION and not confirmed:
            raise ValueError(f"The {stage} step changes your code or the outside world: confirm it first.")
        config = {**CONFIG_DEFAULTS, **(startup.get("config") or {})}
        if stage == "deploy" and not deploy_command(config):
            raise ValueError("Choose where to deploy (or a deploy command) in the launch settings first.")
        if stage == "live" and not config.get("live_url"):
            raise ValueError("There's no live URL yet: deploy first, or set it in the launch settings.")
        with self.guard:
            if startup_id in self.running:
                raise ValueError("A launch step is already running.")
            self.running.add(startup_id)
        self._set(startup_id, stage, "running", output="")
        threading.Thread(target=self._run, args=(startup_id, stage), daemon=True).start()
        return {"started": stage}

    def _run(self, startup_id, stage):
        try:
            getattr(self, f"_{stage}")(startup_id)
        except Exception as e:  # noqa: BLE001 - every failure is reported in the room
            self._set(startup_id, stage, "failed", output=str(e))
            self._say(startup_id, f"{EMOJI[stage]} **{stage.title()}** failed: {e}")
        finally:
            self.mode.live.pop(startup_id, None)
            with self.guard:
                self.running.discard(startup_id)

    # ---- the project folder

    def workspace(self, startup_id):
        """The source the pipeline works in: the configured folder, the first linked project, or a new folder."""
        startup = self._get(startup_id)
        config = {**CONFIG_DEFAULTS, **(startup.get("config") or {})}
        if config["folder"]:
            return {"type": "dir", "path": config["folder"]}
        sources = startup.get("sources") or []
        if sources:
            return sources[0]
        created = self.runner("/v1/projects/create", {"name": startup["name"]})
        config["folder"] = created["folder"]
        self.store.save_launch(startup_id, config=config)
        self._say(startup_id, f"📁 Created the project folder `{created['folder']}`.")
        return {"type": "dir", "path": created["folder"]}

    def _coding(self, startup_id, stage):
        self.mode.live[startup_id] = {"round": self._get(startup_id)["rounds"] + 1, "speaking": "claude-code",
                                      "started": self.mode.clock(), "speakers": ["claude-code"], "direct": True}

    # ---- stages

    def _design(self, startup_id):
        startup = self._get(startup_id)
        config = {**CONFIG_DEFAULTS, **(startup.get("config") or {})}
        source = self.workspace(startup_id)
        self._coding(startup_id, "design")
        where = PROVIDERS[config["deploy"]]["name"] if config["deploy"] != "none" else "a host you recommend"
        prompt = (f"Design version 1 of \"{startup['name']}\": {startup['pitch']}\n\n"
                  f"The team's current plan:\n{startup.get('plan') or '(none yet)'}\n\n"
                  f"Stack: {config['stack'] or 'recommend the simplest stack that ships fast'}. Deploy to: {where}.\n"
                  "Look at what's already in this folder (it may be empty). Don't change any files.\n"
                  "Write the design in under 450 words: the pages or screens and the main user flow, the look "
                  "(colors, type, tone), the data model, the architecture and stack, the files to create, and how "
                  "to run, test and deploy it. Keep v1 small enough to build today.")
        result = self.runner("/v1/projects/task", {"source": source, "prompt": prompt, "agent": "claude-code",
                                                   "mode": "read"}, timeout=1800)
        design = result["output"].strip()
        self._set(startup_id, "design", "done", output=design)
        self._set(startup_id, "build", "waiting")
        self._say(startup_id, f"📐 **Design** for v1:\n\n{design[:2500]}\n\n_Next: build it (you confirm)._")
        if config["team_reviews"]:
            self.mode.run_round(startup_id)

    def _build(self, startup_id):
        startup = self._get(startup_id)
        config = {**CONFIG_DEFAULTS, **(startup.get("config") or {})}
        design = (startup.get("pipeline") or {}).get("design", {}).get("output", "")
        source = self.workspace(startup_id)
        self._coding(startup_id, "build")
        notes = "\n".join(f"- {m['content']}" for m in self.store.messages(startup_id, limit=30)
                          if m["role"] == "founder")[-1500:]
        prompt = (f"Build version 1 of \"{startup['name']}\": {startup['pitch']}\n\n"
                  + (f"The design to follow:\n{design}\n\n" if design else "")
                  + (f"The founder's notes:\n{notes}\n\n" if notes else "")
                  + f"Stack: {config['stack'] or 'the simplest one that ships fast'}.\n"
                  "If the folder is empty, scaffold the project. Make it run end to end, add at least one automated "
                  "test or build check, and a README with how to run, test and deploy it. Don't deploy, don't push, "
                  "and never write secrets into files. End with a short summary, then one line exactly like "
                  "`TEST_COMMAND: <the shell command that runs the tests or build check>`.")
        result = self.runner("/v1/projects/task", {"source": source, "prompt": prompt, "agent": "claude-code",
                                                   "mode": "edit", "confirmed": True, "timeout": 3600}, timeout=3700)
        output = result["output"].strip()
        match = re.search(r"TEST_COMMAND:\s*`?([^`\n]+)`?", output)
        if match and not config["test_command"]:
            config["test_command"] = match.group(1).strip()
            self.store.save_launch(startup_id, config=config)
        changed = result.get("changed") or "no files changed"
        self._set(startup_id, "build", "done", output=output, changed=changed)
        self._say(startup_id, f"🛠️ **Built** v1.\n\n{output[:2000]}\n\nChanged:\n```\n{changed}\n```")
        # The build is checked right away (part of the build the founder approved), with one fix attempt.
        self._set(startup_id, "test", "running", output="")
        self._test(startup_id, fix=True)

    def _test(self, startup_id, fix=False):
        config = {**CONFIG_DEFAULTS, **(self._get(startup_id).get("config") or {})}
        command = config["test_command"]
        if not command:
            self._set(startup_id, "test", "skipped", output="No test command: set one in the launch settings.")
            self._ready_to_deploy(startup_id)
            return
        source = self.workspace(startup_id)
        result = self.runner("/v1/projects/run", {"source": source, "command": command, "confirmed": True,
                                                  "timeout": 900}, timeout=960)
        if result["exit_code"] != 0 and fix:
            self._say(startup_id, f"🧪 `{command}` failed; Claude Code is fixing it.\n```\n{result['output'][-800:]}\n```")
            self._coding(startup_id, "test")
            self.runner("/v1/projects/task", {
                "source": source, "agent": "claude-code", "mode": "edit", "confirmed": True, "timeout": 1800,
                "prompt": f"The check `{command}` fails with:\n{result['output'][-3000:]}\n\nFix the code so it passes. "
                          "Don't weaken or delete tests to make them pass. Don't deploy or push."}, timeout=1900)
            result = self.runner("/v1/projects/run", {"source": source, "command": command, "confirmed": True,
                                                      "timeout": 900}, timeout=960)
        ok = result["exit_code"] == 0
        self._set(startup_id, "test", "done" if ok else "failed", output=result["output"], seconds=result.get("seconds"))
        self._say(startup_id, f"🧪 `{command}` {'passed' if ok else 'failed'}.\n```\n{result['output'][-800:]}\n```")
        if ok:
            self._ready_to_deploy(startup_id)

    def _ready_to_deploy(self, startup_id):
        config = {**CONFIG_DEFAULTS, **(self._get(startup_id).get("config") or {})}
        self._set(startup_id, "deploy", "waiting")
        if not deploy_command(config):
            self._say(startup_id, "🚀 Ready to deploy: choose where in the launch settings, then press Deploy.")

    def _deploy(self, startup_id):
        config = {**CONFIG_DEFAULTS, **(self._get(startup_id).get("config") or {})}
        command = deploy_command(config)
        source = self.workspace(startup_id)
        result = self.runner("/v1/projects/run", {"source": source, "command": command, "confirmed": True,
                                                  "timeout": 1800}, timeout=1860)
        if result["exit_code"] != 0:
            raise RuntimeError(f"`{command}` exited with {result['exit_code']}:\n```\n{result['output'][-1200:]}\n```")
        url = config["live_url"] or live_url_from(result["output"])
        if url and not config["live_url"]:
            config["live_url"] = url
            self.store.save_launch(startup_id, config=config)
        self._set(startup_id, "deploy", "done", output=result["output"], url=url)
        self._say(startup_id, f"🚀 **Deployed** with `{command}`" + (f": {url}" if url else "."))
        if url:
            self._set(startup_id, "live", "running", output="")
            self._live(startup_id)

    def _live(self, startup_id):
        config = {**CONFIG_DEFAULTS, **(self._get(startup_id).get("config") or {})}
        try:
            check = self.runner("/v1/projects/check", {"url": config["live_url"]}, timeout=40)
        except Exception as e:  # noqa: BLE001 - a failed check is a "not live", not a failed deploy
            check = {"ok": False, "error": str(e)}
        ok = bool(check.get("ok"))
        detail = f"HTTP {check.get('status')} in {check.get('ms')} ms" if check.get("status") else check.get("error", "no answer")
        self._set(startup_id, "live", "done" if ok else "failed", output=detail, url=config["live_url"],
                  checked=self.mode.clock())
        self._say(startup_id, f"🌍 {config['live_url']} is {'**live**' if ok else '**not answering**'} ({detail}).")
        if ok and config["team_reviews"]:
            self.mode.run_round(startup_id)


def pipeline_view(startup):
    """The pipeline as the app shows it: every stage, in order."""
    pipeline = startup.get("pipeline") or {}
    return [{"stage": s, **{"status": "idle"}, **pipeline.get(s, {})} for s in STAGES]


def wait_for(launch, startup_id, timeout=5):
    """Tests: wait until no step runs for this startup."""
    end = time.time() + timeout
    while startup_id in launch.running and time.time() < end:
        time.sleep(0.01)
