"""Update Undertone from its own git checkout: check, apply, and undo.

The engine runs from the checkout it updates. A check runs one `git fetch` of
`main` from GitHub; it sends no audio, transcripts, or settings. An apply runs
in its own process and changes files only: it never restarts the engine or
quits the app, so it cannot cut off a dictation or a meeting. The app does
that afterwards, when nothing is in progress. A failed step puts the
checkout, the Python packages, and the app back the way they were.
"""
from __future__ import annotations

import fcntl
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from . import config as settings

REPO_ROOT = Path(__file__).resolve().parents[2]
REMOTE = "origin"
BRANCH = "main"
REFSPEC = f"+refs/heads/{BRANCH}:refs/remotes/{REMOTE}/{BRANCH}"
APP_NAME = "Undertone.app"
PREVIOUS_APP_NAME = "Undertone (previous).app"
DEPENDENCY_FILES = {"pyproject.toml"}
MAX_CHANGES = 20
FETCH_TIMEOUT_SECONDS = 60
BUILD_TIMEOUT_SECONDS = 45 * 60
INSTALL_TIMEOUT_SECONDS = 15 * 60
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


def head_commit(repo: Path = REPO_ROOT) -> str | None:
    try:
        return _git(repo, "rev-parse", "HEAD")
    except StepFailed:
        return None


def _which(name: str) -> str | None:
    extra = os.pathsep.join(str(Path(d).expanduser()) for d in TOOL_DIRS)
    return shutil.which(name, path=os.environ.get("PATH", "") + os.pathsep + extra)


def _xcode_ready() -> bool:
    """SwiftUI needs full Xcode; Command Line Tools alone cannot build the app."""
    try:
        return subprocess.run(["xcodebuild", "-version"], capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _codesign_details(app: Path, *flags: str) -> str:
    try:
        done = subprocess.run(["codesign", "-d", *flags, str(app)], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return done.stdout + done.stderr


def signing_identity(app: Path | None) -> str | None:
    """The identity that signed the installed app. Signing the new build with the
    same one keeps Microphone, Accessibility, and Input Monitoring granted."""
    override = os.environ.get("UNDERTONE_SIGNING_IDENTITY", "").strip()
    if override:
        return override if override != "-" else None
    if app is None or not app.is_dir():
        return None
    for line in _codesign_details(app, "-vv").splitlines():
        if line.startswith("Authority="):
            return line.removeprefix("Authority=").strip() or None
    return None


def designated_requirement(app: Path | None) -> str | None:
    """The rule macOS privacy settings match an app by. The new build must
    satisfy the installed app's rule, or its permissions would reset."""
    if app is None or not app.is_dir():
        return None
    for line in _codesign_details(app, "-r-").splitlines():
        if line.startswith("designated => "):
            return line.removeprefix("designated => ").strip() or None
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


def _changed_paths(repo: Path, old: str, new: str, *filters: str) -> list[str]:
    """Paths that differ. Rename detection is off, so a move lists both ends."""
    out = _git(repo, "diff", "--name-only", "--no-renames", "-z", *filters, old, new)
    return [path for path in out.split("\0") if path]


def _classify(paths: list[str]) -> dict[str, bool]:
    return {
        "app_changed": any(p.startswith("app/") and not p.startswith("app/Tests/") for p in paths),
        "engine_changed": any(p.startswith("engine/") for p in paths),
        "deps_changed": any(p in DEPENDENCY_FILES for p in paths),
    }


def _collisions(repo: Path, old: str, new: str) -> list[str]:
    """Files that moving from `old` to `new` would add, but that already exist
    on disk untracked or ignored. Git would refuse some and silently overwrite
    the ignored ones, so any of them stops the update."""
    hits: list[str] = []
    for path in _changed_paths(repo, old, new, "--diff-filter=A"):
        parts = Path(path).parts
        for depth in range(1, len(parts) + 1):
            here = repo.joinpath(*parts[:depth])
            leaf = depth == len(parts)
            if here.is_symlink() or (here.exists() and (leaf or not here.is_dir())):
                hits.append("/".join(parts[:depth]))
                break
    return sorted(set(hits))


def _expect_head(repo: Path, commit: str) -> None:
    """Every git change first confirms the checkout is still main at `commit`,
    so a branch switch or a new commit is never moved by the updater."""
    try:
        branch = _git(repo, "symbolic-ref", "--quiet", "HEAD")
    except StepFailed:
        branch = "detached"
    if branch != f"refs/heads/{BRANCH}" or _git(repo, "rev-parse", "HEAD") != commit:
        raise StepFailed("The checkout changed while the update ran, so the updater left it alone.")


def _origin_on_github(repo: Path) -> bool:
    """The check promises a fetch from GitHub, so `origin` must point there."""
    try:
        url = _git(repo, "config", "--get", f"remote.{REMOTE}.url")
    except StepFailed:
        return False
    return url.startswith(("https://github.com/", "git@github.com:", "ssh://git@github.com/"))


def engine_stale(started: str | None, repo: Path = REPO_ROOT) -> bool:
    """True when the checkout has engine or package changes the running engine,
    which started from `started`, has not loaded. Worked out from the checkout
    itself, so it holds whichever run, or person, moved it."""
    head = head_commit(repo)
    if not started or not head or head == started:
        return False
    try:
        changed = _classify(_changed_paths(repo, started, head))
    except StepFailed:
        return True
    return changed["engine_changed"] or changed["deps_changed"]


def _clean(repo: Path) -> bool:
    return not _git(repo, "status", "--porcelain", "--untracked-files=no")


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
    temp = path.with_name(f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp")
    temp.write_text(json.dumps(value, indent=2))
    temp.replace(path)


def is_running(state_dir: Path | None = None) -> bool:
    """A run holds the lock for its whole life, so the lock is the truth."""
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


def read_status(state_dir: Path | None = None) -> dict[str, Any]:
    """The last apply or undo. A run that no longer holds the lock but never
    finished counts as failed."""
    paths = _paths(state_dir)
    status = _read_json(paths["status"]) or {"state": "idle"}
    if status.get("state") == "running" and not is_running(state_dir):
        status = {**status, "state": "failed",
                  "message": "The update stopped before it finished. The log has the details."}
    status["log_path"] = str(paths["log"])
    status["can_undo"] = _read_json(paths["previous"]) is not None
    return status


class _Run:
    """Holds the lock and is the only writer of the status file for one run.

    The engine takes the lock before it starts the run's process and hands it
    over as an open descriptor (`lock_fd`), so no second run can slip in."""

    def __init__(self, action: str, state_dir: Path | None, out: Any, *,
                 lock_fd: int | None = None, run_id: str | None = None):
        self.paths = _paths(state_dir)
        self.action = action
        self.out = out
        self.run_id = run_id or uuid.uuid4().hex
        self.status: dict[str, Any] = {}
        self._fd = lock_fd

    def __enter__(self) -> "_Run":
        self.paths["dir"].mkdir(parents=True, exist_ok=True)
        if self._fd is None:
            self._fd = os.open(self.paths["lock"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            fcntl.flock(self._fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self._fd)
            raise StepFailed("An update is already running.")
        self.status = {"state": "running", "action": self.action, "step": "starting", "run_id": self.run_id,
                       "pid": os.getpid(), "started_at": int(time.time())}
        self._save()
        return self

    def __exit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        try:
            if exc is not None and self.status.get("state") == "running":
                reason = str(exc) if isinstance(exc, StepFailed) else "The update stopped on an unexpected error."
                self.finish("failed", f"{reason} The log has the details.")
        finally:
            os.close(self._fd)

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
                            "app_commit": app_build_commit(app), "app_path": str(app) if app else None,
                            "app_changed": False, "engine_changed": False, "deps_changed": False}
    try:
        top = Path(_git(repo, "rev-parse", "--show-toplevel"))
    except StepFailed:
        return {**info, "state": "blocked",
                "message": "This copy of Undertone is not a git checkout, so it cannot update itself."}
    info["repo"] = str(top)
    info["head"] = _git(top, "rev-parse", "HEAD")
    info["branch"] = _git(top, "rev-parse", "--abbrev-ref", "HEAD")
    if not _origin_on_github(top):
        return {**info, "state": "blocked", "message": f"This checkout's {REMOTE} is not on GitHub, so it is not updated from here."}
    if fetch:
        try:
            _git(top, "fetch", "--quiet", "--no-tags", REMOTE, REFSPEC, timeout=FETCH_TIMEOUT_SECONDS)
        except StepFailed:
            return {**info, "state": "error", "message": "Could not reach GitHub. Check the network and try again."}
    try:
        info["remote"] = _git(top, "rev-parse", f"refs/remotes/{REMOTE}/{BRANCH}")
    except StepFailed:
        return {**info, "state": "error", "message": f"This checkout has no {REMOTE}/{BRANCH} to compare with."}
    ahead, behind = (int(n) for n in _git(top, "rev-list", "--left-right", "--count",
                                          f"HEAD...{info['remote']}").split())
    info.update(ahead=ahead, behind=behind)
    if behind:
        log = _git(top, "log", f"--max-count={MAX_CHANGES}", "--format=%h%x09%ct%x09%s", f"HEAD..{info['remote']}")
        for line in log.splitlines():
            commit, when, title = line.split("\t", 2)
            info["changes"].append({"commit": commit, "time": int(when), "title": title})
        info.update(_classify(_changed_paths(top, info["head"], info["remote"])))

    blocked = _blocker(top, info, app)
    if blocked:
        return {**info, "state": "blocked", "message": blocked}
    if not behind:
        return {**info, "message": "Undertone is up to date."}
    count = f"{behind} new change" + ("" if behind == 1 else "s")
    extra = " It downloads Python packages." if info["deps_changed"] else ""
    return {**info, "state": "ready", "message": f"{count} ready to install.{extra}"}


def _blocker(repo: Path, info: dict[str, Any], app: Path | None) -> str | None:
    """Why an update must not run, as a sentence, or None."""
    if info["branch"] != BRANCH:
        return f"The checkout is on branch {info['branch']}. Switch it to {BRANCH} to update."
    if not _clean(repo):
        return "The checkout has uncommitted changes. Commit or discard them, then update."
    if info["ahead"]:
        return f"The checkout has commits that are not on GitHub's {BRANCH}. Push or remove them, then update."
    if not info["behind"]:
        return None
    collisions = _collisions(repo, info["head"], info["remote"])
    if collisions:
        shown = ", ".join(collisions[:3]) + (" and others" if len(collisions) > 3 else "")
        return f"The update adds files that already exist here ({shown}). Move them, then update."
    if info["deps_changed"] and not _which("uv"):
        return "This update changes Python packages, and uv was not found to install them."
    if info["app_changed"]:
        if app is None:
            return "This update changes the app, and no installed Undertone.app was found to replace."
        identity = signing_identity(app)
        if identity is None or designated_requirement(app) is None:
            return "The installed app has no developer signature to reuse. A rebuilt app would lose its permissions."
        if not _identity_in_keychain(identity):
            return f"The signing identity {identity} is not in this Mac's keychain."
        if not _xcode_ready():
            return "This update changes the app, and building it needs Xcode. Install Xcode, then update."
    return None


# MARK: - Apply and undo

def apply(repo: Path = REPO_ROOT, app: Path | None = None, *, state_dir: Path | None = None,
          out: Any = None, expect: str | None = None, lock_fd: int | None = None,
          run_id: str | None = None) -> dict[str, Any]:
    """Fast-forward to the checked commit of GitHub's main, build, install, and
    swap the app. The engine restart and app reopen are left to the app."""
    out = out or sys.stdout
    app = app or default_app_path()
    with _Run("update", state_dir, out, lock_fd=lock_fd, run_id=run_id) as run:
        run.step("checking", "Checking GitHub for changes.")
        info = check(repo, app)
        if info["state"] != "ready":
            return run.finish("done" if info["state"] == "current" else "failed", info["message"])
        if expect and info["remote"] != expect:
            return run.finish("failed", "GitHub's main changed since the last check. Check again, then update.")
        top, old, new = Path(info["repo"]), info["head"], info["remote"]
        run.status.update(old=old, new=new)

        run.step("pulling", f"Moving the checkout from {old[:7]} to {new[:7]}.")
        _expect_head(top, old)
        _git(top, "merge", "--ff-only", "--no-overwrite-ignore", "--quiet", new)
        staged: Path | None = None
        packages: Path | None = None
        swapped = False
        try:
            if info["app_changed"] and app is not None:
                run.step("building", "Building the app. This takes a few minutes.")
                staged = _build_app(top, app, new, out)
            if info["deps_changed"]:
                run.step("installing", "Installing Python packages.")
                packages = _freeze_packages(run.paths["dir"], old, out)
                _install_packages(top, out)
            if info["engine_changed"] or info["deps_changed"]:
                run.step("testing", "Checking that the new engine loads.")
                _engine_imports(top, out)
            record = {"repo": str(top), "commit": old, "installed_commit": new,
                      "deps_changed": info["deps_changed"], "packages": str(packages) if packages else None,
                      "app": None, "installed_app": None,
                      "app_commit": app_build_commit(app), "updated_at": int(time.time())}
            if staged is not None and app is not None:
                run.step("swapping", "Replacing the app. The old one is kept for Go back.")
                record.update(app=str(app.parent / PREVIOUS_APP_NAME), installed_app=str(app),
                              app_commit=app_build_commit(staged))
                _commit_with_swap(staged, app, run.paths["previous"], record)
                swapped = True
            else:
                _write_json(run.paths["previous"], record)
        except Exception as exc:
            reason = str(exc) if isinstance(exc, StepFailed) else "The update stopped on an unexpected error."
            problem = _roll_back(top, old, new, packages, out)
            return run.finish("failed", f"{reason} " + (problem or f"Nothing changed: the checkout is back on "
                                                        f"{old[:7]} and the installed app was not touched."))
        restart = info["engine_changed"] or info["deps_changed"]
        return run.finish("done", f"Updated to {new[:7]}.", relaunch=swapped, restart_engine=restart,
                          app_path=str(app) if swapped else None, app_commit=record["app_commit"])


def _roll_back(repo: Path, old: str, new: str, packages: Path | None, out: Any) -> str | None:
    """Move the checkout from `new` back to `old` and restore the exact package
    set saved in `packages`, if any. Returns None when that worked, else what
    is left to do."""
    try:
        _expect_head(repo, new)
        if _collisions(repo, new, old):
            raise StepFailed("files appeared where the old version has its own")
        _git(repo, "reset", "--keep", old)
    except StepFailed:
        return f"The checkout changed meanwhile, so the updater left it alone. It was on {old[:7]} before."
    if packages is not None:
        try:
            _restore_packages(packages, repo, out)
        except StepFailed:
            return (f"The checkout is back on {old[:7]}, but restoring its Python packages failed. "
                    f"Run `uv pip sync {packages}` with the engine's Python.")
    return None


def undo(repo: Path = REPO_ROOT, *, state_dir: Path | None = None, out: Any = None,
         lock_fd: int | None = None, run_id: str | None = None) -> dict[str, Any]:
    """Go back to the version before the last update, once, and only if the
    checkout is still exactly where that update left it."""
    out = out or sys.stdout
    with _Run("undo", state_dir, out, lock_fd=lock_fd, run_id=run_id) as run:
        record = _read_json(run.paths["previous"]) or {}
        top = Path(_git(repo, "rev-parse", "--show-toplevel"))
        old, current = record.get("commit"), record.get("installed_commit")
        if record.get("repo") != str(top) or not isinstance(old, str) or not isinstance(current, str):
            return run.finish("failed", "There is no earlier version of this checkout to go back to.")
        try:
            _expect_head(top, current)
        except StepFailed:
            return run.finish("failed", f"The checkout is no longer on {current[:7]} on {BRANCH}, so Go back "
                                        "could remove newer work. Nothing changed.")
        if not _clean(top):
            return run.finish("failed", "The checkout has uncommitted changes. Commit or discard them, then go back.")
        collisions = _collisions(top, current, old)
        if collisions:
            return run.finish("failed", f"Going back adds files that already exist here ({', '.join(collisions[:3])}). "
                                        "Move them, then go back.")
        prior, installed = record.get("app"), record.get("installed_app")
        if isinstance(prior, str) and not Path(prior).is_dir():
            return run.finish("failed", "The earlier app is missing, so Go back cannot restore it. Nothing changed.")
        snapshot = record.get("packages")
        if record.get("deps_changed") and not (isinstance(snapshot, str) and Path(snapshot).is_file()):
            return run.finish("failed", "The earlier package list is missing, so Go back cannot restore it. Nothing changed.")
        run.status.update(old=current, new=old)
        run.step("pulling", f"Moving the checkout back from {current[:7]} to {old[:7]}.")
        current_packages = _freeze_packages(run.paths["dir"], current, out) if record.get("deps_changed") else None
        _expect_head(top, current)
        _git(top, "reset", "--keep", old)
        try:
            if record.get("deps_changed"):
                run.step("installing", "Restoring the earlier Python packages.")
                _restore_packages(Path(snapshot), top, out)
            app_commit = record.get("app_commit")
            if isinstance(prior, str) and isinstance(installed, str):
                run.step("swapping", "Putting the earlier app back.")
                app_commit = app_build_commit(Path(prior))
                _swap_back(Path(prior), Path(installed))
        except Exception as exc:
            reason = str(exc) if isinstance(exc, StepFailed) else "Go back stopped on an unexpected error."
            problem = _roll_back(top, current, old, current_packages, out)
            return run.finish("failed", f"{reason} " + (problem or f"Nothing changed: the checkout stays on {current[:7]}."))
        try:
            run.paths["previous"].unlink(missing_ok=True)
        except OSError:
            # Go back is done. A stale record cannot repeat it: the checkout is
            # no longer on the commit the record names, so a second Go back refuses.
            run.log("Could not remove the Go back record.")
        swapped = isinstance(prior, str)
        return run.finish("done", f"Back on {old[:7]}.", relaunch=swapped, restart_engine=True,
                          app_path=installed if swapped else None, app_commit=app_commit)


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


def _freeze_packages(folder: Path, commit: str, out: Any) -> Path:
    """Save the engine's exact installed packages, so a rollback restores them."""
    uv = _which("uv")
    if uv is None:
        raise StepFailed("uv was not found to install Python packages.")
    frozen = _run_logged([uv, "pip", "freeze", "--python", sys.executable], folder, io.StringIO(), 120)
    path = folder / f"update-packages-{commit[:12]}.txt"
    path.write_text(frozen)
    return path


def _restore_packages(snapshot: Path, repo: Path, out: Any) -> None:
    uv = _which("uv")
    if uv is None:
        raise StepFailed("uv was not found to restore Python packages.")
    _run_logged([uv, "pip", "sync", "--python", sys.executable, str(snapshot)], repo, out, INSTALL_TIMEOUT_SECONDS)


def _engine_imports(repo: Path, out: Any) -> None:
    """The new engine must at least load, or the restart would leave no engine."""
    env = {"PYTHONPATH": str(repo / "engine"), "HF_HUB_OFFLINE": "1"}
    try:
        _run_logged([sys.executable, "-c", "import undertone.server, undertone.cli"], repo, out, 300, env=env)
    except StepFailed as exc:
        raise StepFailed("The new engine does not load.") from exc


def _build_app(repo: Path, app: Path, commit: str, out: Any) -> Path:
    """Build and sign the app; return the bundle only if macOS would treat it as
    the same app as the installed one, so its permissions carry over."""
    identity, requirement = signing_identity(app), designated_requirement(app)
    if not identity or not requirement:
        raise StepFailed("The installed app has no developer signature to reuse.")
    script = repo / "app" / "scripts" / "build_app.sh"
    printed = _run_logged(["/bin/zsh", str(script), "--production"], repo, out, BUILD_TIMEOUT_SECONDS,
                          env={"UNDERTONE_SIGNING_IDENTITY": identity})
    lines = [line for line in printed.splitlines() if line.strip()]
    bundle = Path(lines[-1].strip()) if lines else None
    if bundle is None or not (bundle / "Contents" / "MacOS" / "Undertone").is_file():
        raise StepFailed("The build did not produce an app.")
    try:
        _run_logged(["codesign", "--verify", "--strict", f"-R={requirement}", str(bundle)], repo, out, 120)
    except StepFailed as exc:
        raise StepFailed("The new app is not signed like the installed one, so it would lose its permissions.") from exc
    if app_build_commit(bundle) != commit:
        raise StepFailed("The built app is stamped with a different commit.")
    return bundle


def _copy_bundle(source: Path, target: Path) -> None:
    """ditto keeps the signature, extended attributes, and symlinks intact."""
    if target.exists():
        shutil.rmtree(target)
    subprocess.run(["ditto", str(source), str(target)], check=True, capture_output=True, timeout=300)


def _commit_with_swap(staged: Path, installed: Path, record_path: Path, record: dict[str, Any]) -> None:
    """Put the new app in place, keep the old one as the previous app, and
    write the Go back record. Either all of it happens or none of it does:
    every bundle is only renamed until the end."""
    folder = installed.parent
    incoming = folder / ".Undertone (incoming).app"
    previous = folder / PREVIOUS_APP_NAME
    parked = folder / ".Undertone (previous, parked).app"
    old_record = _read_json(record_path)
    try:
        _copy_bundle(staged, incoming)
        if parked.exists():
            shutil.rmtree(parked)
    except (OSError, subprocess.SubprocessError) as exc:
        shutil.rmtree(incoming, ignore_errors=True)
        raise StepFailed("Could not copy the new app into place.") from exc
    moves: list[tuple[Path, Path]] = []
    try:
        for source, target in ((previous, parked), (installed, previous), (incoming, installed)):
            if source.exists():
                source.rename(target)
                moves.append((source, target))
        _write_json(record_path, record)
    except OSError as exc:
        for source, target in reversed(moves):
            target.rename(source)
        if old_record is not None:
            _write_json(record_path, old_record)
        shutil.rmtree(incoming, ignore_errors=True)
        raise StepFailed("Could not move the new app into place.") from exc
    shutil.rmtree(parked, ignore_errors=True)


def _swap_back(previous: Path, installed: Path) -> None:
    """Put the kept app back. The newer one is removed only once that worked."""
    newer = installed.parent / ".Undertone (undone).app"
    if newer.exists():
        shutil.rmtree(newer)
    installed.rename(newer)
    try:
        previous.rename(installed)
    except OSError as exc:
        newer.rename(installed)
        raise StepFailed("Could not put the earlier app back.") from exc
    shutil.rmtree(newer, ignore_errors=True)


# MARK: - Starting a run from the engine

def start_detached(action: str, app: Path | None = None, *, repo: Path = REPO_ROOT,
                   state_dir: Path | None = None, expect: str | None = None) -> dict[str, Any]:
    """Start `undertone update --apply` (or `--undo`) in its own session and
    return at once. The engine takes the lock first and passes it to the run,
    so two requests can never start two runs."""
    paths = _paths(state_dir)
    paths["dir"].mkdir(parents=True, exist_ok=True)
    fd = os.open(paths["lock"], os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise StepFailed("An update is already running.")
        run_id = uuid.uuid4().hex
        _write_json(paths["status"], {"state": "running", "action": action, "step": "starting", "run_id": run_id,
                                      "started_at": int(time.time()), "message": "Starting."})
        cmd = [sys.executable, "-m", "undertone.cli", "update", "--undo" if action == "undo" else "--apply",
               "--detached", "--lock-fd", str(fd), "--run-id", run_id]
        if app is not None and action != "undo":
            cmd += ["--app", str(app)]
        if expect and action != "undo":
            cmd += ["--expect", expect]
        if repo != REPO_ROOT:
            cmd += ["--repo", str(repo)]
        if state_dir is not None:
            cmd += ["--state-dir", str(state_dir)]
        # Import the updater from the code that is running now, the engine's own.
        engine_dir = str(Path(__file__).resolve().parents[1])
        env = {**os.environ, "PYTHONPATH": os.pathsep.join(filter(None, [engine_dir, os.environ.get("PYTHONPATH")]))}
        try:
            with paths["log"].open("a") as log:
                process = subprocess.Popen(cmd, cwd=repo, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                           env=env, start_new_session=True, pass_fds=(fd,))
        except OSError as exc:
            _write_json(paths["status"], {"state": "failed", "action": action, "run_id": run_id,
                                          "finished_at": int(time.time()), "message": "The update could not start."})
            raise StepFailed("The update could not start.") from exc
    finally:
        os.close(fd)  # the run keeps the lock through its own copy of the descriptor
    # Reap the process when it ends, so it never lingers as a zombie of the engine.
    threading.Thread(target=process.wait, daemon=True).start()
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
