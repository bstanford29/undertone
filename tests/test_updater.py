from __future__ import annotations

import io
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from undertone import updater

GIT_ENV = {**os.environ, "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.com",
           "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.com",
           "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}


def git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True,
                          env=GIT_ENV).stdout.strip()


def commit(repo: Path, path: str, text: str, title: str) -> str:
    target = repo / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    git(repo, "add", path)
    git(repo, "commit", "--quiet", "-m", title)
    return git(repo, "rev-parse", "HEAD")


def make_app(path: Path, marker: str) -> Path:
    (path / "Contents" / "MacOS").mkdir(parents=True)
    (path / "Contents" / "MacOS" / "Undertone").write_text(marker)
    return path


def marker(app: Path) -> str:
    return (app / "Contents" / "MacOS" / "Undertone").read_text()


class UpdaterTests(unittest.TestCase):
    """A bare repo stands in for GitHub; `upstream` is where new commits land."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.origin = root / "origin.git"
        self.upstream = root / "upstream"
        self.checkout = root / "checkout"
        self.state = root / "state"
        self.apps = root / "Applications"
        subprocess.run(["git", "init", "--quiet", "--bare", "-b", "main", str(self.origin)], check=True, env=GIT_ENV)
        subprocess.run(["git", "clone", "--quiet", str(self.origin), str(self.upstream)], check=True, env=GIT_ENV,
                       capture_output=True)
        git(self.upstream, "switch", "--quiet", "-c", "main")
        self.first = commit(self.upstream, "engine/undertone/a.py", "one\n", "First")
        git(self.upstream, "push", "--quiet", "origin", "main")
        subprocess.run(["git", "clone", "--quiet", str(self.origin), str(self.checkout)], check=True, env=GIT_ENV,
                       capture_output=True)
        self.app = make_app(self.apps / "Undertone.app", "old app")
        self.restarts: list[bool] = []
        for name, value in (("restart_engine", lambda: self.restarts.append(True) or True),
                            ("signing_identity", lambda app: "Apple Development: Test (TEAM)"),
                            ("_identity_in_keychain", lambda identity: True),
                            ("_xcode_ready", lambda: True)):
            patcher = patch.object(updater, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def push(self, path: str, title: str, text: str = "two\n") -> str:
        sha = commit(self.upstream, path, text, title)
        git(self.upstream, "push", "--quiet", "origin", "main")
        return sha

    def apply(self, **kwargs):
        return updater.apply(self.checkout, self.app, state_dir=self.state, out=io.StringIO(), **kwargs)

    # Check

    def test_check_lists_new_changes_and_what_they_touch(self):
        self.assertEqual(updater.check(self.checkout, self.app)["state"], "current")
        self.push("engine/undertone/a.py", "Fix the engine")
        info = updater.check(self.checkout, self.app)
        self.assertEqual(info["state"], "ready")
        self.assertEqual(info["behind"], 1)
        self.assertEqual(info["changes"][0]["title"], "Fix the engine")
        self.assertTrue(info["engine_changed"])
        self.assertFalse(info["app_changed"])
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.first, "a check never moves the checkout")

    def test_check_blocks_local_work(self):
        self.push("engine/undertone/a.py", "Fix the engine")
        (self.checkout / "engine/undertone/a.py").write_text("local edit\n")
        self.assertIn("uncommitted changes", updater.check(self.checkout, self.app)["message"])
        git(self.checkout, "checkout", "--quiet", "--", ".")
        git(self.checkout, "switch", "--quiet", "-c", "experiment")
        self.assertIn("branch experiment", updater.check(self.checkout, self.app)["message"])
        git(self.checkout, "switch", "--quiet", "main")
        commit(self.checkout, "notes.txt", "mine\n", "Local only")
        self.assertIn("not on GitHub", updater.check(self.checkout, self.app)["message"])

    def test_app_change_without_xcode_is_blocked(self):
        self.push("app/Sources/UndertoneApp/View.swift", "Change the app")
        with patch.object(updater, "_xcode_ready", lambda: False):
            info = updater.check(self.checkout, self.app)
        self.assertEqual(info["state"], "blocked")
        self.assertIn("needs Xcode", info["message"])

    # Apply

    def test_engine_only_update_fast_forwards_and_restarts_the_engine(self):
        new = self.push("engine/undertone/a.py", "Fix the engine")
        with patch.object(updater, "_build_app", side_effect=AssertionError("no app change, no build")):
            result = self.apply()
        self.assertEqual(result["state"], "done")
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), new)
        self.assertEqual(self.restarts, [True])
        self.assertFalse(result["relaunch"])
        self.assertEqual(marker(self.app), "old app")
        saved = updater.read_status(self.state)
        self.assertEqual(saved["state"], "done")
        self.assertTrue(saved["can_undo"])

    def test_failed_build_moves_the_checkout_back_and_keeps_the_app(self):
        self.push("app/Sources/UndertoneApp/View.swift", "Break the build")
        with patch.object(updater, "_build_app", side_effect=updater.StepFailed("build_app.sh failed (exit 1).")):
            result = self.apply()
        self.assertEqual(result["state"], "failed")
        self.assertIn("back on", result["message"])
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.first)
        self.assertEqual(marker(self.app), "old app")
        self.assertEqual(self.restarts, [])
        self.assertFalse(updater.read_status(self.state)["can_undo"])

    def test_app_update_keeps_the_old_app_and_undo_restores_it(self):
        new = self.push("app/Sources/UndertoneApp/View.swift", "Change the app")
        staged = make_app(self.apps.parent / "build" / "Undertone", "new app")
        with patch.object(updater, "_build_app", return_value=staged):
            result = self.apply()
        self.assertEqual(result["state"], "done")
        self.assertTrue(result["relaunch"])
        self.assertEqual(marker(self.app), "new app")
        self.assertEqual(marker(self.apps / updater.PREVIOUS_APP_NAME), "old app")
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), new)

        undone = updater.undo(self.checkout, state_dir=self.state, out=io.StringIO())
        self.assertEqual(undone["state"], "done")
        self.assertTrue(undone["relaunch"])
        self.assertEqual(marker(self.app), "old app")
        self.assertFalse((self.apps / updater.PREVIOUS_APP_NAME).exists())
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.first)
        self.assertFalse(updater.read_status(self.state)["can_undo"], "undo works once")

    def test_dry_run_changes_nothing(self):
        self.push("engine/undertone/a.py", "Fix the engine")
        result = self.apply(dry_run=True)
        self.assertIn("Dry run", result["message"])
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), self.first)
        self.assertEqual(self.restarts, [])

    def test_only_one_run_at_a_time(self):
        self.push("engine/undertone/a.py", "Fix the engine")
        with updater._Run("update", self.state, io.StringIO()):
            self.assertTrue(updater.is_running(self.state))
            with self.assertRaises(updater.StepFailed):
                self.apply()
        self.assertFalse(updater.is_running(self.state))

    def test_a_run_that_died_reads_as_failed(self):
        self.state.mkdir()
        (self.state / "update-status.json").write_text(json.dumps(
            {"state": "running", "pid": 999_999, "started_at": 0}))
        self.assertEqual(updater.read_status(self.state)["state"], "failed")

    def test_detached_run_finishes_on_its_own(self):
        """The engine's path: a separate process does the update and reports
        through the status file. A docs-only change needs no restart or build."""
        new = self.push("docs/notes.md", "Update the docs")
        started = updater.start_detached("apply", repo=self.checkout, state_dir=self.state)
        self.assertEqual(started["state"], "running")
        for _ in range(200):
            status = updater.read_status(self.state)
            if status["state"] != "running":
                break
            time.sleep(0.05)
        self.assertEqual(status["state"], "done", (self.state / "update.log").read_text())
        self.assertEqual(git(self.checkout, "rev-parse", "HEAD"), new)
        self.assertIn("Moving the checkout", (self.state / "update.log").read_text())

    def test_only_the_installed_app_may_be_replaced(self):
        self.assertEqual(updater.valid_app_path(str(Path.home() / "Applications/Undertone.app")),
                         Path.home() / "Applications/Undertone.app")
        for bad in ("/tmp/Undertone.app", "Undertone.app", str(Path.home() / "Applications/Other.app")):
            with self.assertRaises(ValueError):
                updater.valid_app_path(bad)


if __name__ == "__main__":
    unittest.main()
