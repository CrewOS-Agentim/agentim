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


if __name__ == "__main__":
    unittest.main()
