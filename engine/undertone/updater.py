"""Update Undertone from its own git checkout: check, apply, and undo.

The engine runs from the checkout it updates. A check runs one `git fetch` of
`main` from GitHub; it sends no audio, transcripts, or settings. An apply runs
in its own process, so it outlives the engine restart at its end. A failed
step moves the checkout back to where it was and leaves the app untouched.
"""
from __future__ import annotations

import fcntl
import json
import os
import plistlib
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Any

from . import config as settings

REPO_ROOT = Path(__file__).resolve().parents[2]
REMOTE = "origin"
BRANCH = "main"
ENGINE_LABEL = "com.undertone.engine"
APP_NAME = "Undertone.app"
PREVIOUS_APP_NAME = "Undertone (previous).app"
DEPENDENCY_FILES = {"pyproject.toml"}
MAX_CHANGES = 20
FETCH_TIMEOUT_SECONDS = 60
BUILD_TIMEOUT_SECONDS = 45 * 60
INSTALL_TIMEOUT_SECONDS = 15 * 60
START_GRACE_SECONDS = 30
TOOL_DIRS = ("~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.cargo/bin")


class StepFailed(Exception):
    """One update step failed. The message is a plain sentence for the user."""


def installed_app_paths() -> list[Path]:
    """The two places the app runs from, the same list as RuntimeIdentity."""
    return [Path.home() / "Applications" / APP_NAME, Path("/Applications") / APP_NAME]


def default_app_path() -> Path | None:
    return next((path for path in installed_app_paths() if path.is_dir()), None)


def valid_app_path(value: str) -> Path:
    """Only an installed Undertone.app may be replaced."""
    path = Path(value).expanduser()
    if not path.is_absolute() or path not in installed_app_paths():
        raise ValueError("app_path must be the installed Undertone.app")
    return path


# MARK: - Small helpers

def _git(repo: Path, *args: str, timeout: int = 30) -> str:
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0", "LC_ALL": "C"}
    try:
        done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                              timeout=timeout, env=env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise StepFailed(f"git {args[0]} did not finish.") from exc
    if done.returncode != 0:
        raise StepFailed(f"git {args[0]} failed: {done.stderr.strip()[:300]}")
    return done.stdout.strip()


def _which(name: str) -> str | None:
    extra = os.pathsep.join(str(Path(d).expanduser()) for d in TOOL_DIRS)
    return shutil.which(name, path=os.environ.get("PATH", "") + os.pathsep + extra)


def _xcode_ready() -> bool:
    """SwiftUI needs full Xcode; Command Line Tools alone cannot build the app."""
    try:
        return subprocess.run(["xcodebuild", "-version"], capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def signing_identity(app: Path | None) -> str | None:
    """The identity that signed the installed app. Signing the new build with the
    same one keeps Microphone, Accessibility, and Input Monitoring granted."""
    override = os.environ.get("UNDERTONE_SIGNING_IDENTITY", "").strip()
    if override:
        return override if override != "-" else None
    if app is None or not app.is_dir():
        return None
    try:
        done = subprocess.run(["codesign", "-dvv", str(app)], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in done.stderr.splitlines():
        if line.startswith("Authority="):
            return line.removeprefix("Authority=").strip() or None
    return None


def _identity_in_keychain(identity: str) -> bool:
    try:
        done = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                              capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return f'"{identity}"' in done.stdout


def app_build_commit(app: Path | None) -> str | None:
    if app is None:
        return None
    try:
        with (app / "Contents" / "Info.plist").open("rb") as handle:
            value = plistlib.load(handle).get("UndertoneBuildCommit")
    except (OSError, plistlib.InvalidFileException):
        return None
    return value if isinstance(value, str) else None


def _classify(paths: list[str]) -> dict[str, bool]:
    return {
        "app_changed": any(p.startswith("app/") and not p.startswith("app/Tests/") for p in paths),
        "engine_changed": any(p.startswith("engine/") for p in paths),
        "deps_changed": any(p in DEPENDENCY_FILES for p in paths),
    }


# MARK: - Status file and lock

def _paths(state_dir: Path | None) -> dict[str, Path]:
    base = state_dir or settings.CONFIG_DIR
    return {"dir": base, "status": base / "update-status.json", "log": base / "update.log",
            "lock": base / "update.lock", "previous": base / "update-previous.json"}


def _read_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(value, indent=2))
    temp.replace(path)


def _alive(pid: Any) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def read_status(state_dir: Path | None = None) -> dict[str, Any]:
    """The last apply or undo. A run whose process is gone counts as failed."""
    paths = _paths(state_dir)
    status = _read_json(paths["status"]) or {"state": "idle"}
    starting = status.get("pid") is None and time.time() - float(status.get("started_at") or 0) < START_GRACE_SECONDS
    if status.get("state") == "running" and not starting and not _alive(status.get("pid")):
        status = {**status, "state": "failed",
                  "message": "The update stopped before it finished. The log has the details."}
    status["log_path"] = str(paths["log"])
    status["can_undo"] = _read_json(paths["previous"]) is not None
    return status


def is_running(state_dir: Path | None = None) -> bool:
    lock = _paths(state_dir)["lock"]
    if not lock.exists():
        return False
    with lock.open("a") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        fcntl.flock(handle, fcntl.LOCK_UN)
    return False


class _Run:
    """Holds the lock and writes each step to the status file and the log."""

    def __init__(self, action: str, state_dir: Path | None, out: Any):
        self.paths = _paths(state_dir)
        self.action = action
        self.out = out
        self.status: dict[str, Any] = {}
        self._lock_handle: Any = None

    def __enter__(self) -> "_Run":
        self.paths["dir"].mkdir(parents=True, exist_ok=True)
        self._lock_handle = self.paths["lock"].open("a")
        try:
            fcntl.flock(self._lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self._lock_handle.close()
            raise StepFailed("An update is already running.")
        self.status = {"state": "running", "action": self.action, "step": "starting",
                       "pid": os.getpid(), "started_at": int(time.time())}
        self._save()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        try:
            if exc is not None and self.status.get("state") == "running":
                reason = str(exc) if isinstance(exc, StepFailed) else "The update stopped on an unexpected error."
                self.finish("failed", f"{reason} The log has the details.")
        finally:
            fcntl.flock(self._lock_handle, fcntl.LOCK_UN)
            self._lock_handle.close()

    def _save(self) -> None:
        _write_json(self.paths["status"], self.status)

    def step(self, name: str, message: str) -> None:
        self.status.update(step=name, message=message)
        self._save()
        self.log(message)

    def log(self, message: str) -> None:
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        print(f"[{stamp}] {self.action}: {message}", file=self.out, flush=True)

    def finish(self, state: str, message: str, **fields: Any) -> dict[str, Any]:
        self.status.update(state=state, message=message, finished_at=int(time.time()), **fields)
        self.status.pop("step", None)
        self._save()
        self.log(message)
        return self.status


# MARK: - Check

def check(repo: Path = REPO_ROOT, app: Path | None = None, *, fetch: bool = True) -> dict[str, Any]:
    """Compare the checkout with GitHub's main. Changes nothing but the fetch."""
    app = app or default_app_path()
    info: dict[str, Any] = {"state": "current", "checked_at": int(time.time()), "changes": [],
                            "app_commit": app_build_commit(app), "app_path": str(app) if app else None}
    try:
        top = Path(_git(repo, "rev-parse", "--show-toplevel"))
    except StepFailed:
        return {**info, "state": "blocked",
                "message": "This copy of Undertone is not a git checkout, so it cannot update itself."}
    info["repo"] = str(top)
    info["head"] = _git(top, "rev-parse", "HEAD")
    info["branch"] = _git(top, "rev-parse", "--abbrev-ref", "HEAD")
    if fetch:
        try:
            _git(top, "fetch", "--quiet", REMOTE, BRANCH, timeout=FETCH_TIMEOUT_SECONDS)
        except StepFailed:
            return {**info, "state": "error", "message": "Could not reach GitHub. Check the network and try again."}
    try:
        info["remote"] = _git(top, "rev-parse", f"{REMOTE}/{BRANCH}")
    except StepFailed:
        return {**info, "state": "error", "message": f"This checkout has no {REMOTE}/{BRANCH} to compare with."}
    ahead, behind = (int(n) for n in _git(top, "rev-list", "--left-right", "--count",
                                          f"HEAD...{REMOTE}/{BRANCH}").split())
    info.update(ahead=ahead, behind=behind)
    if behind:
        log = _git(top, "log", f"--max-count={MAX_CHANGES}", "--format=%h%x09%ct%x09%s", f"HEAD..{REMOTE}/{BRANCH}")
        for line in log.splitlines():
            commit, when, title = line.split("\t", 2)
            info["changes"].append({"commit": commit, "time": int(when), "title": title})
        paths = _git(top, "diff", "--name-only", f"HEAD...{REMOTE}/{BRANCH}").splitlines()
        info.update(_classify(paths))
    else:
        info.update(app_changed=False, engine_changed=False, deps_changed=False)

    blocked = _blocker(top, info, app)
    if blocked:
        return {**info, "state": "blocked", "message": blocked}
    if not behind:
        return {**info, "message": "Undertone is up to date."}
    count = f"{behind} new change" + ("" if behind == 1 else "s")
    return {**info, "state": "ready", "message": f"{count} ready to install."}


def _blocker(repo: Path, info: dict[str, Any], app: Path | None) -> str | None:
    """Why an update must not run, as a sentence, or None."""
    if info["branch"] != BRANCH:
        return f"The checkout is on branch {info['branch']}. Switch it to {BRANCH} to update."
    if _git(repo, "status", "--porcelain", "--untracked-files=no"):
        return "The checkout has uncommitted changes. Commit or discard them, then update."
    if not info["behind"]:
        return None
    if info["ahead"]:
        return f"The checkout has commits that are not on GitHub's {BRANCH}. Push or remove them, then update."
    if info["deps_changed"] and not _which("uv"):
        return "This update changes Python packages, and uv was not found to install them."
    if info["app_changed"]:
        if app is None:
            return "This update changes the app, and no installed Undertone.app was found to replace."
        identity = signing_identity(app)
        if identity is None:
            return "The installed app has no developer signature to reuse. A rebuilt app would lose its permissions."
        if not _identity_in_keychain(identity):
            return f"The signing identity {identity} is not in this Mac's keychain."
        if not _xcode_ready():
            return "This update changes the app, and building it needs Xcode. Install Xcode, then update."
    return None


# MARK: - Apply and undo

def apply(repo: Path = REPO_ROOT, app: Path | None = None, *, state_dir: Path | None = None,
          out: Any = None, dry_run: bool = False) -> dict[str, Any]:
    """Fast-forward to GitHub's main, install, build, swap, and restart."""
    out = out or sys.stdout
    app = app or default_app_path()
    with _Run("update", state_dir, out) as run:
        run.step("checking", "Checking GitHub for changes.")
        info = check(repo, app)
        if info["state"] != "ready":
            return run.finish("done" if info["state"] == "current" else "failed", info["message"])
        top, old, new = Path(info["repo"]), info["head"], info["remote"]
        run.status.update(old=old, new=new)
        if dry_run:
            plan = [k for k in ("deps_changed", "app_changed", "engine_changed") if info[k]]
            return run.finish("done", f"Dry run: would move {old[:7]} to {new[:7]} ({', '.join(plan) or 'no code'}).")

        run.step("pulling", f"Moving the checkout from {old[:7]} to {new[:7]}.")
        _git(top, "merge", "--ff-only", "--quiet", new)
        previous_app: Path | None = None
        try:
            if info["deps_changed"]:
                run.step("installing", "Installing Python packages.")
                _install_packages(top, out)
            if info["app_changed"] and app is not None:
                run.step("building", "Building the app. This takes a few minutes.")
                staged = _build_app(top, signing_identity(app) or "", new, out)
                run.step("swapping", "Replacing the app. The old one is kept for undo.")
                previous_app = _swap_in(staged, app)
        except Exception as exc:
            try:
                _git(top, "reset", "--keep", old)
                where = f"the checkout is back on {old[:7]}"
            except StepFailed:
                where = f"move the checkout back with `git reset --keep {old[:7]}`"
            reason = str(exc) if isinstance(exc, StepFailed) else "The update stopped on an unexpected error."
            return run.finish("failed", f"{reason} The installed app was not changed, and {where}.")

        _write_json(run.paths["previous"], {"commit": old, "app": str(previous_app) if previous_app else None,
                                            "installed_app": str(app) if app else None,
                                            "deps_changed": info["deps_changed"], "updated_at": int(time.time())})
        restart = info["engine_changed"] or info["deps_changed"]
        result = run.finish("done", f"Updated to {new[:7]}.", relaunch=previous_app is not None,
                            restart_engine=restart, app_path=str(app) if app else None)
        if restart:
            _restart_after(run)
        return result


def undo(repo: Path = REPO_ROOT, *, state_dir: Path | None = None, out: Any = None) -> dict[str, Any]:
    """Go back to the version before the last update, once."""
    out = out or sys.stdout
    with _Run("undo", state_dir, out) as run:
        previous = _read_json(run.paths["previous"])
        if previous is None or not isinstance(previous.get("commit"), str):
            return run.finish("failed", "There is no earlier version to go back to.")
        top = Path(_git(repo, "rev-parse", "--show-toplevel"))
        if _git(top, "rev-parse", "--abbrev-ref", "HEAD") != BRANCH:
            return run.finish("failed", f"The checkout is not on {BRANCH}, so undo would move the wrong branch.")
        if _git(top, "status", "--porcelain", "--untracked-files=no"):
            return run.finish("failed", "The checkout has uncommitted changes. Commit or discard them, then undo.")
        old, current = previous["commit"], _git(top, "rev-parse", "HEAD")
        run.status.update(old=current, new=old)
        run.step("pulling", f"Moving the checkout back from {current[:7]} to {old[:7]}.")
        _git(top, "reset", "--keep", old)
        if previous.get("deps_changed"):
            run.step("installing", "Reinstalling the earlier Python packages.")
            try:
                _install_packages(top, out)
            except StepFailed as exc:
                run.log(f"{exc} Run `uv pip install -e .` in the checkout if the engine does not start.")
        swapped = False
        prior, installed = previous.get("app"), previous.get("installed_app")
        if isinstance(prior, str) and isinstance(installed, str) and Path(prior).is_dir():
            run.step("swapping", "Putting the earlier app back.")
            _swap_back(Path(prior), Path(installed))
            swapped = True
        run.paths["previous"].unlink(missing_ok=True)
        result = run.finish("done", f"Back on {old[:7]}.", relaunch=swapped, restart_engine=True,
                            app_path=installed if swapped else None)
        _restart_after(run)
        return result


def _run_logged(cmd: list[str], cwd: Path, out: Any, timeout: int, env: dict[str, str] | None = None) -> str:
    try:
        done = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout,
                              env={**os.environ, **(env or {})})
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise StepFailed(f"{Path(cmd[0]).name} did not finish.") from exc
    for stream in (done.stdout, done.stderr):
        if stream.strip():
            print(stream.rstrip(), file=out, flush=True)
    if done.returncode != 0:
        raise StepFailed(f"{Path(cmd[0]).name} failed (exit {done.returncode}). The log has the details.")
    return done.stdout


def _install_packages(repo: Path, out: Any) -> None:
    uv = _which("uv")
    if uv is None:
        raise StepFailed("uv was not found to install Python packages.")
    _run_logged([uv, "pip", "install", "--python", sys.executable, "-e", str(repo)], repo, out,
                INSTALL_TIMEOUT_SECONDS)


def _build_app(repo: Path, identity: str, commit: str, out: Any) -> Path:
    """Build and sign the app; return the bundle only if it verifies."""
    if not identity:
        raise StepFailed("No signing identity to build the app with.")
    script = repo / "app" / "scripts" / "build_app.sh"
    printed = _run_logged(["/bin/zsh", str(script), "--production"], repo, out, BUILD_TIMEOUT_SECONDS,
                          env={"UNDERTONE_SIGNING_IDENTITY": identity})
    lines = [line for line in printed.splitlines() if line.strip()]
    bundle = Path(lines[-1].strip()) if lines else None
    if bundle is None or not (bundle / "Contents" / "MacOS" / "Undertone").is_file():
        raise StepFailed("The build did not produce an app.")
    _run_logged(["codesign", "--verify", "--strict", str(bundle)], repo, out, 120)
    if app_build_commit(bundle) != commit:
        raise StepFailed("The built app is stamped with a different commit.")
    return bundle


def _copy_bundle(source: Path, target: Path) -> None:
    """ditto keeps the signature, extended attributes, and symlinks intact."""
    if target.exists():
        shutil.rmtree(target)
    subprocess.run(["ditto", str(source), str(target)], check=True, capture_output=True, timeout=300)


def _swap_in(staged: Path, installed: Path) -> Path:
    """Put the new app in place and keep the old one beside it."""
    folder = installed.parent
    incoming, previous = folder / ".Undertone (incoming).app", folder / PREVIOUS_APP_NAME
    try:
        _copy_bundle(staged, incoming)
    except (OSError, subprocess.SubprocessError) as exc:
        raise StepFailed("Could not copy the new app into place.") from exc
    if previous.exists():
        shutil.rmtree(previous)
    installed.rename(previous)
    try:
        incoming.rename(installed)
    except OSError:
        previous.rename(installed)
        raise
    return previous


def _swap_back(previous: Path, installed: Path) -> None:
    """Put the kept app back; the newer one is removed."""
    newer = installed.parent / ".Undertone (undone).app"
    if newer.exists():
        shutil.rmtree(newer)
    if installed.exists():
        installed.rename(newer)
    previous.rename(installed)
    shutil.rmtree(newer, ignore_errors=True)


def _restart_after(run: _Run) -> None:
    """The status already says done. Restart last, and say so if it fails."""
    if restart_engine():
        run.log("Engine restarted.")
        return
    run.status["message"] += " Restart the engine to use the new version."
    run._save()
    run.log("The engine is not run by launchd, so it was not restarted.")


def restart_engine() -> bool:
    """Restart the launchd agent. False when the engine is not run by launchd."""
    target = f"gui/{os.getuid()}/{ENGINE_LABEL}"
    try:
        return subprocess.run(["launchctl", "kickstart", "-k", target], capture_output=True,
                              timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


# MARK: - Starting a run from the engine

def start_detached(action: str, app: Path | None = None, *, repo: Path = REPO_ROOT,
                   state_dir: Path | None = None) -> dict[str, Any]:
    """Start `undertone update --apply` (or `--undo`) in its own session, so the
    engine restart at the end does not stop it. Returns at once."""
    paths = _paths(state_dir)
    if is_running(state_dir):
        raise StepFailed("An update is already running.")
    paths["dir"].mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "-m", "undertone.cli", "update", "--undo" if action == "undo" else "--apply", "--detached"]
    if app is not None and action != "undo":
        cmd += ["--app", str(app)]
    if repo != REPO_ROOT:
        cmd += ["--repo", str(repo)]
    if state_dir is not None:
        cmd += ["--state-dir", str(state_dir)]
    # Import the updater from the code that is running now, the engine's own.
    engine_dir = str(Path(__file__).resolve().parents[1])
    env = {**os.environ, "PYTHONPATH": os.pathsep.join(filter(None, [engine_dir, os.environ.get("PYTHONPATH")]))}
    started = {"state": "running", "action": action, "step": "starting", "pid": None,
               "started_at": int(time.time()), "message": "Starting."}
    _write_json(paths["status"], started)
    with paths["log"].open("a") as log:
        process = subprocess.Popen(cmd, cwd=repo, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                   env=env, start_new_session=True)
    # Reap the process when it ends, so it never lingers as a zombie of the engine.
    threading.Thread(target=process.wait, daemon=True).start()
    # Record the pid unless the run has already written its own status, so a
    # process that dies at once reads as failed instead of starting.
    if _read_json(paths["status"]) == started:
        _write_json(paths["status"], {**started, "pid": process.pid})
    return read_status(state_dir)


class Tee:
    """Writes to the terminal and the update log at once, for Terminal runs."""

    def __init__(self, *streams: Any):
        self.streams = streams

    def write(self, text: str) -> None:
        for stream in self.streams:
            stream.write(text)

    def flush(self) -> None:
        for stream in self.streams:
            stream.flush()


def log_path(state_dir: Path | None = None) -> Path:
    return _paths(state_dir)["log"]
