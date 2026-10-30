import os
import subprocess
import tempfile
import unittest

import runner


def git(folder, *args):
    subprocess.run(["git", "-C", folder, *args], check=True, capture_output=True, text=True)


class ResultsTests(unittest.TestCase):
    """What the coding agent changed, and pull requests: a real git repo, a local "origin", a fake gh."""

    def setUp(self):
        root = tempfile.mkdtemp()
        self.origin, self.repo = os.path.join(root, "origin.git"), os.path.join(root, "shop")
        subprocess.run(["git", "init", "--quiet", "--bare", "-b", "main", self.origin], check=True)
        subprocess.run(["git", "init", "--quiet", "-b", "main", self.repo], check=True)
        for key, value in (("user.name", "Test"), ("user.email", "t@example.com")):
            git(self.repo, "config", key, value)
        with open(os.path.join(self.repo, "app.py"), "w") as f:
            f.write("print('hi')\n")
        git(self.repo, "add", "-A")
        git(self.repo, "commit", "--quiet", "-m", "first")
        git(self.repo, "remote", "add", "origin", self.origin)
        git(self.repo, "push", "--quiet", "-u", "origin", "main")
        self.gh_calls = []

        def run(cmd, **kwargs):
            if cmd[0] == "gh":
                self.gh_calls.append(cmd)
                return subprocess.CompletedProcess(cmd, 0, "https://github.com/acme/shop/pull/7\n", "")
            if cmd[-3:] == ["remote", "get-url", "origin"]:  # looks like GitHub; pushes still go to the local origin
                return subprocess.CompletedProcess(cmd, 0, "git@github.com:acme/shop.git\n", "")
            return subprocess.run(cmd, **kwargs)

        self.projects = runner.Projects(agents=object(), run=run, which=lambda name: "/usr/bin/" + name)

    def test_github_repo_from_remote(self):
        for url in ["git@github.com:acme/shop.git", "https://github.com/acme/shop", "https://x@github.com/acme/shop.git/",
                    "ssh://git@github.com/acme/shop.git"]:
            self.assertEqual(runner.Projects.github_repo(url), "acme/shop", url)
        self.assertIsNone(runner.Projects.github_repo("https://gitlab.com/acme/shop.git"))
        self.assertIsNone(runner.Projects.github_repo(""))

    def test_changes_lists_edits_and_new_files(self):
        with open(os.path.join(self.repo, "app.py"), "a") as f:
            f.write("print('bye')\nprint('again')\n")
        with open(os.path.join(self.repo, "new.py"), "w") as f:
            f.write("a = 1\nb = 2\nc = 3")
        files = {f["path"]: f for f in self.projects.changes(self.repo)}
        self.assertEqual(files["app.py"], {"path": "app.py", "status": "modified", "added": 2, "removed": 0})
        self.assertEqual(files["new.py"], {"path": "new.py", "status": "added", "added": 3, "removed": 0})

    def test_pull_request_branches_commits_pushes_and_opens(self):
        with open(os.path.join(self.repo, "app.py"), "a") as f:
            f.write("print('dark mode')\n")
        result = self.projects.pull_request(self.repo, "Add dark mode", "Users asked for it.")
        self.assertEqual(result["url"], "https://github.com/acme/shop/pull/7")
        self.assertEqual(result["number"], 7)
        self.assertEqual((result["repo"], result["base"]), ("acme/shop", "main"))
        self.assertTrue(result["branch"].startswith("agentim/add-dark-mode-"), "never the default branch")
        self.assertEqual([f["path"] for f in result["files"]], ["app.py"])
        # The branch really reached origin, and gh was asked for exactly this PR.
        pushed = subprocess.run(["git", "-C", self.origin, "branch", "--list", result["branch"]], capture_output=True, text=True)
        self.assertIn(result["branch"], pushed.stdout)
        create = self.gh_calls[0]
        self.assertEqual(create[:3], ["gh", "pr", "create"])
        self.assertEqual(create[create.index("--head") + 1], result["branch"])
        self.assertEqual(create[create.index("--title") + 1], "Add dark mode")

    def test_nothing_to_open(self):
        with self.assertRaisesRegex(RuntimeError, "Nothing to put in a pull request"):
            self.projects.pull_request(self.repo, "Nothing", "")
        self.assertEqual(self.gh_calls, [])

    def test_needs_a_github_remote(self):
        projects = runner.Projects(agents=object(), which=lambda name: "/usr/bin/" + name)
        with self.assertRaisesRegex(RuntimeError, "no GitHub remote"):
            projects.pull_request(self.repo, "x", "")


if __name__ == "__main__":
    unittest.main()
