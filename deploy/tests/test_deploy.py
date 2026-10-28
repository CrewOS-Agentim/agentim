import os
import shutil
import subprocess
import tempfile
import unittest

DEPLOY = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MACOS = os.path.join(DEPLOY, "macos")


class PowerGuardTests(unittest.TestCase):
    def decide(self, text):
        return subprocess.check_output(["bash", os.path.join(MACOS, "power-guard.sh"), "decide", text]).decode().strip()

    def test_on_charger_disables_lid_sleep(self):
        self.assertEqual(self.decide("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged;"), "1")

    def test_on_battery_restores_sleep(self):
        self.assertEqual(self.decide("Now drawing from 'Battery Power'\n -InternalBattery-0\t80%; discharging;"), "0")

    def test_unknown_is_safe(self):
        self.assertEqual(self.decide(""), "0")


@unittest.skipUnless(shutil.which("plutil"), "macOS only")
class InstallerTests(unittest.TestCase):
    def test_dry_run_writes_valid_plists(self):
        with tempfile.TemporaryDirectory() as out:
            subprocess.run(["bash", os.path.join(MACOS, "install.sh"), "--dry-run", out], check=True,
                           capture_output=True)
            plists = {
                "watchdog": os.path.join(out, "LaunchAgents", "com.agentim.watchdog.plist"),
                "runner": os.path.join(out, "LaunchAgents", "com.agentim.runner.plist"),
                "power": os.path.join(out, "LaunchDaemons", "com.agentim.power.plist"),
            }
            for name, path in plists.items():
                self.assertTrue(os.path.exists(path), name)
                subprocess.run(["plutil", "-lint", path], check=True, capture_output=True)
            runner = open(plists["runner"]).read()
            self.assertIn("<key>KeepAlive</key><true/>", runner)  # restarted if it stops
            self.assertIn("8766", runner)
            self.assertIn("StartInterval", open(plists["watchdog"]).read())
            self.assertIn("power-guard.sh", open(plists["power"]).read())

    def test_scripts_are_valid_bash(self):
        for name in ("install.sh", "uninstall.sh", "watchdog.sh", "power-guard.sh"):
            subprocess.run(["bash", "-n", os.path.join(MACOS, name)], check=True)
        subprocess.run(["bash", "-n", os.path.join(DEPLOY, "linux", "install.sh")], check=True)


class ConnectClaudeTests(unittest.TestCase):
    """connect-claude.sh adds/removes agentim in Claude Desktop's config and keeps everything else."""

    def run_script(self, config, *args):
        env = {"PATH": "/usr/bin:/bin", "HOME": os.path.dirname(config), "CLAUDE_DESKTOP_CONFIG": config}
        return subprocess.run(["bash", os.path.join(MACOS, "connect-claude.sh"), *args], env=env,
                              capture_output=True, text=True)

    @unittest.skipUnless(os.path.exists("/usr/bin/python3"), "needs /usr/bin/python3")
    def test_add_and_remove(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            config = os.path.join(tmp, "claude_desktop_config.json")
            with open(config, "w") as f:
                json.dump({"mcpServers": {"other": {"command": "x"}}, "theme": "dark"}, f)
            result = self.run_script(config)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = json.load(open(config))
            self.assertEqual(data["theme"], "dark")
            self.assertIn("other", data["mcpServers"])
            self.assertEqual(data["mcpServers"]["agentim"]["command"], "/usr/bin/python3")
            self.assertTrue(data["mcpServers"]["agentim"]["args"][0].endswith("deploy/mcp/agentim_mcp.py"))
            self.assertTrue(os.path.exists(config + ".agentim-backup"))
            self.run_script(config, "remove")
            self.assertEqual(set(json.load(open(config))["mcpServers"]), {"other"})

    @unittest.skipUnless(os.path.exists("/usr/bin/python3"), "needs /usr/bin/python3")
    def test_new_config_and_bad_json(self):
        import json
        with tempfile.TemporaryDirectory() as tmp:
            config = os.path.join(tmp, "Claude", "claude_desktop_config.json")
            self.assertEqual(self.run_script(config).returncode, 0)
            self.assertIn("agentim", json.load(open(config))["mcpServers"])
            with open(config, "w") as f:
                f.write("{broken")
            result = self.run_script(config)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("isn't valid JSON", result.stderr)


if __name__ == "__main__":
    unittest.main()
