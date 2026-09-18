from __future__ import annotations

import json
import os
import sqlite3
import tempfile
import unittest
from datetime import datetime
from pathlib import Path

from undertone.meeting import (
    MAX_NOTES_CHARS,
    MAX_SUMMARY_CHARS,
    MAX_SUMMARY_SECTION_CHARS,
    MAX_TITLE_CHARS,
    MeetingService,
)

# The original meeting_sessions shape, before notes, title_source,
# summary_edited, and updated_at existed.
LEGACY_SCHEMA = """
CREATE TABLE meeting_sessions (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    started_at REAL NOT NULL,
    ended_at REAL,
    status TEXT NOT NULL,
    summary TEXT,
    note_path TEXT,
    transcript_path TEXT NOT NULL
);
CREATE TABLE meeting_chunks (
    session_id TEXT NOT NULL REFERENCES meeting_sessions(id),
    seq INTEGER NOT NULL,
    source_path TEXT NOT NULL,
    retained_path TEXT NOT NULL,
    speaker TEXT NOT NULL,
    offset_s REAL NOT NULL,
    duration_s REAL NOT NULL,
    status TEXT NOT NULL,
    text TEXT,
    stt_ms REAL,
    error_code TEXT,
    created_at REAL NOT NULL,
    PRIMARY KEY (session_id, seq)
);
"""


class MeetingFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.database = root / "meeting.sqlite"
        self.audio_root = root / "retained"
        self.source = root / "source.wav"
        self.source.write_bytes(b"synthetic audio")

    def service(self, *, transcribe=None, summarize=None):
        return MeetingService(
            self.database, self.audio_root,
            transcribe=transcribe or (lambda path: "Synthetic transcript"),
            summarize=summarize or (lambda section: "Synthetic summary"),
        )

    def add_chunk(self, service, session_id, seq=0, **kwargs):
        values = {"audio_path": str(self.source), "speaker": "me", "offset_s": float(seq * 10), "duration_s": 10.0}
        values.update(kwargs)
        audio_path = values.pop("audio_path")
        return service.chunk(session_id, seq, audio_path, **values)


class MeetingTests(MeetingFixture):
    def test_chunk_is_retained_and_row_is_saved_before_transcription(self):
        seen = {}

        def transcribe(path):
            with self.service_instance._connect() as db:
                seen["status"] = db.execute(
                    "SELECT status FROM meeting_chunks WHERE seq=0"
                ).fetchone()[0]
            seen["path"] = Path(path)
            return "Me said this"

        self.service_instance = self.service(transcribe=transcribe)
        session = self.service_instance.start("Team sync")
        response = self.add_chunk(self.service_instance, session["session_id"])
        self.assertEqual(seen["status"], "pending")
        self.assertEqual(response["status"], "complete")
        self.assertTrue(seen["path"].is_file())
        self.assertEqual(seen["path"].read_bytes(), self.source.read_bytes())
        self.assertEqual(os.stat(seen["path"]).st_mode & 0o777, 0o600)
        fetched = self.service_instance.get(session["session_id"])
        self.assertEqual(fetched["session"]["chunks"][0]["text"], "Me said this")
        line = Path(fetched["session"]["transcript_path"]).read_text().strip()
        self.assertEqual(json.loads(line)["speaker"], "me")

    def test_database_context_commits_and_closes_connections(self):
        service = self.service()
        connection = None
        with service._connect() as db:
            connection = db
            db.execute(
                "INSERT INTO meeting_sessions (id,title,started_at,status,transcript_path) VALUES (?,?,?,?,?)",
                ("session01", "Synthetic", 0, "recording", "/tmp/synthetic.ndjson"),
            )
        self.assertIsNotNone(connection)
        with self.assertRaises(sqlite3.ProgrammingError):
            connection.execute("SELECT 1")
        with service._connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM meeting_sessions").fetchone()[0], 1)

        with self.assertRaises(RuntimeError):
            with service._connect() as db:
                db.execute("DELETE FROM meeting_sessions WHERE id = ?", ("session01",))
                raise RuntimeError("rollback fixture")
        with service._connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM meeting_sessions").fetchone()[0], 1)

    def test_retained_audio_creation_rejects_symlink_destination(self):
        service = self.service()
        session_id = service.start()["session_id"]
        destination = self.audio_root / session_id / "000000-me.wav"
        destination.symlink_to(self.source)
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id)
        self.assertTrue(destination.is_symlink())

    def test_complete_chunk_retry_is_idempotent_and_mismatch_is_rejected(self):
        calls = []
        service = self.service(transcribe=lambda path: calls.append(path) or "Once")
        session = service.start()
        session_id = session["session_id"]
        first = self.add_chunk(service, session_id)
        again = self.add_chunk(service, session_id)
        self.assertEqual(first["text"], again["text"])
        self.assertEqual(len(calls), 1)
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id, speaker="others")

    def test_materialized_transcript_and_note_are_chronological(self):
        def transcribe(path):
            return "Late" if "000000" in path else "Early"

        sections = []
        service = self.service(transcribe=transcribe, summarize=lambda section: sections.append(section) or "Summary")
        session_id = service.start("Chronological")["session_id"]
        self.add_chunk(service, session_id, seq=0, offset_s=20.0)
        self.add_chunk(service, session_id, seq=1, offset_s=10.0)
        transcript_path = service.get(session_id)["session"]["transcript_path"]
        transcript = [json.loads(line) for line in Path(transcript_path).read_text().splitlines()]
        self.assertEqual([line["timestamp"] for line in transcript], [10.0, 20.0])
        self.assertEqual([line["text"] for line in transcript], ["Early", "Late"])

        vault = Path(self.temporary.name) / "vault"
        vault.mkdir()
        result = service.end(session_id, vault_path=vault)
        note = Path(result["note_path"]).read_text()
        self.assertLess(note.index("[10.000]"), note.index("[20.000]"))
        self.assertLess(sections[0].index("[10.000]"), sections[0].index("[20.000]"))

    def test_quiet_chunk_is_retained_without_transcription_and_flag_is_idempotent(self):
        calls = []
        service = self.service(transcribe=lambda path: calls.append(path) or "must not run")
        session_id = service.start()["session_id"]
        response = self.add_chunk(service, session_id, voice_activity=False)
        self.assertEqual(response["status"], "complete")
        self.assertEqual(response["text"], "")
        self.assertFalse(response["voice_activity"])
        self.assertEqual(calls, [])
        again = self.add_chunk(service, session_id, voice_activity=False)
        self.assertFalse(again["voice_activity"])
        fetched = service.get(session_id)["session"]["chunks"][0]
        self.assertFalse(fetched["voice_activity"])
        self.assertEqual(fetched["status"], "complete")
        ndjson = Path(service.get(session_id)["session"]["transcript_path"]).read_text().strip()
        self.assertFalse(json.loads(ndjson)["text"])
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id, voice_activity=True)

    def test_voice_activity_must_be_boolean(self):
        service = self.service()
        session_id = service.start()["session_id"]
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id, voice_activity="false")

    def test_failed_transcription_retains_audio_and_exact_retry_can_recover(self):
        calls = []

        def transcribe(path):
            calls.append(path)
            if len(calls) == 1:
                raise RuntimeError("synthetic failure")
            return "Recovered transcript"

        service = self.service(transcribe=transcribe)
        session_id = service.start()["session_id"]
        first = self.add_chunk(service, session_id)
        self.assertEqual(first["error_code"], "stt_failed")
        chunk = service.get(session_id)["session"]["chunks"][0]
        retained = Path(chunk["retained_path"])
        self.assertEqual(chunk["source_path"], str(self.source))
        self.assertTrue(retained.exists())
        self.source.unlink()
        recovered = service.chunk(
            session_id, 0, chunk["source_path"], "me", chunk["offset_s"], chunk["duration_s"],
            voice_activity=chunk["voice_activity"],
        )
        self.assertEqual(recovered["text"], "Recovered transcript")
        self.assertEqual(Path(calls[1]), retained)
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id, duration_s=9.0)

    def test_sequence_speaker_and_path_bounds_are_enforced(self):
        service = self.service()
        session_id = service.start()["session_id"]
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id, seq=1)
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id, speaker="unknown")
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id, duration_s=121.0)
        with self.assertRaises(ValueError):
            self.add_chunk(service, session_id, audio_path="relative.wav")

    def test_missing_vault_saves_summary_locally_and_export_reuses_it(self):
        called = []
        service = self.service(summarize=lambda section: called.append(section) or "summary")
        session_id = service.start("Vaultless")["session_id"]
        self.add_chunk(service, session_id)
        result = service.end(session_id)
        self.assertEqual(result["status"], "needs_vault")
        self.assertTrue(result["needs_vault"])
        self.assertEqual(len(called), 1)
        self.assertEqual(result["summary"], "summary")
        self.assertIsNotNone(result["ended_at"])
        self.assertIsNone(result["note_path"])
        ended_at = result["ended_at"]
        self.assertEqual(service.end(session_id)["summary"], "summary")
        vault = Path(self.temporary.name) / "vault"
        vault.mkdir()
        exported = service.end(session_id, vault_path=vault)
        self.assertEqual(exported["status"], "ended")
        self.assertEqual(exported["ended_at"], ended_at)
        self.assertTrue(Path(exported["note_path"]).is_file())
        self.assertEqual(len(called), 1)

    def test_summary_and_note_retain_all_chunks_and_bound_summary_sections(self):
        sections = []
        service = self.service(summarize=lambda section: sections.append(section) or "Section summary")
        session_id = service.start("../Quarterly: sync")["session_id"]
        for seq in range(105):
            self.add_chunk(service, session_id, seq=seq, speaker="me" if seq % 2 == 0 else "others")
        vault = Path(self.temporary.name) / "vault"
        vault.mkdir()
        result = service.end(session_id, vault_path=vault)
        self.assertEqual(result["status"], "ended")
        self.assertEqual(len(sections), 1)
        self.assertLessEqual(max(map(len, sections)), MAX_SUMMARY_SECTION_CHARS)
        note = Path(result["note_path"])
        self.assertTrue(note.is_file())
        self.assertIn("# Quarterly_ sync", note.read_text())
        self.assertNotIn("..", note.name)
        self.assertEqual(note.read_text().count("Synthetic transcript"), 105)
        self.assertIn(session_id[:8], note.name)

    def test_summary_failure_retains_session_and_retry_exports_atomically(self):
        attempts = []

        def summarize(section):
            attempts.append(section)
            if len(attempts) == 1:
                raise RuntimeError("synthetic summary failure")
            return "Recovered summary"

        service = self.service(summarize=summarize)
        session_id = service.start()["session_id"]
        self.add_chunk(service, session_id)
        vault = Path(self.temporary.name) / "vault"
        vault.mkdir()
        failed = service.end(session_id, vault_path=vault)
        self.assertEqual(failed["status"], "summary_failed")
        self.assertIsNone(failed["note_path"])
        self.assertEqual(service.get(session_id)["session"]["chunk_count"], 1)
        recovered = service.end(session_id, vault_path=vault)
        self.assertEqual(recovered["status"], "ended")
        self.assertEqual(Path(recovered["note_path"]).read_text().count("Recovered summary"), 1)

    def test_expanding_summary_fails_bounded_and_retains_transcript(self):
        service = self.service(summarize=lambda section: section + ("x" * 20_000))
        session_id = service.start()["session_id"]
        self.add_chunk(service, session_id)
        vault = Path(self.temporary.name) / "vault"
        vault.mkdir()
        result = service.end(session_id, vault_path=vault)
        self.assertEqual(result["status"], "summary_failed")
        self.assertEqual(service.get(session_id)["session"]["chunk_count"], 1)
        self.assertEqual(list((vault / "Meetings").iterdir()), [])

    def test_vault_meetings_symlink_and_note_collision_are_rejected(self):
        service = self.service()
        session_id = service.start("Safe title")["session_id"]
        self.add_chunk(service, session_id)
        vault = Path(self.temporary.name) / "vault"
        vault.mkdir()
        outside = Path(self.temporary.name) / "outside"
        outside.mkdir()
        (vault / "Meetings").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(ValueError):
            service.end(session_id, vault_path=vault)

    def test_unknown_existing_note_is_never_overwritten(self):
        service = self.service()
        session = service.start("Safe title", started_at=0)
        session_id = session["session_id"]
        self.add_chunk(service, session_id)
        vault = Path(self.temporary.name) / "vault"
        meetings = vault / "Meetings"
        meetings.mkdir(parents=True)
        date = datetime.fromtimestamp(session["started_at"]).strftime("%Y-%m-%d")
        destination = meetings / f"{date} Safe title [{session_id[:8]}].md"
        destination.write_text("unrelated note")
        with self.assertRaises(ValueError):
            service.end(session_id, vault_path=vault)
        self.assertEqual(destination.read_text(), "unrelated note")


class MeetingEditingTests(MeetingFixture):
    """Editable title, notes, summary, and the generated first-pass title."""

    def mode_service(self, *, title="Quarterly budget review", summary="## Key points\n- Synthetic"):
        """A summarizer that answers each prompt mode, like the engine's does."""
        self.modes: list[str] = []

        def summarize(section, *, mode="final"):
            self.modes.append(mode)
            if mode == "title":
                return title() if callable(title) else title
            return summary

        return MeetingService(
            self.database, self.audio_root,
            transcribe=lambda path: "Synthetic transcript",
            summarize=summarize,
        )

    def vault(self):
        vault = Path(self.temporary.name) / "vault"
        vault.mkdir(exist_ok=True)
        return vault

    def test_old_database_gains_the_new_session_columns(self):
        with sqlite3.connect(self.database) as db:
            db.executescript(LEGACY_SCHEMA)
            db.execute(
                "INSERT INTO meeting_sessions (id,title,started_at,status,summary,transcript_path)"
                " VALUES (?,?,?,?,?,?)",
                ("legacysession01", "Old meeting", 10.0, "ended", "Old summary", "/tmp/old.ndjson"),
            )
        service = self.service()
        with service._connect() as db:
            columns = {row[1] for row in db.execute("PRAGMA table_info(meeting_sessions)")}
        self.assertLessEqual({"notes", "title_source", "summary_edited", "updated_at"}, columns)
        session = service.get("legacysession01")["session"]
        self.assertEqual(session["title"], "Old meeting")
        self.assertEqual(session["notes"], "")
        self.assertEqual(session["title_source"], "user")
        self.assertFalse(session["summary_edited"])
        self.assertIsNone(session["updated_at"])
        # The migration runs on every connection and must stay idempotent.
        self.assertEqual(self.service().get("legacysession01")["session"]["title"], "Old meeting")

    def test_update_changes_only_the_named_fields(self):
        service = self.service()
        session_id = service.start("Typed title")["session_id"]
        updated = service.update(session_id, notes="Jordan owns the follow up.")
        self.assertEqual(updated["notes"], "Jordan owns the follow up.")
        self.assertEqual(updated["title"], "Typed title")
        self.assertIsNone(updated["summary"])
        self.assertFalse(updated["summary_edited"])
        self.assertIsNotNone(updated["updated_at"])

        renamed = service.update(session_id, title="Budget call")
        self.assertEqual(renamed["title"], "Budget call")
        self.assertEqual(renamed["title_source"], "user")
        self.assertEqual(renamed["notes"], "Jordan owns the follow up.")

        edited = service.update(session_id, summary="## Key points\n- Mine")
        self.assertEqual(edited["summary"], "## Key points\n- Mine")
        self.assertTrue(edited["summary_edited"])
        self.assertEqual(edited["notes"], "Jordan owns the follow up.")

    def test_update_rejects_empty_and_oversized_input(self):
        service = self.service()
        session_id = service.start()["session_id"]
        with self.assertRaises(ValueError):
            service.update(session_id)
        with self.assertRaises(ValueError):
            service.update(session_id, title="   ")
        with self.assertRaises(ValueError):
            service.update(session_id, title="x" * (MAX_TITLE_CHARS + 1))
        with self.assertRaises(ValueError):
            service.update(session_id, notes="x" * (MAX_NOTES_CHARS + 1))
        with self.assertRaises(ValueError):
            service.update(session_id, summary="x" * (MAX_SUMMARY_CHARS + 1))
        with self.assertRaises(ValueError):
            service.update("unknownsession01", notes="x")
        self.assertEqual(service.get(session_id)["session"]["title"], "Meeting")

    def test_typed_title_survives_end(self):
        service = self.mode_service()
        session_id = service.start("Process flows review")["session_id"]
        self.add_chunk(service, session_id)
        result = service.end(session_id, vault_path=self.vault())
        self.assertEqual(result["title"], "Process flows review")
        self.assertEqual(result["title_source"], "user")
        self.assertNotIn("title", self.modes)

    def test_untitled_meeting_is_named_at_end(self):
        service = self.mode_service(title='"Quarterly budget review."')
        session_id = service.start()["session_id"]
        self.add_chunk(service, session_id)
        result = service.end(session_id, vault_path=self.vault())
        self.assertEqual(result["title"], "Quarterly budget review")
        self.assertEqual(result["title_source"], "auto")
        self.assertEqual(self.modes, ["final", "title"])
        self.assertIn("Quarterly budget review", Path(result["note_path"]).name)
        # A later edit still wins over the generated name.
        renamed = service.update(session_id, title="My own name")
        self.assertEqual(renamed["title_source"], "user")

    def test_failed_title_generation_keeps_the_default_name(self):
        def explode():
            raise RuntimeError("synthetic title failure")

        service = self.mode_service(title=explode)
        session_id = service.start()["session_id"]
        self.add_chunk(service, session_id)
        result = service.end(session_id, vault_path=self.vault())
        self.assertEqual(result["status"], "ended")
        self.assertEqual(result["title"], "Meeting")
        self.assertEqual(result["title_source"], "default")
        self.assertEqual(result["summary"], "## Key points\n- Synthetic")

    def test_only_the_last_summary_round_asks_for_the_structured_form(self):
        service = MeetingService(
            self.database, self.audio_root,
            transcribe=lambda path: "word " * 400,
            summarize=lambda section, *, mode="final": self.modes.append(mode) or "Round output",
        )
        self.modes = []
        session_id = service.start("Long meeting")["session_id"]
        for seq in range(10):
            self.add_chunk(service, session_id, seq=seq)
        service.end(session_id, vault_path=self.vault())
        self.assertEqual(self.modes[-1], "final")
        self.assertEqual(set(self.modes[:-1]), {"section"})
        self.assertGreater(len(self.modes), 1)

    def test_list_returns_previews_and_one_search_haystack(self):
        service = self.service(summarize=lambda section: "Y" * 400)
        first = service.start("Quarterly planning")["session_id"]
        self.add_chunk(service, first)
        service.end(first)
        service.update(first, notes="N" * 400)
        service.start("Process flows")
        sessions = service.list_sessions()
        self.assertEqual([row["title"] for row in sessions], ["Process flows", "Quarterly planning"])
        planning = sessions[1]
        self.assertEqual(len(planning["summary"]), 300)
        self.assertEqual(len(planning["notes"]), 200)
        self.assertEqual(planning["chunk_count"], 1)
        self.assertIn("quarterly planning", planning["search_text"])
        self.assertIn("n" * 400, planning["search_text"])
        self.assertIn("y" * 400, planning["search_text"])
        self.assertEqual(planning["search_text"], planning["search_text"].lower())

    def test_exported_note_keeps_notes_verbatim_and_follows_later_edits(self):
        service = self.mode_service()
        session_id = service.start("Vault meeting")["session_id"]
        self.add_chunk(service, session_id)
        service.update(session_id, notes="My own note.\nSecond line.")
        result = service.end(session_id, vault_path=self.vault())
        note = Path(result["note_path"])
        text = note.read_text(encoding="utf-8")
        self.assertIn("## Notes\n\nMy own note.\nSecond line.", text)
        self.assertLess(text.index("## Notes"), text.index("## Key points"))
        self.assertLess(text.index("## Key points"), text.index("## Transcript"))

        service.update(session_id, title="Renamed later", notes="Edited note.")
        rewritten = note.read_text(encoding="utf-8")
        self.assertIn("# Renamed later", rewritten)
        self.assertIn("Edited note.", rewritten)
        self.assertNotIn("My own note.", rewritten)
        self.assertIn("Synthetic transcript", rewritten)
        self.assertEqual([path.name for path in (self.vault() / "Meetings").iterdir()], [note.name])

    def test_resummarize_replaces_an_edited_summary_only_after_the_meeting_ends(self):
        service = self.mode_service()
        session_id = service.start("Regenerate me")["session_id"]
        self.add_chunk(service, session_id)
        with self.assertRaises(ValueError):
            service.summarize_again(session_id)
        service.end(session_id, vault_path=self.vault())
        edited = service.update(session_id, summary="Mine")
        self.assertTrue(edited["summary_edited"])
        again = service.summarize_again(session_id)
        self.assertEqual(again["summary"], "## Key points\n- Synthetic")
        self.assertFalse(again["summary_edited"])


if __name__ == "__main__":
    unittest.main()
