from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

CONFIG_DIR = Path.home() / ".undertone"
CONFIG_PATH = CONFIG_DIR / "config.yaml"

VALID_HOLD_KEYS = {"f13", "right_option", "right_cmd"}
VALID_INSERT_MODES = {"ax", "type", "paste"}
VALID_CLEANUP_LEVELS = {"none", "light", "medium", "high"}

DEFAULTS: dict[str, Any] = {
    "hold_key": "f13",
    "stt_model": "mlx-community/whisper-large-v3-turbo",
    "cleanup_model": "qwen3.5:latest",
    "cleanup_fallback_model": "",
    "cleanup_high_model": "gemma4:31b",
    "cleanup_high_fallback_model": "qwen3.5:latest",
    "ollama_url": "http://localhost:11434",
    "ollama_keep_alive": "60m",
    "ollama_num_ctx": 8192,
    "app_prompt_variants": {
        "com.apple.MobileSMS": "Keep the speaker's casual tone and contractions. Preserve every spoken fact and request.",
        "com.apple.mail": "Use conventional punctuation and paragraph breaks suitable for email. Preserve the spoken wording and greetings; add no greeting or sign-off.",
    },
    "insert_mode": "ax",
    "cleanup_level": "medium",
    "short_utterance_words": 6,
    "min_speech_seconds": 0.4,
    "min_speech_rms": 0.004,
    "toggle_mode": False,
    "double_tap_lock": True,
    "streaming": False,
    "sounds": True,
    "whisper_mode": False,
    "stream_insert": True,
    "obsidian_vault_path": None,
    "pill_persistent": True,
    "pill_edge": "bottom",
    "pill_offset": 0.5,
}

VALID_PILL_EDGES = {"bottom", "top", "left", "right"}

MAX_APP_VARIANTS = 50
MAX_APP_ID_CHARS = 300
MAX_VARIANT_CHARS = 2000


def valid_app_prompt_variants(value: Any) -> bool:
    """True when `value` is a bundle id -> style text map the cleaner can use."""
    if not isinstance(value, dict) or len(value) > MAX_APP_VARIANTS:
        return False
    for key, text in value.items():
        if not isinstance(key, str) or not key.strip() or len(key) > MAX_APP_ID_CHARS:
            return False
        if any(ord(char) < 32 or ord(char) == 127 for char in key):
            return False
        if not isinstance(text, str) or not text.strip() or len(text) > MAX_VARIANT_CHARS:
            return False
    return True


def _write_defaults() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    with CONFIG_PATH.open("w") as f:
        yaml.safe_dump(DEFAULTS, f, sort_keys=False)


def load_config() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        _write_defaults()
        return dict(DEFAULTS)

    with CONFIG_PATH.open() as f:
        loaded = yaml.safe_load(f) or {}

    config = dict(DEFAULTS)
    config.update(loaded)

    if config["hold_key"] not in VALID_HOLD_KEYS:
        config["hold_key"] = DEFAULTS["hold_key"]
    if config["insert_mode"] not in VALID_INSERT_MODES:
        config["insert_mode"] = DEFAULTS["insert_mode"]
    if config["cleanup_level"] not in VALID_CLEANUP_LEVELS:
        config["cleanup_level"] = DEFAULTS["cleanup_level"]
    if config.get("pill_edge") not in VALID_PILL_EDGES:
        config["pill_edge"] = DEFAULTS["pill_edge"]
    try:
        offset = float(config.get("pill_offset", DEFAULTS["pill_offset"]))
    except (TypeError, ValueError):
        offset = DEFAULTS["pill_offset"]
    config["pill_offset"] = min(1.0, max(0.0, offset))
    config["pill_persistent"] = bool(config.get("pill_persistent", DEFAULTS["pill_persistent"]))
    config["double_tap_lock"] = bool(config.get("double_tap_lock", DEFAULTS["double_tap_lock"]))
    if not valid_app_prompt_variants(config.get("app_prompt_variants")):
        config["app_prompt_variants"] = dict(DEFAULTS["app_prompt_variants"])

    return config
