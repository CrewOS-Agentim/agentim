# Contributing to agentim 🐙

Thanks for helping Agent Tim grow more tentacles!

## Good first contributions

- **A new skill.** Drop a `SKILL.md` into `gateway/skills/`, with front matter for `name`, `description` and `triggers`. Both the gateway and the Mac app pick it up. Add it to the list in `gateway/tests/test_gateway.py`.
- **A new channel.** Subclass `Channel` in `gateway/agentim/channels/`. Implement `run`, `send_text` and `send_media`, and turn platform events into `deliver(chat_id, user_id, text)`. Put the parsing in a pure function and unit-test it, like `parse_update` for Telegram.
- **A new model backend.** Anything OpenAI-compatible is one line in `runner/runner.py → default_backends()`.

## Ground rules

- Keep the runner on the Python standard library only.
- Every change comes with tests, and none of them may need network access or tokens: use fakes, as the existing tests do.
- Local first: new features must work with local models only. Cloud is always optional.
- Never route sensitive prompts to the cloud.

## Running everything

```sh
python3 -m unittest discover -s gateway/tests
(cd runner && python3 -m unittest test_runner)
python3 -m unittest discover -s deploy/tests
xcodegen generate && xcodebuild -project agentim.xcodeproj -scheme AgentHub \
  -destination platform=macOS -skipMacroValidation -skipPackagePluginValidation test
```

Screenshots for the website come from the app's demo mode: `agentim -demo YES -section models`.
