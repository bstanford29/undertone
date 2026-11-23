from __future__ import annotations

import io
import json
import os
import shutil
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
        # The checkout's origin says GitHub, as a real clone's does; git's own
        # insteadOf sends the fetches to the local stand-in.
        git(self.checkout, "remote", "set-url", "origin", "https://github.com/example/undertone.git")
        git(self.checkout, "config", f"url.{self.origin}.insteadOf", "https://github.com/example/undertone.git")
        self.app = make_app(self.apps / "Undertone.app", "old app")
        self.installs: list[str] = []
        self.restores: list[tuple[str, str]] = []
        def freeze(folder, commit, out):
            path = folder / f"update-packages-{commit[:12]}.txt"
            path.write_text(f"packages at {commit}\n")
            return path
        for name, value in (("signing_identity", lambda app: "Apple Development: Test (TEAM)"),
                            ("_engine_imports", lambda repo, out: None),
                            ("_freeze_packages", freeze),
                            ("_restore_packages", lambda snapshot, repo, out: self.restores.append(
                                (snapshot.read_text().strip(), git(repo, "rev-parse", "HEAD")))),
                            ("designated_requirement", lambda app: 'identifier "com.undertone.app"'),
                            ("_identity_in_keychain", lambda identity: True),
                            ("_xcode_ready", lambda: True),
                            ("_which", lambda name: "/usr/bin/true"),
                            ("_install_packages", lambda repo, out: self.installs.append(git(repo, "rev-parse", "HEAD")))):
            patcher = patch.object(updater, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def push(self, path: str, title: str, text: str = "two\n") -> str:
        sha = commit(self.upstream, path, text, title)
        git(self.upstream, "push", "--quiet", "origin", "main")
        return sha

    def apply(self, **kwargs):
        return updater.apply(self.checkout, self.app, state_dir=self.state, out=io.StringIO(), **kwargs)

    def undo(self):
        return updater.undo(self.checkout, state_dir=self.state, out=io.StringIO())

    def head(self) -> str:
        return git(self.checkout, "rev-parse", "HEAD")

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
        self.assertEqual(self.head(), self.first, "a check never moves the checkout")

    def test_moving_a_file_out_of_the_engine_counts_as_an_engine_change(self):
        (self.upstream / "docs").mkdir()
        git(self.upstream, "mv", "engine/undertone/a.py", "docs/a.py")
        git(self.upstream, "commit", "--quiet", "-m", "Move a module")
        git(self.upstream, "push", "--quiet", "origin", "main")
        self.assertTrue(updater.check(self.checkout, self.app)["engine_changed"])

    def test_check_ignores_a_custom_fetch_refspec(self):
        git(self.checkout, "config", "remote.origin.fetch", "+refs/heads/other:refs/remotes/origin/other")
        new = self.push("engine/undertone/a.py", "Fix the engine")
        info = updater.check(self.checkout, self.app)
        self.assertEqual((info["state"], info["remote"]), ("ready", new))

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

    def test_ahead_only_is_blocked_not_up_to_date(self):
        commit(self.checkout, "notes.txt", "mine\n", "Local only")
        self.assertEqual(updater.check(self.checkout, self.app)["state"], "blocked")

    def test_a_file_the_update_would_overwrite_blocks_it(self):
        self.push("docs/draft.md", "Add a doc")
        draft = self.checkout / "docs/draft.md"
        draft.parent.mkdir()
        draft.write_text("my own notes\n")
        (self.checkout / ".git/info/exclude").write_text("docs/draft.md\n")  # ignored: git overwrites those silently
        result = self.apply()
        self.assertEqual(result["state"], "failed")
        self.assertIn("docs/draft.md", result["message"])
        self.assertEqual(draft.read_text(), "my own notes\n")
        self.assertEqual(self.head(), self.first)

    def test_an_ignored_file_where_the_update_needs_a_folder_blocks_it(self):
        self.push("docs/readme.md", "Add docs")
        (self.checkout / "docs").write_text("my notes, saved as a file called docs\n")
        (self.checkout / ".git/info/exclude").write_text("docs\n")
        result = self.apply()
        self.assertEqual(result["state"], "failed")
        self.assertIn("docs", result["message"])
        self.assertEqual((self.checkout / "docs").read_text(), "my notes, saved as a file called docs\n")

    def test_a_tracked_file_that_becomes_a_folder_is_not_a_collision(self):
        git(self.upstream, "rm", "--quiet", "engine/undertone/a.py")
        commit(self.upstream, "engine/undertone/a.py/inner.py", "x = 1\n", "Turn a file into a folder")
        git(self.upstream, "push", "--quiet", "origin", "main")
        self.assertEqual(updater.check(self.checkout, self.app)["state"], "ready")
        self.assertEqual(self.apply()["state"], "done")
        self.assertTrue((self.checkout / "engine/undertone/a.py/inner.py").is_file())

    def test_only_a_github_origin_is_updated_from(self):
        self.push("engine/undertone/a.py", "Fix the engine")
        git(self.checkout, "remote", "set-url", "origin", str(self.origin))
        info = updater.check(self.checkout, self.app)
        self.assertEqual(info["state"], "blocked")
        self.assertIn("not on GitHub", info["message"])

    def test_the_engine_is_stale_until_it_restarts_whoever_moved_the_checkout(self):
        self.push("docs/notes.md", "Docs only")
        self.assertEqual(self.apply()["state"], "done")
        self.assertFalse(updater.engine_stale(self.first, self.checkout), "a docs change needs no restart")
        self.push("engine/undertone/a.py", "Fix the engine", text="three\n")
        self.assertEqual(self.apply()["state"], "done")
        self.assertTrue(updater.engine_stale(self.first, self.checkout))
        self.assertEqual(self.apply()["state"], "done", "a later 'up to date' run")
        self.assertTrue(updater.engine_stale(self.first, self.checkout), "still stale: it does not hang on the last run")
        self.assertFalse(updater.engine_stale(self.head(), self.checkout), "a restarted engine is current")

    def test_app_change_without_xcode_is_blocked(self):
        self.push("app/Sources/UndertoneApp/View.swift", "Change the app")
        with patch.object(updater, "_xcode_ready", lambda: False):
            info = updater.check(self.checkout, self.app)
        self.assertEqual(info["state"], "blocked")
        self.assertIn("needs Xcode", info["message"])

    # Apply

    def test_engine_only_update_fast_forwards_and_leaves_the_restart_to_the_app(self):
        new = self.push("engine/undertone/a.py", "Fix the engine")
        with patch.object(updater, "_build_app", side_effect=AssertionError("no app change, no build")):
            result = self.apply()
        self.assertEqual(result["state"], "done")
        self.assertEqual(self.head(), new)
        self.assertTrue(result["restart_engine"])
        self.assertFalse(result["relaunch"])
        self.assertEqual(marker(self.app), "old app")
        self.assertTrue(updater.read_status(self.state)["can_undo"])

    def test_apply_installs_only_the_commit_that_was_checked(self):
        checked = updater.check(self.checkout, self.app)["remote"]
        self.push("engine/undertone/a.py", "Pushed after the check")
        result = self.apply(expect=checked)
        self.assertEqual(result["state"], "failed")
        self.assertIn("changed since the last check", result["message"])
        self.assertEqual(self.head(), self.first)

    def test_failed_build_moves_the_checkout_back_and_keeps_the_app(self):
        self.push("app/Sources/UndertoneApp/View.swift", "Break the build")
        with patch.object(updater, "_build_app", side_effect=updater.StepFailed("build_app.sh failed (exit 1).")):
            result = self.apply()
        self.assertEqual(result["state"], "failed")
        self.assertIn("back on", result["message"])
        self.assertEqual(self.head(), self.first)
        self.assertEqual(marker(self.app), "old app")
        self.assertFalse(updater.read_status(self.state)["can_undo"])

    def test_failed_package_install_restores_the_exact_old_packages(self):
        self.push("pyproject.toml", "Add a dependency", text="[project]\n")
        with patch.object(updater, "_install_packages", side_effect=updater.StepFailed("uv failed (exit 2).")):
            result = self.apply()
        self.assertEqual(result["state"], "failed")
        self.assertEqual(self.restores, [(f"packages at {self.first}", self.first)],
                         "the package list saved before the install comes back, at the old commit")
        self.assertEqual(self.head(), self.first)

    def test_a_new_engine_that_does_not_load_is_rolled_back(self):
        self.push("engine/undertone/a.py", "Break the engine")
        with patch.object(updater, "_engine_imports", side_effect=updater.StepFailed("The new engine does not load.")):
            result = self.apply()
        self.assertEqual(result["state"], "failed")
        self.assertIn("does not load", result["message"])
        self.assertEqual(self.head(), self.first)

    def test_go_back_restores_the_packages_from_before_the_update(self):
        new = self.push("pyproject.toml", "Add a dependency", text="[project]\n")
        self.assertEqual(self.apply()["state"], "done")
        self.assertEqual(self.undo()["state"], "done")
        self.assertEqual(self.restores, [(f"packages at {self.first}", self.first)])
        self.assertNotEqual(self.head(), new)

    def test_rollback_never_moves_a_branch_the_user_switched_to(self):
        self.push("app/Sources/UndertoneApp/View.swift", "Change the app")
        def switch_then_fail(*args):
            git(self.checkout, "switch", "--quiet", "-c", "mine")
            raise updater.StepFailed("build_app.sh failed (exit 1).")
        with patch.object(updater, "_build_app", side_effect=switch_then_fail):
            result = self.apply()
        self.assertEqual(result["state"], "failed")
        self.assertIn("left it alone", result["message"])
        self.assertEqual(git(self.checkout, "rev-parse", "mine"), git(self.checkout, "rev-parse", "main"),
                         "the branch the user switched to was not reset")

    def test_app_update_keeps_the_old_app_and_go_back_restores_it(self):
        new = self.push("app/Sources/UndertoneApp/View.swift", "Change the app")
        staged = make_app(self.apps.parent / "build" / "Undertone", "new app")
        with patch.object(updater, "_build_app", return_value=staged):
            result = self.apply()
        self.assertEqual(result["state"], "done")
        self.assertTrue(result["relaunch"])
        self.assertEqual(marker(self.app), "new app")
        self.assertEqual(marker(self.apps / updater.PREVIOUS_APP_NAME), "old app")
        self.assertEqual(self.head(), new)

        undone = self.undo()
        self.assertEqual(undone["state"], "done")
        self.assertTrue(undone["relaunch"])
        self.assertTrue(undone["restart_engine"])
        self.assertEqual(marker(self.app), "old app")
        self.assertFalse((self.apps / updater.PREVIOUS_APP_NAME).exists())
        self.assertEqual(self.head(), self.first)
        self.assertFalse(updater.read_status(self.state)["can_undo"], "Go back works once")

    def test_go_back_refuses_once_the_checkout_has_moved_on(self):
        self.push("engine/undertone/a.py", "Fix the engine")
        self.assertEqual(self.apply()["state"], "done")
        mine = commit(self.checkout, "notes.txt", "mine\n", "Local work after the update")
        result = self.undo()
        self.assertEqual(result["state"], "failed")
        self.assertEqual(self.head(), mine)
        self.assertTrue((self.checkout / "notes.txt").exists())

    def test_go_back_refuses_when_the_earlier_app_is_missing(self):
        self.push("app/Sources/UndertoneApp/View.swift", "Change the app")
        staged = make_app(self.apps.parent / "build" / "Undertone", "new app")
        with patch.object(updater, "_build_app", return_value=staged):
            new = self.apply()["new"]
        shutil.rmtree(self.apps / updater.PREVIOUS_APP_NAME)
        result = self.undo()
        self.assertEqual(result["state"], "failed")
        self.assertIn("earlier app is missing", result["message"])
        self.assertEqual(self.head(), new, "nothing moved")

    def test_only_one_run_at_a_time(self):
        self.push("engine/undertone/a.py", "Fix the engine")
        with updater._Run("update", self.state, io.StringIO()):
            self.assertTrue(updater.is_running(self.state))
            with self.assertRaises(updater.StepFailed):
                self.apply()
            with self.assertRaises(updater.StepFailed):
                updater.start_detached("apply", repo=self.checkout, state_dir=self.state)
        self.assertFalse(updater.is_running(self.state))

    def test_a_run_that_no_longer_holds_the_lock_reads_as_failed(self):
        self.state.mkdir()
        (self.state / "update-status.json").write_text(json.dumps({"state": "running", "started_at": 0}))
        self.assertEqual(updater.read_status(self.state)["state"], "failed")

    def test_detached_run_finishes_on_its_own(self):
        """The engine's path: it takes the lock, hands it to a separate process,
        and that process reports through the status file. A docs-only change
        needs no build."""
        new = self.push("docs/notes.md", "Update the docs")
        started = updater.start_detached("apply", repo=self.checkout, state_dir=self.state)
        self.assertEqual(started["state"], "running")
        for _ in range(200):
            status = updater.read_status(self.state)
            if status["state"] != "running":
                break
            time.sleep(0.05)
        self.assertEqual(status["state"], "done", (self.state / "update.log").read_text())
        self.assertEqual(status["run_id"], started["run_id"])
        self.assertEqual(self.head(), new)
        self.assertFalse(updater.is_running(self.state))

    def test_only_the_installed_app_may_be_replaced(self):
        self.assertEqual(updater.valid_app_path(str(Path.home() / "Applications/Undertone.app")),
                         Path.home() / "Applications/Undertone.app")
        for bad in ("/tmp/Undertone.app", "Undertone.app", str(Path.home() / "Applications/Other.app")):
            with self.assertRaises(ValueError):
                updater.valid_app_path(bad)


if __name__ == "__main__":
    unittest.main()
