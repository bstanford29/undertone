from __future__ import annotations

import threading
import time
from typing import Any

from . import dictionary, history

MAX_PHRASE_CHARS = 200
MAX_PHRASE_WORDS = 12
MAX_APP_CHARS = 300
MAX_SUGGESTIONS = 100
MAX_CLIENT_TOKEN_CHARS = 128

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

_ACTION_SCHEMA = """
CREATE TABLE IF NOT EXISTS learning_actions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    produced TEXT NOT NULL,
    term TEXT NOT NULL,
    term_key TEXT NOT NULL,
    row_id INTEGER NOT NULL,
    app_bundle_id TEXT NOT NULL,
    created_at REAL NOT NULL,
    client_token TEXT,
    status TEXT NOT NULL DEFAULT 'active'
)
"""

_DICTIONARY_WRITE_SCHEMA = """
CREATE TABLE IF NOT EXISTS dictionary_writes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    term TEXT NOT NULL,
    created_at REAL NOT NULL
)
"""


def _ensure_schema(db: Any) -> None:
    db.execute(_SCHEMA)
    db.execute(_SUPPRESSION_SCHEMA)
    db.execute(_ACTION_SCHEMA)
    db.execute(_DICTIONARY_WRITE_SCHEMA)
    columns = {row[1] for row in db.execute("PRAGMA table_info(learning_actions)")}
    if "client_token" not in columns:
        db.execute("ALTER TABLE learning_actions ADD COLUMN client_token TEXT")
    db.execute(
        "CREATE INDEX IF NOT EXISTS learning_actions_term_idx "
        "ON learning_actions(term_key, status)"
    )
    db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS learning_actions_client_token_idx "
        "ON learning_actions(client_token) WHERE client_token IS NOT NULL"
    )
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


def _action_id(value: Any) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise ValueError("action_id must be an integer")
    return value


def _client_token(value: Any) -> str:
    if (
        not isinstance(value, str)
        or not 1 <= len(value) <= MAX_CLIENT_TOKEN_CHARS
        or any(char not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for char in value)
    ):
        raise ValueError("Invalid client_token")
    return value


def _single_word(value: str, name: str) -> str:
    words = value.split()
    if len(words) != 1 or any(char.isspace() for char in value):
        raise ValueError(f"Invalid {name}")
    return words[0]


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


def _supersede_open_actions(db: Any, term: str, *, excluding_action_id: int | None = None) -> None:
    query = (
        "UPDATE learning_actions SET status = 'superseded' "
        "WHERE term_key = ? AND status IN ('active', 'preparing')"
    )
    parameters: tuple[Any, ...] = (term.casefold(),)
    if excluding_action_id is not None:
        query += " AND id != ?"
        parameters += (excluding_action_id,)
    db.execute(query, parameters)


def _dictionary_term(term_key: str) -> str | None:
    return next(
        (term for term in dictionary.load_dictionary()["terms"] if term.casefold() == term_key),
        None,
    )


def _activate_preparing_action(db: Any, action_id: int, term: str) -> None:
    _supersede_open_actions(db, term, excluding_action_id=action_id)
    db.execute(
        "UPDATE learning_actions SET status = 'active' WHERE id = ? AND status = 'preparing'",
        (action_id,),
    )


def _recover_dictionary_writes(db: Any) -> None:
    rows = db.execute("SELECT id, term FROM dictionary_writes ORDER BY id").fetchall()
    for write_id, term in rows:
        dictionary.add_term(term)
        db.execute("DELETE FROM dictionary_writes WHERE id = ?", (write_id,))


def _journal_dictionary_write(db: Any, term: str) -> int:
    cursor = db.execute(
        "INSERT INTO dictionary_writes (term, created_at) VALUES (?, ?)",
        (term, time.time()),
    )
    return cursor.lastrowid


def _write_journaled_dictionary_term(db: Any, write_id: int, term: str) -> dict[str, Any]:
    db.commit()
    dictionary_data = dictionary.add_term(term)
    db.execute("DELETE FROM dictionary_writes WHERE id = ?", (write_id,))
    return dictionary_data


def recover_pending_dictionary_writes() -> None:
    """Finish durable manual dictionary writes left by an interrupted engine."""
    with _LOCK, history._connect() as db:
        _ensure_schema(db)
        _recover_dictionary_writes(db)


def add_explicit_term(term: str) -> dict[str, Any]:
    """Add a user-owned term and transfer ownership from auto-learning actions."""
    with _LOCK:
        with history._connect() as db:
            _ensure_schema(db)
            _recover_dictionary_writes(db)
            _supersede_open_actions(db, term)
            write_id = _journal_dictionary_write(db, term)
            return _write_journaled_dictionary_term(db, write_id, term)


def remove_explicit_term(term: str) -> dict[str, Any]:
    """Remove a term after cancelling any interrupted manual add for it."""
    term_key = term.casefold()
    with _LOCK:
        with history._connect() as db:
            _ensure_schema(db)
            pending = db.execute("SELECT id, term FROM dictionary_writes").fetchall()
            for write_id, pending_term in pending:
                if pending_term.casefold() == term_key:
                    db.execute("DELETE FROM dictionary_writes WHERE id = ?", (write_id,))
            db.commit()
            return dictionary.remove_term(term)


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
        if action == "add":
            _recover_dictionary_writes(db)
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
        # Suggestion acceptance writes its term to the dictionary here.
        if action == "add":
            _supersede_open_actions(db, row[2])
            write_id = _journal_dictionary_write(db, row[2])
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
        if action == "add":
            _write_journaled_dictionary_term(db, write_id, row[2])
        return {"suggestion_id": suggestion_id, "status": desired}


def auto_learn(
    produced: str,
    replacement: str,
    row_id: int,
    app_bundle_id: str,
    *,
    enabled: bool,
    client_token: str | None = None,
) -> dict[str, Any]:
    """Learn one accepted correction and return an action-scoped undo token."""
    produced = _single_word(_phrase(produced, "produced"), "produced")
    replacement = _single_word(_phrase(replacement, "replacement"), "replacement")
    row_id = _row_id(row_id)
    app_bundle_id = _app_bundle(app_bundle_id)
    if client_token is not None:
        client_token = _client_token(client_token)
    if not enabled:
        return {"status": "disabled", "term": replacement}
    if produced.casefold() == replacement.casefold():
        raise ValueError("A learning action must change the word")

    term_key = replacement.casefold()
    with _LOCK:
        with history._connect() as db:
            _ensure_schema(db)
            owner = db.execute(
                "SELECT app_bundle_id FROM dictations WHERE id = ?", (row_id,)
            ).fetchone()
            if owner is None or owner[0] != app_bundle_id:
                raise ValueError("History row does not belong to app")
            if client_token is not None:
                existing_action = db.execute(
                    "SELECT id, term, term_key, status, created_at FROM learning_actions WHERE client_token = ?",
                    (client_token,),
                ).fetchone()
                if existing_action is not None:
                    if existing_action[3] == "preparing":
                        if _dictionary_term(existing_action[2]) is None:
                            dictionary.add_term(existing_action[1])
                        _activate_preparing_action(db, existing_action[0], existing_action[1])
                    return {
                        "status": "learned",
                        "term": existing_action[1],
                        "action_id": existing_action[0],
                        "created_at": existing_action[4],
                        "client_token": client_token,
                        "action_status": "active" if existing_action[3] == "preparing" else existing_action[3],
                    }
            terms = dictionary.load_dictionary()["terms"]
            existing = next((term for term in terms if term.casefold() == term_key), None)
            if existing is not None:
                return {"status": "already_known", "term": existing}
            created_at = time.time()
            cursor = db.execute(
                """INSERT INTO learning_actions
                   (produced, term, term_key, row_id, app_bundle_id, created_at, client_token, status)
                   VALUES (?, ?, ?, ?, ?, ?, ?, 'preparing')""",
                (produced, replacement, term_key, row_id, app_bundle_id, created_at, client_token),
            )
            action_id = cursor.lastrowid
            # Journal the action before the separate YAML store. Reconciliation
            # can then tell whether the term reached disk after an interruption.
            db.commit()
            dictionary.add_term(replacement)
            # A user may remove a previously learned term directly. Do not
            # let that stale action retain ownership of the new learning action
            # or block its undo.
            _activate_preparing_action(db, action_id, replacement)
            return {
                "status": "learned",
                "term": replacement,
                "action_id": action_id,
                "created_at": created_at,
                "client_token": client_token,
                "action_status": "active",
            }


def lookup(client_token: str) -> dict[str, Any]:
    """Resolve a token and finish or discard an interrupted journaled action."""
    client_token = _client_token(client_token)
    with _LOCK, history._connect() as db:
        _ensure_schema(db)
        row = db.execute(
            "SELECT id, term, status, created_at FROM learning_actions WHERE client_token = ?",
            (client_token,),
        ).fetchone()
        if row is None:
            return {"status": "not_found", "client_token": client_token}
        if row[2] == "preparing":
            if _dictionary_term(row[1].casefold()) is None:
                db.execute("DELETE FROM learning_actions WHERE id = ? AND status = 'preparing'", (row[0],))
                return {"status": "not_found", "client_token": client_token}
            _activate_preparing_action(db, row[0], row[1])
            action_status = "active"
        else:
            action_status = row[2]
        return {
            "status": "learned",
            "action_id": row[0],
            "term": row[1],
            "action_status": action_status,
            "created_at": row[3],
            "client_token": client_token,
        }


def undo(action_id: int) -> dict[str, Any]:
    """Undo only the vocabulary term owned by one active learning action."""
    action_id = _action_id(action_id)
    with _LOCK:
        with history._connect() as db:
            _ensure_schema(db)
            row = db.execute(
                "SELECT id, term, term_key, status FROM learning_actions WHERE id = ?",
                (action_id,),
            ).fetchone()
            if row is None:
                raise ValueError("Unknown learning action")
            if row[3] != "active":
                return {"status": row[3], "action_id": action_id, "term": row[1]}
            other = db.execute(
                "SELECT 1 FROM learning_actions WHERE term_key = ? AND status = 'active' AND id != ? LIMIT 1",
                (row[2], action_id),
            ).fetchone()
            if other is not None:
                db.execute(
                    "UPDATE learning_actions SET status = 'undone' WHERE id = ? AND status = 'active'",
                    (action_id,),
                )
                return {"status": "preserved", "action_id": action_id, "term": row[1]}
            terms = dictionary.load_dictionary()["terms"]
            owned = [term for term in terms if term.casefold() == row[2]]
            if len(owned) == 0:
                result = "absent"
            elif len(owned) == 1:
                dictionary.remove_term(owned[0])
                result = "removed"
            else:
                result = "preserved"
            db.execute(
                "UPDATE learning_actions SET status = 'undone' WHERE id = ? AND status = 'active'",
                (action_id,),
            )
            return {"status": result, "action_id": action_id, "term": row[1]}
