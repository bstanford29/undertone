from __future__ import annotations

import inspect
import json
import logging
import math
import os
import re
import shutil
import sqlite3
import tempfile
import threading
import time
import unicodedata
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Iterator

logger = logging.getLogger(__name__)

MAX_TITLE_CHARS = 200
MAX_NOTES_CHARS = 50_000
MAX_SUMMARY_CHARS = 20_000
MAX_TITLE_WORDS = 8
TITLE_TRANSCRIPT_CHARS = 1_500
DEFAULT_TITLE = "Meeting"
MAX_AUDIO_PATH_CHARS = 4096
MAX_CHUNKS = 10_000
MAX_CHUNK_SECONDS = 120.0
MAX_MEETING_SECONDS = 24 * 60 * 60.0
MAX_AUDIO_BYTES = 100 * 1024 * 1024
MAX_PAGE_SIZE = 100
MAX_SUMMARY_SECTION_CHARS = 12_000
MAX_SUMMARY_INPUT_CHARS = 12_000
MAX_SUMMARY_ROUNDS = 8

_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
_SPEAKERS = {"me", "others"}
# A meeting that has finished. "needs_vault" is ended too; it only lacks an
# Obsidian export because no vault is configured.
_ENDED_STATUSES = {"ended", "needs_vault"}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS meeting_sessions (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    started_at REAL NOT NULL,
    ended_at REAL,
    status TEXT NOT NULL,
    summary TEXT,
    note_path TEXT,
    transcript_path TEXT NOT NULL,
    notes TEXT NOT NULL DEFAULT '',
    title_source TEXT NOT NULL DEFAULT 'user',
    summary_edited INTEGER NOT NULL DEFAULT 0,
    updated_at REAL
);
CREATE TABLE IF NOT EXISTS meeting_chunks (
    session_id TEXT NOT NULL REFERENCES meeting_sessions(id),
    seq INTEGER NOT NULL,
    source_path TEXT NOT NULL,
    retained_path TEXT NOT NULL,
    speaker TEXT NOT NULL,
    voice_activity INTEGER NOT NULL DEFAULT 1,
    offset_s REAL NOT NULL,
    duration_s REAL NOT NULL,
    status TEXT NOT NULL,
    text TEXT,
    stt_ms REAL,
    error_code TEXT,
    created_at REAL NOT NULL,
    PRIMARY KEY (session_id, seq)
);
CREATE INDEX IF NOT EXISTS meeting_chunks_session_idx
    ON meeting_chunks(session_id, seq);
"""

# Columns added to meeting_sessions after the first release. A database made by
# an older build keeps the original CREATE TABLE shape, so each column is added
# once, guarded by PRAGMA table_info.
_SESSION_COLUMNS = (
    ("notes", "notes TEXT NOT NULL DEFAULT ''"),
    ("title_source", "title_source TEXT NOT NULL DEFAULT 'user'"),
    ("summary_edited", "summary_edited INTEGER NOT NULL DEFAULT 0"),
    ("updated_at", "updated_at REAL"),
)

_SESSION_FIELDS = (
    "id,title,started_at,ended_at,status,summary,note_path,transcript_path,"
    "notes,title_source,summary_edited,updated_at"
)


def _accepts_mode(summarize: Callable[..., str] | None) -> bool:
    """Report whether the injected summarizer takes the ``mode`` keyword.

    Test doubles and older callers pass a one-argument callable. Asking the
    signature once keeps those working without catching TypeError at call time,
    which would hide a real TypeError raised inside the callable.
    """
    if summarize is None:
        return False
    try:
        signature = inspect.signature(summarize)
    except (TypeError, ValueError):
        return False
    for parameter in signature.parameters.values():
        if parameter.kind is inspect.Parameter.VAR_KEYWORD:
            return True
        if parameter.name == "mode" and parameter.kind in {
            inspect.Parameter.KEYWORD_ONLY,
            inspect.Parameter.POSITIONAL_OR_KEYWORD,
        }:
            return True
    return False


class MeetingService:
    """Retain local meeting audio/transcripts and optionally export a note.

    ``transcribe`` receives the retained audio path. ``summarize`` receives a
    bounded transcript section and returns summary text. Both callbacks are
    injected so the store can be tested without loading a model.
    """

    def __init__(
        self,
        database_path: str | Path,
        audio_root: str | Path,
        *,
        transcribe: Callable[[str], str] | None = None,
        summarize: Callable[[str], str] | None = None,
    ) -> None:
        self.database_path = Path(database_path).expanduser()
        self.audio_root = Path(audio_root).expanduser()
        self.transcribe = transcribe
        self.summarize = summarize
        self._lock = threading.RLock()
        self._initialize()

    @property
    def summarize(self) -> Callable[..., str] | None:
        return self._summarize_callable

    @summarize.setter
    def summarize(self, value: Callable[..., str] | None) -> None:
        # Callers may swap the summarizer after construction, so the record of
        # whether it understands prompt modes is refreshed with it.
        self._summarize_callable = value
        self._summarize_takes_mode = _accepts_mode(value)

    @contextmanager
    def _connect(self) -> Iterator[sqlite3.Connection]:
        self.database_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        conn = sqlite3.connect(self.database_path)
        try:
            conn.execute("PRAGMA foreign_keys = ON")
            conn.executescript(_SCHEMA)
            columns = {row[1] for row in conn.execute("PRAGMA table_info(meeting_chunks)")}
            if "voice_activity" not in columns:
                conn.execute("ALTER TABLE meeting_chunks ADD COLUMN voice_activity INTEGER NOT NULL DEFAULT 1")
            columns = {row[1] for row in conn.execute("PRAGMA table_info(meeting_sessions)")}
            for name, definition in _SESSION_COLUMNS:
                if name not in columns:
                    conn.execute(f"ALTER TABLE meeting_sessions ADD COLUMN {definition}")
            yield conn
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()

    def _initialize(self) -> None:
        self.audio_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.audio_root.chmod(0o700)
        with self._connect():
            pass
        self.database_path.chmod(0o600)

    @staticmethod
    def _title(value: Any) -> str:
        if value is None:
            return DEFAULT_TITLE
        if not isinstance(value, str):
            raise ValueError("Invalid meeting title")
        value = value.strip()
        if not value or len(value) > MAX_TITLE_CHARS:
            raise ValueError("Invalid meeting title")
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("Invalid meeting title")
        return value

    @staticmethod
    def _start_title(value: Any) -> tuple[str, str]:
        """Return the stored title and where it came from.

        No title, or a title of only whitespace, starts the meeting as
        "Meeting" so ``end`` may replace it with a generated one.
        """
        if value is None or (isinstance(value, str) and not value.strip()):
            return DEFAULT_TITLE, "default"
        return MeetingService._title(value), "user"

    @staticmethod
    def _body(value: Any, name: str, limit: int) -> str:
        if not isinstance(value, str) or len(value) > limit:
            raise ValueError(f"Invalid meeting {name}")
        if any(ord(char) < 32 and char not in "\n\r\t" for char in value):
            raise ValueError(f"Invalid meeting {name}")
        return value

    @staticmethod
    def _session_id(value: Any) -> str:
        if not isinstance(value, str) or not _ID_RE.fullmatch(value):
            raise ValueError("Invalid meeting session")
        return value

    @staticmethod
    def _seq(value: Any) -> int:
        if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value < MAX_CHUNKS:
            raise ValueError("Invalid meeting chunk sequence")
        return value

    @staticmethod
    def _number(value: Any, name: str, *, positive: bool = False) -> float:
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError(f"Invalid {name}")
        value = float(value)
        if not math.isfinite(value) or value < 0 or (positive and value <= 0):
            raise ValueError(f"Invalid {name}")
        return value

    @staticmethod
    def _speaker(value: Any) -> str:
        if value not in _SPEAKERS:
            raise ValueError("Invalid meeting speaker")
        return value

    @staticmethod
    def _voice_activity(value: Any) -> bool:
        if not isinstance(value, bool):
            raise ValueError("voice_activity must be a boolean")
        return value

    @staticmethod
    def _source(value: Any, *, require_exists: bool) -> Path:
        if not isinstance(value, str) or len(value) > MAX_AUDIO_PATH_CHARS:
            raise ValueError("Invalid meeting audio path")
        path = Path(value).expanduser()
        if not path.is_absolute():
            raise ValueError("Meeting audio path must be absolute")
        if require_exists and (path.is_symlink() or not path.is_file()):
            raise ValueError("Meeting audio file is unavailable")
        if require_exists and path.stat().st_size > MAX_AUDIO_BYTES:
            raise ValueError("Meeting audio file is too large")
        return path

    def start(self, title: str | None = None, *, started_at: float | None = None) -> dict[str, Any]:
        title, title_source = self._start_title(title)
        timestamp = time.time() if started_at is None else self._number(started_at, "started_at")
        session_id = uuid.uuid4().hex
        session_dir = self.audio_root / session_id
        session_dir.mkdir(mode=0o700)
        transcript_path = session_dir / "transcript.ndjson"
        transcript_path.touch(mode=0o600)
        with self._lock, self._connect() as db:
            db.execute(
                """INSERT INTO meeting_sessions
                   (id,title,started_at,status,transcript_path,notes,title_source,summary_edited,updated_at)
                   VALUES (?,?,?,?,?,'',?,0,?)""",
                (session_id, title, timestamp, "recording", str(transcript_path), title_source, timestamp),
            )
        return self.get(session_id)["session"]

    def chunk(
        self,
        session_id: str,
        seq: int,
        audio_path: str,
        speaker: str,
        offset_s: float,
        duration_s: float,
        voice_activity: bool = True,
    ) -> dict[str, Any]:
        session_id = self._session_id(session_id)
        seq = self._seq(seq)
        speaker = self._speaker(speaker)
        voice_activity = self._voice_activity(voice_activity)
        offset_s = self._number(offset_s, "offset_s")
        duration_s = self._number(duration_s, "duration_s", positive=True)
        if duration_s > MAX_CHUNK_SECONDS or offset_s + duration_s > MAX_MEETING_SECONDS:
            raise ValueError("Meeting chunk is too long")

        with self._lock:
            with self._connect() as db:
                session = db.execute(
                    "SELECT status, started_at FROM meeting_sessions WHERE id = ?", (session_id,)
                ).fetchone()
                if session is None:
                    raise ValueError("Unknown meeting session")
                if session[0] != "recording":
                    raise ValueError("Meeting is not recording")
                existing = db.execute(
                    """SELECT source_path, speaker, offset_s, duration_s, retained_path, status, text,
                              stt_ms, error_code, voice_activity
                       FROM meeting_chunks WHERE session_id = ? AND seq = ?""",
                    (session_id, seq),
                ).fetchone()
                source = self._source(audio_path, require_exists=existing is None)
                if existing is not None:
                    if (
                        existing[0] != str(source)
                        or existing[1] != speaker
                        or existing[2] != offset_s
                        or existing[3] != duration_s
                        or bool(existing[9]) != voice_activity
                    ):
                        raise ValueError("Meeting chunk retry does not match")
                    if existing[5] == "complete":
                        self._rewrite_transcript(session_id)
                        return self._chunk_response(session_id, seq, existing)
                    retained_path = Path(existing[4])
                else:
                    max_seq = db.execute(
                        "SELECT MAX(seq) FROM meeting_chunks WHERE session_id = ?", (session_id,)
                    ).fetchone()[0]
                    if (max_seq is None and seq != 0) or (max_seq is not None and seq != max_seq + 1):
                        raise ValueError("Meeting chunks must be contiguous")
                    session_dir = self.audio_root / session_id
                    retained_path = session_dir / f"{seq:06d}-{speaker}.wav"
                    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
                    try:
                        descriptor = os.open(retained_path, flags, 0o600)
                    except FileExistsError as exc:
                        raise ValueError("Meeting retained audio collision") from exc
                    copied = False
                    try:
                        with os.fdopen(descriptor, "wb") as retained:
                            descriptor = -1
                            with source.open("rb") as original:
                                shutil.copyfileobj(original, retained)
                            retained.flush()
                            os.fsync(retained.fileno())
                        copied = True
                    finally:
                        if descriptor >= 0:
                            os.close(descriptor)
                        if not copied:
                            retained_path.unlink(missing_ok=True)
                    db.execute(
                        """INSERT INTO meeting_chunks
                           (session_id,seq,source_path,retained_path,speaker,voice_activity,offset_s,duration_s,status,created_at)
                           VALUES (?,?,?,?,?,?,?,?,?,?)""",
                        (session_id, seq, str(source), str(retained_path), speaker, int(voice_activity), offset_s, duration_s, "pending", time.time()),
                    )
                    db.commit()

            if not voice_activity:
                with self._connect() as db:
                    db.execute(
                        "UPDATE meeting_chunks SET status='complete', text='', stt_ms=0, error_code=NULL WHERE session_id=? AND seq=?",
                        (session_id, seq),
                    )
                self._rewrite_transcript(session_id)
                return {"session_id": session_id, "seq": seq, "status": "complete", "text": "", "stt_ms": 0.0, "voice_activity": False}

            if self.transcribe is None:
                self._mark_chunk_error(session_id, seq, "stt_unavailable")
                return self._chunk_error_response(session_id, seq, "stt_unavailable")
            started = time.perf_counter()
            try:
                text = self.transcribe(str(retained_path))
                if not isinstance(text, str):
                    raise ValueError("invalid transcription")
                text = text.strip()
            except Exception:
                self._mark_chunk_error(session_id, seq, "stt_failed")
                return self._chunk_error_response(session_id, seq, "stt_failed")
            elapsed = (time.perf_counter() - started) * 1000
            with self._connect() as db:
                db.execute(
                    "UPDATE meeting_chunks SET status='complete', text=?, stt_ms=?, error_code=NULL WHERE session_id=? AND seq=?",
                    (text, elapsed, session_id, seq),
                )
            self._rewrite_transcript(session_id)
            return {"session_id": session_id, "seq": seq, "status": "complete", "text": text, "stt_ms": elapsed, "voice_activity": True}

    def _mark_chunk_error(self, session_id: str, seq: int, code: str) -> None:
        with self._connect() as db:
            db.execute(
                "UPDATE meeting_chunks SET status='error', error_code=?, stt_ms=NULL WHERE session_id=? AND seq=?",
                (code, session_id, seq),
            )

    @staticmethod
    def _chunk_response(session_id: str, seq: int, row: tuple[Any, ...]) -> dict[str, Any]:
        return {
            "session_id": session_id,
            "seq": seq,
            "source_path": row[0],
            "status": row[5],
            "text": row[6] or "",
            "stt_ms": row[7],
            "voice_activity": bool(row[9]),
        }

    @staticmethod
    def _chunk_error_response(session_id: str, seq: int, code: str) -> dict[str, Any]:
        return {"session_id": session_id, "seq": seq, "status": "error", "error_code": code}

    def _rewrite_transcript(self, session_id: str) -> None:
        with self._connect() as db:
            row = db.execute(
                "SELECT transcript_path FROM meeting_sessions WHERE id = ?", (session_id,)
            ).fetchone()
            chunks = db.execute(
                """SELECT seq, offset_s, speaker, text FROM meeting_chunks
                   WHERE session_id = ? AND status = 'complete' ORDER BY offset_s, seq""",
                (session_id,),
            ).fetchall()
        if row is None:
            raise ValueError("Unknown meeting session")
        destination = Path(row[0])
        destination.parent.mkdir(mode=0o700, exist_ok=True)
        fd, temporary_name = tempfile.mkstemp(prefix=".transcript-", suffix=".tmp", dir=destination.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                for seq, offset_s, speaker, text in chunks:
                    output.write(json.dumps({"seq": seq, "timestamp": offset_s, "speaker": speaker, "text": text}, ensure_ascii=False) + "\n")
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary_name, destination)
        finally:
            Path(temporary_name).unlink(missing_ok=True)

    @staticmethod
    def _safe_title(title: str) -> str:
        title = unicodedata.normalize("NFKC", title)
        title = re.sub(r"[^A-Za-z0-9 _.-]+", "_", title).strip(" ._")
        return (title or "Meeting")[:80]

    @staticmethod
    def _vault(vault_path: str | Path | None) -> tuple[Path | None, Path | None]:
        if vault_path is None:
            return None, None
        if not isinstance(vault_path, (str, Path)):
            raise ValueError("Invalid Obsidian vault path")
        vault = Path(vault_path).expanduser()
        if not vault.is_absolute() or vault.is_symlink() or not vault.is_dir():
            raise ValueError("Obsidian vault must be an existing absolute directory")
        meetings = vault / "Meetings"
        if meetings.exists() and meetings.is_symlink():
            raise ValueError("Obsidian Meetings path must not be a symlink")
        if meetings.exists() and not meetings.is_dir():
            raise ValueError("Obsidian Meetings path must be a directory")
        meetings.mkdir(mode=0o700, exist_ok=True)
        meetings = meetings.resolve()
        if meetings.parent != vault.resolve():
            raise ValueError("Obsidian Meetings path escaped vault")
        return vault.resolve(), meetings

    def end(self, session_id: str, *, vault_path: str | Path | None = None) -> dict[str, Any]:
        session_id = self._session_id(session_id)
        with self._lock:
            with self._connect() as db:
                session = db.execute(
                    f"SELECT {_SESSION_FIELDS} FROM meeting_sessions WHERE id=?",
                    (session_id,),
                ).fetchone()
                if session is None:
                    raise ValueError("Unknown meeting session")
                if session[4] == "ended":
                    return self.get(session_id)["session"]
                complete = db.execute(
                    "SELECT COUNT(*) FROM meeting_chunks WHERE session_id=? AND status != 'complete'",
                    (session_id,),
                ).fetchone()[0]
                if complete:
                    raise ValueError("Meeting has untranscribed chunks")
            _, meetings = self._vault(vault_path)
            try:
                self._rewrite_transcript(session_id)
                summary = session[5] or self._make_summary(session_id)
            except Exception:
                with self._connect() as db:
                    db.execute("UPDATE meeting_sessions SET status='summary_failed' WHERE id=?", (session_id,))
                result = self.get(session_id)["session"]
                result["error_code"] = "summary_failed"
                return result
            self._apply_auto_title(session_id, summary)
            if meetings is None:
                with self._connect() as db:
                    db.execute(
                        "UPDATE meeting_sessions SET summary=?,ended_at=COALESCE(ended_at,?),status='needs_vault' WHERE id=?",
                        (summary, time.time(), session_id),
                    )
                result = self.get(session_id)["session"]
                result["needs_vault"] = True
                return result
            session = self.get(session_id, limit=MAX_PAGE_SIZE)["session"]
            session["chunks"] = self._all_chunks(session_id)
            with self._connect() as db:
                db.execute(
                    "UPDATE meeting_sessions SET summary=?,status='exporting' WHERE id=?",
                    (summary, session_id),
                )
            date = datetime.fromtimestamp(session["started_at"]).strftime("%Y-%m-%d")
            filename = f"{date} {self._safe_title(session['title'])} [{session_id[:8]}].md"
            note_path = meetings / filename
            note = self._note_text(session, summary)
            if note_path.exists() or note_path.is_symlink():
                if note_path.is_file() and note_path.read_text(encoding="utf-8") == note:
                    with self._connect() as db:
                        db.execute(
                            "UPDATE meeting_sessions SET ended_at=COALESCE(ended_at,?),status='ended',note_path=? WHERE id=?",
                            (time.time(), str(note_path), session_id),
                        )
                    return self.get(session_id)["session"]
                raise ValueError("Obsidian note already exists")
            self._atomic_write(note_path, note, replace=False)
            with self._connect() as db:
                db.execute(
                    "UPDATE meeting_sessions SET ended_at=COALESCE(ended_at,?),status='ended',summary=?,note_path=? WHERE id=?",
                    (time.time(), summary, str(note_path), session_id),
                )
            return self.get(session_id)["session"]

    def _make_summary(self, session_id: str) -> str:
        if self.summarize is None:
            raise RuntimeError("summary unavailable")
        with self._connect() as db:
            rows = db.execute(
                "SELECT seq,offset_s,speaker,text FROM meeting_chunks WHERE session_id=? ORDER BY offset_s,seq",
                (session_id,),
            ).fetchall()
        lines = [
            f"[{offset_s:.3f}] {speaker}: {text}"
            for _, offset_s, speaker, text in rows
            if isinstance(text, str) and text.strip()
        ]
        if not lines:
            return "No transcript captured."
        sections: list[str] = []
        current = ""
        for line in lines:
            if current and len(current) + len(line) + 1 > MAX_SUMMARY_SECTION_CHARS:
                sections.append(current)
                current = ""
            if len(line) > MAX_SUMMARY_SECTION_CHARS:
                for start in range(0, len(line), MAX_SUMMARY_SECTION_CHARS):
                    part = line[start : start + MAX_SUMMARY_SECTION_CHARS]
                    if current:
                        sections.append(current)
                    current = part
            else:
                current = f"{current}\n{line}".strip() if current else line
        if current:
            sections.append(current)
        summaries = self._summarize_all(sections)
        if not all(isinstance(value, str) and value.strip() for value in summaries):
            raise ValueError("summary returned no text")
        for _ in range(MAX_SUMMARY_ROUNDS):
            if any(len(value) > MAX_SUMMARY_INPUT_CHARS for value in summaries):
                raise ValueError("summary output is too large")
            if len(summaries) <= 1:
                return summaries[0].strip()
            groups: list[str] = []
            current = ""
            for value in summaries:
                for start in range(0, len(value), MAX_SUMMARY_INPUT_CHARS):
                    part = value[start : start + MAX_SUMMARY_INPUT_CHARS]
                    if current and len(current) + len(part) + 2 > MAX_SUMMARY_INPUT_CHARS:
                        groups.append(current)
                        current = ""
                    current = f"{current}\n\n{part}".strip() if current else part
            if current:
                groups.append(current)
            if len(groups) >= len(summaries):
                raise ValueError("summary did not converge")
            summaries = self._summarize_all(groups)
            if not all(isinstance(value, str) and value.strip() for value in summaries):
                raise ValueError("summary returned no text")
        raise ValueError("summary exceeded bounded synthesis rounds")

    def _summarize_all(self, texts: list[str]) -> list[str]:
        """Summarize one synthesis round.

        Only the round that produces the single remaining summary asks for the
        structured form. Intermediate rounds stay plain so the headings are
        written once, over the whole meeting.
        """
        mode = "final" if len(texts) == 1 else "section"
        return [self._summarize(text, mode) for text in texts]

    def _summarize(self, text: str, mode: str) -> str:
        if self.summarize is None:
            raise RuntimeError("summary unavailable")
        if self._summarize_takes_mode:
            return self.summarize(text, mode=mode)
        return self.summarize(text)

    def _apply_auto_title(self, session_id: str, summary: str) -> None:
        """Name a meeting that was started without a title.

        A title the person typed is never replaced, and a failure here never
        fails ``end``; the meeting keeps its default name.
        """
        try:
            with self._connect() as db:
                row = db.execute(
                    "SELECT title_source FROM meeting_sessions WHERE id=?", (session_id,)
                ).fetchone()
            if row is None or row[0] != "default":
                return
            title = self._auto_title(session_id, summary)
            if not title:
                return
            with self._connect() as db:
                db.execute(
                    """UPDATE meeting_sessions SET title=?,title_source='auto',updated_at=?
                       WHERE id=? AND title_source='default'""",
                    (title, time.time(), session_id),
                )
        except Exception as exc:
            logger.warning("meeting auto title failed (%s)", type(exc).__name__)

    def _auto_title(self, session_id: str, summary: str) -> str:
        # A title needs the dedicated prompt, which needs a mode-aware
        # summarizer. Without one the meeting keeps its default name.
        if not self._summarize_takes_mode:
            return ""
        with self._connect() as db:
            rows = db.execute(
                "SELECT text FROM meeting_chunks WHERE session_id=? ORDER BY offset_s,seq",
                (session_id,),
            ).fetchall()
        spoken = " ".join(
            row[0].strip() for row in rows if isinstance(row[0], str) and row[0].strip()
        )[:TITLE_TRANSCRIPT_CHARS]
        payload = f"{spoken}\n\n{summary}".strip()
        if not payload:
            return ""
        return self._clean_title(self._summarize(payload, "title"))

    @staticmethod
    def _clean_title(value: Any) -> str:
        """Reduce a model answer to one short plain title, or to nothing."""
        if not isinstance(value, str):
            return ""
        text = unicodedata.normalize("NFKC", value).replace("—", " ").replace("–", " ")
        line = next((part for part in text.splitlines() if part.strip()), "")
        line = re.sub(r"^\s*(title|meeting title)\s*[:\-]\s*", "", line, flags=re.IGNORECASE)
        line = re.sub(r"[\"'“”‘’`*#]", "", line)
        title = " ".join(line.split()[:MAX_TITLE_WORDS]).strip(" .:;,-")
        title = title[:MAX_TITLE_CHARS].strip()
        if not title or any(ord(char) < 32 or ord(char) == 127 for char in title):
            return ""
        return "" if title.casefold() == DEFAULT_TITLE.casefold() else title

    def update(self, session_id: str, *, title: Any = None, notes: Any = None,
               summary: Any = None) -> dict[str, Any]:
        """Save what the person typed. Only the named fields change."""
        session_id = self._session_id(session_id)
        updates: list[str] = []
        values: list[Any] = []
        if title is not None:
            updates.extend(("title = ?", "title_source = 'user'"))
            values.append(self._title(title))
        if notes is not None:
            updates.append("notes = ?")
            values.append(self._body(notes, "notes", MAX_NOTES_CHARS))
        if summary is not None:
            updates.extend(("summary = ?", "summary_edited = 1"))
            values.append(self._body(summary, "summary", MAX_SUMMARY_CHARS))
        if not updates:
            raise ValueError("No meeting fields to update")
        updates.append("updated_at = ?")
        values.append(time.time())
        values.append(session_id)
        with self._lock:
            with self._connect() as db:
                cursor = db.execute(
                    "UPDATE meeting_sessions SET " + ", ".join(updates) + " WHERE id = ?", values
                )
                if cursor.rowcount != 1:
                    raise ValueError("Unknown meeting session")
            self._rewrite_note(session_id)
            return self.get(session_id)["session"]

    def summarize_again(self, session_id: str) -> dict[str, Any]:
        """Re-run the summary for a finished meeting and drop the edited flag."""
        session_id = self._session_id(session_id)
        with self._lock:
            with self._connect() as db:
                row = db.execute(
                    "SELECT status FROM meeting_sessions WHERE id=?", (session_id,)
                ).fetchone()
            if row is None:
                raise ValueError("Unknown meeting session")
            if row[0] not in _ENDED_STATUSES:
                raise ValueError("Meeting has not ended")
            summary = self._make_summary(session_id)
            with self._connect() as db:
                db.execute(
                    "UPDATE meeting_sessions SET summary=?,summary_edited=0,updated_at=? WHERE id=?",
                    (summary, time.time(), session_id),
                )
            self._apply_auto_title(session_id, summary)
            self._rewrite_note(session_id)
            return self.get(session_id)["session"]

    def _rewrite_note(self, session_id: str) -> None:
        """Keep an exported Obsidian note in step with an edit.

        The note keeps its original filename. Only the content is rewritten,
        and only when the recorded path still holds a regular file.
        """
        session = self.get(session_id, limit=MAX_PAGE_SIZE)["session"]
        note_path = session.get("note_path")
        if not note_path:
            return
        destination = Path(note_path)
        if destination.is_symlink() or not destination.is_file():
            return
        session["chunks"] = self._all_chunks(session_id)
        self._atomic_write(destination, self._note_text(session, session.get("summary") or ""))

    @staticmethod
    def _note_text(session: dict[str, Any], summary: str) -> str:
        title = MeetingService._safe_title(session["title"])
        notes = (session.get("notes") or "").strip()
        lines = [
            f"<!-- undertone-session: {session['session_id']} -->",
            "",
            f"# {title}",
            "",
            f"Date: {datetime.fromtimestamp(session['started_at']).strftime('%Y-%m-%d %H:%M')}",
            "",
        ]
        if notes:
            # The person's own words. The exporter copies them, never rewrites them.
            lines += ["## Notes", "", notes, ""]
        lines += [
            summary,
            "",
            "## Transcript",
            "",
        ]
        for chunk in sorted(session["chunks"], key=lambda item: (item["offset_s"], item["seq"])):
            lines.append(f"[{chunk['offset_s']:.3f}] **{chunk['speaker']}**: {chunk['text'] or ''}")
        return "\n".join(lines) + "\n"

    def _all_chunks(self, session_id: str) -> list[dict[str, Any]]:
        with self._connect() as db:
            rows = db.execute(
                """SELECT seq,source_path,offset_s,duration_s,speaker,voice_activity,status,text,stt_ms,error_code,retained_path
                   FROM meeting_chunks WHERE session_id=? ORDER BY offset_s,seq""",
                (session_id,),
            ).fetchall()
        return [
            {
                "seq": value[0], "source_path": value[1], "offset_s": value[2], "duration_s": value[3], "speaker": value[4],
                "voice_activity": bool(value[5]), "status": value[6], "text": value[7], "stt_ms": value[8],
                "error_code": value[9], "retained_path": value[10],
            }
            for value in rows
        ]

    @staticmethod
    def _atomic_write(destination: Path, content: str, *, replace: bool = True) -> None:
        fd, temporary_name = tempfile.mkstemp(prefix=".meeting-", suffix=".tmp", dir=destination.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as output:
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            if replace:
                os.replace(temporary_name, destination)
            else:
                # A hard-link create is atomic and fails if another writer
                # won the destination race. The caller may safely retry after
                # inspecting the exact session marker in the existing note.
                os.link(temporary_name, destination)
                os.unlink(temporary_name)
        finally:
            Path(temporary_name).unlink(missing_ok=True)

    def get(self, session_id: str, *, offset: int = 0, limit: int = MAX_PAGE_SIZE) -> dict[str, Any]:
        session_id = self._session_id(session_id)
        if not isinstance(offset, int) or isinstance(offset, bool) or not 0 <= offset:
            raise ValueError("Invalid meeting page offset")
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= MAX_PAGE_SIZE:
            raise ValueError("Invalid meeting page size")
        with self._lock, self._connect() as db:
            row = db.execute(
                f"SELECT {_SESSION_FIELDS} FROM meeting_sessions WHERE id=?",
                (session_id,),
            ).fetchone()
            if row is None:
                raise ValueError("Unknown meeting session")
            count = db.execute("SELECT COUNT(*) FROM meeting_chunks WHERE session_id=?", (session_id,)).fetchone()[0]
            rows = db.execute(
                """SELECT seq,source_path,offset_s,duration_s,speaker,voice_activity,status,text,stt_ms,error_code,retained_path
                   FROM meeting_chunks WHERE session_id=? ORDER BY seq LIMIT ? OFFSET ?""",
                (session_id, limit, offset),
            ).fetchall()
            chunks = [
                {
                    "seq": value[0], "source_path": value[1], "offset_s": value[2], "duration_s": value[3], "speaker": value[4],
                    "voice_activity": bool(value[5]), "status": value[6], "text": value[7], "stt_ms": value[8],
                    "error_code": value[9], "retained_path": value[10],
                }
                for value in rows
            ]
            session = {
                "session_id": row[0], "title": row[1], "started_at": row[2], "ended_at": row[3],
                "status": row[4], "summary": row[5], "note_path": row[6], "transcript_path": row[7],
                "notes": row[8] or "", "title_source": row[9] or "user",
                "summary_edited": bool(row[10]), "updated_at": row[11],
                "chunk_count": count, "chunks": chunks,
            }
            next_offset = offset + len(chunks) if offset + len(chunks) < count else None
            return {"session": session, "next_offset": next_offset}

    def list_sessions(self, limit: int = MAX_PAGE_SIZE) -> list[dict[str, Any]]:
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= MAX_PAGE_SIZE:
            raise ValueError("Invalid meeting list limit")
        with self._lock, self._connect() as db:
            rows = db.execute(
                f"""SELECT {_SESSION_FIELDS}
                   FROM meeting_sessions ORDER BY started_at DESC, id DESC LIMIT ?""",
                (limit,),
            ).fetchall()
            sessions: list[dict[str, Any]] = []
            for row in rows:
                count = db.execute(
                    "SELECT COUNT(*) FROM meeting_chunks WHERE session_id=?", (row[0],)
                ).fetchone()[0]
                title, summary, notes = row[1], row[5] or "", row[8] or ""
                sessions.append({
                    "session_id": row[0], "title": title, "started_at": row[2],
                    "ended_at": row[3], "status": row[4], "summary": summary[:300],
                    "note_path": row[6], "transcript_path": row[7],
                    "notes": notes[:200], "title_source": row[9] or "user",
                    "summary_edited": bool(row[10]), "updated_at": row[11],
                    "chunk_count": count,
                    "search_text": self._search_text(title, summary, notes),
                })
            return sessions

    @staticmethod
    def _search_text(title: str, summary: str, notes: str) -> str:
        """One lowercased haystack so the app can filter without another call."""
        return " ".join(part for part in (title, summary, notes) if part).lower()
