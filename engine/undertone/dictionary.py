from __future__ import annotations

import re
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


def _write_defaults() -> None:
    DICTIONARY_DIR.mkdir(parents=True, exist_ok=True)
    data = {"terms": DEFAULT_TERMS, "replacements": DEFAULT_REPLACEMENTS}
    with DICTIONARY_PATH.open("w") as f:
        yaml.safe_dump(data, f, sort_keys=False)


def load_dictionary() -> dict[str, Any]:
    if not DICTIONARY_PATH.exists():
        _write_defaults()
        return {"terms": list(DEFAULT_TERMS), "replacements": dict(DEFAULT_REPLACEMENTS)}

    with DICTIONARY_PATH.open() as f:
        loaded = yaml.safe_load(f) or {}

    terms = loaded.get("terms") or []
    replacements = loaded.get("replacements") or {}
    return {"terms": list(terms), "replacements": dict(replacements)}


def save_dictionary(dictionary: dict[str, Any]) -> None:
    DICTIONARY_DIR.mkdir(parents=True, exist_ok=True)
    with DICTIONARY_PATH.open("w") as f:
        yaml.safe_dump(dictionary, f, sort_keys=False)


def add_term(term: str) -> dict[str, Any]:
    dictionary = load_dictionary()
    terms = dictionary["terms"]
    # Most-recently-used first: drop any existing occurrence, then prepend.
    terms = [t for t in terms if t.lower() != term.lower()]
    terms.insert(0, term)
    dictionary["terms"] = terms
    save_dictionary(dictionary)
    return dictionary


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
