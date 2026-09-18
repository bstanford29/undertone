from __future__ import annotations

import sqlite3
import time
from pathlib import Path

HISTORY_DIR = Path.home() / ".undertone"
HISTORY_PATH = HISTORY_DIR / "history.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS dictations (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts REAL NOT NULL,
    app_bundle_id TEXT,
    raw_text TEXT,
    clean_text TEXT,
    stt_ms REAL,
    llm_ms REAL,
    insert_ms REAL,
    total_ms REAL,
    insert_mode TEXT,
    audio_seconds REAL,
    guard_fired INTEGER NOT NULL DEFAULT 0,
    model TEXT,
    audio_path TEXT,
    edited_text TEXT
)
"""


def _connect() -> sqlite3.Connection:
    HISTORY_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(HISTORY_PATH)
    conn.execute(SCHEMA)
    columns = {row[1] for row in conn.execute("PRAGMA table_info(dictations)")}
    for name, kind in {"guard_fired": "INTEGER NOT NULL DEFAULT 0", "model": "TEXT", "audio_path": "TEXT", "edited_text": "TEXT", "kind": "TEXT NOT NULL DEFAULT 'dictation'", "instruction_text": "TEXT"}.items():
        if name not in columns:
            conn.execute(f"ALTER TABLE dictations ADD COLUMN {name} {kind}")
    conn.commit()
    return conn


def frontmost_bundle_id() -> str | None:
    try:
        from AppKit import NSWorkspace

        app = NSWorkspace.sharedWorkspace().frontmostApplication()
        return app.bundleIdentifier() if app else None
    except Exception:
        return None


def record(
    raw_text: str,
    clean_text: str,
    stt_ms: float,
    llm_ms: float,
    insert_ms: float,
    total_ms: float,
    insert_mode: str,
    audio_seconds: float,
    app_bundle_id: str | None = None,
    guard_fired: bool = False,
    model: str | None = None,
    audio_path: str | None = None,
    kind: str = "dictation",
    instruction_text: str | None = None,
) -> int:
    if kind not in {"dictation", "command"}:
        raise ValueError("Invalid history kind")
    app_bundle_id = app_bundle_id or frontmost_bundle_id()
    with _connect() as conn:
        cursor = conn.execute(
            """INSERT INTO dictations
            (ts, app_bundle_id, raw_text, clean_text, stt_ms, llm_ms, insert_ms, total_ms, insert_mode, audio_seconds, guard_fired, model, audio_path, kind, instruction_text)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                time.time(),
                app_bundle_id,
                raw_text,
                clean_text,
                stt_ms,
                llm_ms,
                insert_ms,
                total_ms,
                insert_mode,
                audio_seconds,
                int(guard_fired),
                model,
                audio_path,
                kind,
                instruction_text,
            ),
        )
        return cursor.lastrowid
