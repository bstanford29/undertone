from __future__ import annotations

import threading
import time
from typing import Any

from . import dictionary, history

MAX_PHRASE_CHARS = 200
MAX_PHRASE_WORDS = 12
MAX_APP_CHARS = 300
MAX_SUGGESTIONS = 100

_LOCK = threading.RLock()

_SCHEMA = """
CREATE TABLE IF NOT EXISTS learned_suggestions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    produced TEXT NOT NULL,
    replacement TEXT NOT NULL,
    row_id INTEGER NOT NULL,
    app_bundle_id TEXT NOT NULL,
    created_at REAL NOT NULL,
    reason TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    produced_key TEXT NOT NULL,
    replacement_key TEXT NOT NULL
)
"""

_SUPPRESSION_SCHEMA = """
CREATE TABLE IF NOT EXISTS learned_suppressions (
    produced_key TEXT PRIMARY KEY,
    created_at REAL NOT NULL
)
"""


def _ensure_schema(db: Any) -> None:
    db.execute(_SCHEMA)
    db.execute(_SUPPRESSION_SCHEMA)
    db.execute(
        "CREATE INDEX IF NOT EXISTS learned_suggestions_pending_idx "
        "ON learned_suggestions(status, created_at DESC)"
    )


def _phrase(value: Any, name: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"Invalid {name}")
    value = value.strip()
    if not value or len(value) > MAX_PHRASE_CHARS or len(value.split()) > MAX_PHRASE_WORDS:
        raise ValueError(f"Invalid {name}")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError(f"Invalid {name}")
    return value


def _app_bundle(value: Any) -> str:
    if not isinstance(value, str):
        raise ValueError("Invalid app_bundle_id")
    value = value.strip()
    if not value or len(value) > MAX_APP_CHARS:
        raise ValueError("Invalid app_bundle_id")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise ValueError("Invalid app_bundle_id")
    return value


def _row_id(value: Any) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ValueError("row_id must be an integer")
    return value


def _suggestion(row: Any) -> dict[str, Any]:
    return {
        "id": row[0],
        "produced": row[1],
        "replacement": row[2],
        "row_id": row[3],
        "app_bundle_id": row[4],
        "created_at": row[5],
        "reason": row[6],
    }


def propose(
    produced: str,
    replacement: str,
    row_id: int,
    app_bundle_id: str,
) -> dict[str, Any] | None:
    """Queue a bounded post-edit suggestion for the matching history row."""
    produced = _phrase(produced, "produced")
    replacement = _phrase(replacement, "replacement")
    row_id = _row_id(row_id)
    app_bundle_id = _app_bundle(app_bundle_id)
    if produced.casefold() == replacement.casefold():
        raise ValueError("A suggestion must change the phrase")
    produced_key = produced.casefold()
    replacement_key = replacement.casefold()

    with _LOCK, history._connect() as db:
        _ensure_schema(db)
        owner = db.execute(
            "SELECT app_bundle_id FROM dictations WHERE id = ?", (row_id,)
        ).fetchone()
        if owner is None or owner[0] != app_bundle_id:
            raise ValueError("History row does not belong to app")
        if db.execute(
            "SELECT 1 FROM learned_suppressions WHERE produced_key = ?",
            (produced_key,),
        ).fetchone():
            return None
        if db.execute(
            """SELECT 1 FROM learned_suggestions
               WHERE produced_key = ? AND replacement_key = ? AND app_bundle_id = ? AND status != 'ignored'""",
            (produced_key, replacement_key, app_bundle_id),
        ).fetchone():
            return None
        created_at = time.time()
        cursor = db.execute(
            """INSERT INTO learned_suggestions
               (produced, replacement, row_id, app_bundle_id, created_at, reason,
                produced_key, replacement_key)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                produced,
                replacement,
                row_id,
                app_bundle_id,
                created_at,
                "post_insert_edit",
                produced_key,
                replacement_key,
            ),
        )
        return {
            "id": cursor.lastrowid,
            "produced": produced,
            "replacement": replacement,
            "row_id": row_id,
            "app_bundle_id": app_bundle_id,
            "created_at": created_at,
            "reason": "post_insert_edit",
        }


def list_suggestions(limit: int = MAX_SUGGESTIONS) -> list[dict[str, Any]]:
    if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= MAX_SUGGESTIONS:
        raise ValueError("limit must be 1 through 100")
    with _LOCK, history._connect() as db:
        _ensure_schema(db)
        rows = db.execute(
            """SELECT id, produced, replacement, row_id, app_bundle_id, created_at, reason
               FROM learned_suggestions WHERE status = 'pending'
               ORDER BY created_at DESC, id DESC LIMIT ?""",
            (limit,),
        ).fetchall()
        return [_suggestion(row) for row in rows]


def act(suggestion_id: int, action: str) -> dict[str, Any]:
    suggestion_id = _row_id(suggestion_id)
    if action not in {"add", "ignore", "never_ask"}:
        raise ValueError("Invalid learned action")
    with _LOCK, history._connect() as db:
        _ensure_schema(db)
        row = db.execute(
            """SELECT id, produced, replacement, row_id, app_bundle_id, created_at, reason,
                      status, produced_key
               FROM learned_suggestions WHERE id = ?""",
            (suggestion_id,),
        ).fetchone()
        if row is None:
            raise ValueError("Unknown suggestion")
        status = row[7]
        desired = {"add": "added", "ignore": "ignored", "never_ask": "never_ask"}[action]
        if status == desired:
            return {"suggestion_id": suggestion_id, "status": desired}
        if status != "pending":
            raise ValueError("Suggestion was already handled")
        # This is deliberately the only path that writes an auto-learned term.
        if action == "add":
            dictionary.add_term(row[2])
        if action == "never_ask":
            db.execute(
                "INSERT OR IGNORE INTO learned_suppressions (produced_key, created_at) VALUES (?, ?)",
                (row[8], time.time()),
            )
            db.execute(
                "UPDATE learned_suggestions SET status = 'never_ask' WHERE produced_key = ? AND status = 'pending'",
                (row[8],),
            )
        else:
            db.execute(
                "UPDATE learned_suggestions SET status = ? WHERE id = ?",
                (desired, suggestion_id),
            )
        return {"suggestion_id": suggestion_id, "status": desired}
