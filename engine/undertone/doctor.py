from __future__ import annotations

import argparse
import dataclasses
import json
import os
import platform
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from . import config as settings

OLLAMA_TAGS_TIMEOUT_SECONDS = 3.0
INSTALL_OLLAMA_FIX = "Install Ollama from https://ollama.com and start it."


@dataclasses.dataclass
class Check:
    """One doctor check result.

    ``ok`` is true when the check passed outright. ``warn`` marks a check
    that did not pass but should not block ``undertone`` from running (for
    example an optional model, or a whisper model that has not downloaded
    yet). Anything with ``ok`` false and ``warn`` false is a required
    failure and drives the process exit code.
    """

    name: str
    ok: bool
    detail: str
    fix: str | None = None
    warn: bool = False

    @property
    def tag(self) -> str:
        if self.ok:
            return "ok"
        if self.warn:
            return "warn"
        return "fail"


def _check_python_and_mlx_whisper() -> Check:
    python_version = platform.python_version()
    try:
        import mlx_whisper  # noqa: F401
    except Exception as exc:
        return Check(
            "mlx-whisper",
            False,
            f"mlx-whisper is not importable under Python {python_version}: {exc}",
            "Install engine dependencies (uv sync, or pip install mlx-whisper).",
        )
    try:
        import importlib.metadata as metadata

        mlx_version = metadata.version("mlx-whisper")
    except Exception:
        mlx_version = "unknown"
    return Check(
        "mlx-whisper",
        True,
        f"mlx-whisper {mlx_version} importable (Python {python_version}).",
    )


def _ollama_tags_url(ollama_url: str) -> str:
    """Build the local /api/tags URL, rejecting anything not plain localhost HTTP."""
    parsed = urllib.parse.urlsplit(ollama_url)
    if parsed.scheme != "http" or parsed.hostname not in {"localhost", "127.0.0.1", "::1"}:
        raise ValueError("Ollama URL must be plain HTTP on localhost")
    host = "127.0.0.1" if parsed.hostname == "localhost" else parsed.hostname
    port = parsed.port
    if ":" in host:
        netloc = f"[{host}]" if port is None else f"[{host}]:{port}"
    else:
        netloc = host if port is None else f"{host}:{port}"
    return urllib.parse.urlunsplit((parsed.scheme, netloc, "/api/tags", "", ""))


def fetch_ollama_models(ollama_url: str, timeout: float = OLLAMA_TAGS_TIMEOUT_SECONDS) -> list[str]:
    """Return the model names Ollama currently has pulled."""
    url = _ollama_tags_url(ollama_url)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=timeout) as resp:
        data = json.load(resp)
    models = data.get("models") if isinstance(data, dict) else None
    names: list[str] = []
    for entry in models or []:
        if isinstance(entry, dict):
            name = entry.get("name") or entry.get("model")
            if isinstance(name, str):
                names.append(name)
    return names


def _check_ollama_reachable(ollama_url: str) -> tuple[Check, list[str] | None]:
    try:
        models = fetch_ollama_models(ollama_url)
    except Exception as exc:
        return (
            Check(
                "ollama",
                False,
                f"Could not reach Ollama at {ollama_url} ({type(exc).__name__}: {exc}).",
                INSTALL_OLLAMA_FIX,
            ),
            None,
        )
    return Check("ollama", True, f"Ollama responded at {ollama_url} with {len(models)} model(s) pulled."), models


def _model_present(name: str, available: list[str]) -> bool:
    if name in available:
        return True
    if ":" not in name and f"{name}:latest" in available:
        return True
    return False


def _check_model(label: str, model_name: Any, models: list[str] | None, *, required: bool) -> Check:
    if not model_name or not isinstance(model_name, str):
        return Check(label, not required, f"No {label} configured.", warn=not required)
    fix = f"ollama pull {model_name}"
    if models is None:
        return Check(
            label,
            False,
            f"Cannot check whether {model_name} is pulled because Ollama is unreachable.",
            fix,
            warn=not required,
        )
    if _model_present(model_name, models):
        return Check(label, True, f"{model_name} is pulled.")
    return Check(label, False, f"{model_name} is not pulled.", fix, warn=not required)


def _hf_cache_dir() -> Path:
    hub_cache = os.environ.get("HF_HUB_CACHE")
    if hub_cache:
        return Path(hub_cache).expanduser()
    home = os.environ.get("HF_HOME")
    if home:
        return Path(home).expanduser() / "hub"
    return Path.home() / ".cache" / "huggingface" / "hub"


def _hf_cache_folder(repo_id: str) -> Path:
    return _hf_cache_dir() / ("models--" + repo_id.replace("/", "--"))


def _download_whisper_model(stt_model: str) -> None:
    import mlx_whisper.load_models as load_models

    load_models.load_model(stt_model)


def _check_whisper_cache(stt_model: str, *, download: bool) -> Check:
    if Path(stt_model).expanduser().exists():
        return Check("whisper model", True, f"{stt_model} is a local path.")

    folder = _hf_cache_folder(stt_model)
    if folder.is_dir() and any(folder.iterdir()):
        return Check("whisper model", True, f"{stt_model} is cached at {folder}.")

    if download:
        try:
            _download_whisper_model(stt_model)
        except Exception as exc:
            return Check(
                "whisper model",
                False,
                f"Download of {stt_model} failed: {exc}",
                "Run 'undertone doctor --download' again once the network issue is resolved.",
                warn=True,
            )
        return Check("whisper model", True, f"Downloaded {stt_model} to {folder}.")

    return Check(
        "whisper model",
        False,
        f"{stt_model} is not cached at {folder}. It will download about 1.6 GB on first run.",
        "Run 'undertone doctor --download' to fetch it now.",
        warn=True,
    )


def _check_undertone_dir() -> Check:
    directory = settings.CONFIG_DIR
    socket_path = directory / "engine.sock"
    try:
        directory.mkdir(parents=True, exist_ok=True)
        probe = directory / ".doctor-write-check"
        probe.write_text("")
        probe.unlink()
    except OSError as exc:
        return Check(
            "~/.undertone writable",
            False,
            f"{directory} is not writable: {exc}",
            f"Fix permissions on {directory} (chmod u+w), or remove it and let undertone recreate it.",
        )
    if not socket_path.parent.is_dir():
        return Check(
            "~/.undertone writable",
            False,
            f"Socket directory {socket_path.parent} does not exist.",
            f"Create {socket_path.parent} before running 'undertone serve'.",
        )
    return Check(
        "~/.undertone writable",
        True,
        f"{directory} exists and is writable; socket path {socket_path} is reachable.",
    )


def _check_config_present() -> Check:
    if settings.CONFIG_PATH.exists():
        return Check("config file", True, f"{settings.CONFIG_PATH} exists.")
    return Check(
        "config file",
        False,
        f"{settings.CONFIG_PATH} does not exist yet. Defaults apply until 'undertone' writes one.",
        warn=True,
    )


def run_checks(config: dict[str, Any], *, download: bool = False) -> list[Check]:
    """Run every doctor check and return the results in report order."""
    checks: list[Check] = [_check_python_and_mlx_whisper()]

    ollama_url = config.get("ollama_url", settings.DEFAULTS["ollama_url"])
    ollama_check, models = _check_ollama_reachable(ollama_url)
    checks.append(ollama_check)

    checks.append(_check_model("cleanup_model", config.get("cleanup_model"), models, required=True))
    checks.append(_check_model("cleanup_high_model", config.get("cleanup_high_model"), models, required=False))

    stt_model = config.get("stt_model", settings.DEFAULTS["stt_model"])
    checks.append(_check_whisper_cache(stt_model, download=download))

    checks.append(_check_undertone_dir())
    checks.append(_check_config_present())

    return checks


def format_report(checks: list[Check]) -> str:
    lines = [f"{check.tag:<4} {check.name}: {check.detail}" for check in checks]
    fixes = [check.fix for check in checks if check.fix and not check.ok]
    if fixes:
        lines.append("")
        lines.append("Next steps:")
        lines.extend(f"  - {fix}" for fix in fixes)
    return "\n".join(lines)


def cmd_doctor(args: argparse.Namespace) -> None:
    config = settings.load_config()
    checks = run_checks(config, download=getattr(args, "download", False))
    if getattr(args, "json", False):
        print(json.dumps([dataclasses.asdict(check) for check in checks], indent=2))
    else:
        print(format_report(checks))
    if any(not check.ok and not check.warn for check in checks):
        sys.exit(1)
