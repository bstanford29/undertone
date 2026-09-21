from __future__ import annotations

import re
import threading
from pathlib import Path
from typing import Any

import yaml

DICTIONARY_DIR = Path.home() / ".undertone"
DICTIONARY_PATH = DICTIONARY_DIR / "dictionary.yaml"

DEFAULT_TERMS = [
    "Undertone",
    "Obsidian",
    "Ollama",
    "Qwen",
    "Whisper",
]

DEFAULT_REPLACEMENTS = {
    "btw": "by the way",
}

# Rough cap on vocab prompt size. ~180 tokens at ~4 chars/token.
VOCAB_CHAR_CAP = 180 * 4

_LOCK = threading.RLock()


def _write_defaults() -> None:
    data = {"terms": DEFAULT_TERMS, "replacements": DEFAULT_REPLACEMENTS}
    _save_dictionary(data)


def _save_dictionary(data: dict[str, Any]) -> None:
    DICTIONARY_DIR.mkdir(parents=True, exist_ok=True)
    temporary = DICTIONARY_PATH.with_name(DICTIONARY_PATH.name + ".tmp")
    with temporary.open("w") as f:
        yaml.safe_dump(data, f, sort_keys=False)
    temporary.chmod(0o600)
    temporary.replace(DICTIONARY_PATH)


def load_dictionary() -> dict[str, Any]:
    with _LOCK:
        if not DICTIONARY_PATH.exists():
            _write_defaults()
            return {"terms": list(DEFAULT_TERMS), "replacements": dict(DEFAULT_REPLACEMENTS)}

        with DICTIONARY_PATH.open() as f:
            loaded = yaml.safe_load(f) or {}

        terms = loaded.get("terms") or []
        replacements = loaded.get("replacements") or {}
        return {"terms": list(terms), "replacements": dict(replacements)}


def save_dictionary(data: dict[str, Any]) -> None:
    with _LOCK:
        _save_dictionary(data)


def add_term(term: str) -> dict[str, Any]:
    with _LOCK:
        data = load_dictionary()
        terms = data["terms"]
        # Most-recently-used first: drop any existing occurrence, then prepend.
        terms = [t for t in terms if t.casefold() != term.casefold()]
        terms.insert(0, term)
        data["terms"] = terms
        save_dictionary(data)
        return data


def remove_term(term: str) -> dict[str, Any]:
    """Remove every case-insensitive occurrence of one vocabulary term."""
    with _LOCK:
        data = load_dictionary()
        data["terms"] = [existing for existing in data["terms"] if existing.casefold() != term.casefold()]
        save_dictionary(data)
        return data


def set_replacement(phrase: str, replacement: str) -> dict[str, Any]:
    with _LOCK:
        data = load_dictionary()
        data["replacements"][phrase] = replacement
        save_dictionary(data)
        return data


def vocab_prompt(dictionary: dict[str, Any] | None = None) -> str:
    dictionary = load_dictionary() if dictionary is None else dictionary
    terms = dictionary.get("terms", [])
    joined = ""
    for term in terms:
        candidate = f"{joined}, {term}" if joined else term
        if len(candidate) > VOCAB_CHAR_CAP:
            break
        joined = candidate
    return joined


def apply_replacements(text: str, dictionary: dict[str, Any] | None = None) -> str:
    dictionary = load_dictionary() if dictionary is None else dictionary
    replacements = dictionary.get("replacements", {})
    for phrase, replacement in replacements.items():
        pattern = re.compile(rf"(?<!\w){re.escape(phrase)}(?!\w)", re.IGNORECASE)
        text = pattern.sub(lambda match: replacement, text)
    return text
