from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from undertone import history


class HistoryTests(unittest.TestCase):
    def test_existing_database_retains_rows_and_records_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.sqlite"
            with sqlite3.connect(path) as db:
                db.execute("CREATE TABLE dictations (id INTEGER PRIMARY KEY, ts REAL, app_bundle_id TEXT, raw_text TEXT, clean_text TEXT, stt_ms REAL, llm_ms REAL, insert_ms REAL, total_ms REAL, insert_mode TEXT, audio_seconds REAL)")
                db.execute("INSERT INTO dictations (id, ts, raw_text) VALUES (1, 1, 'Existing dictation')")
            with patch.object(history, "HISTORY_DIR", Path(directory)), patch.object(history, "HISTORY_PATH", path):
                row_id = history.record("New words", "New words.", 1, 2, 0, 3, "skipped", 1, "test.app", True, "test-model")
                self.assertEqual(row_id, 2)
                with history._connect() as db:
                    rows = db.execute("SELECT raw_text, guard_fired, model FROM dictations ORDER BY id").fetchall()
                self.assertEqual(rows, [("Existing dictation", 0, None), ("New words", 1, "test-model")])


if __name__ == "__main__":
    unittest.main()
