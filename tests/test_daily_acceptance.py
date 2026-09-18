from __future__ import annotations
import datetime as dt
import importlib.util
from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('daily_acceptance', Path(__file__).resolve().parents[1] / 'bench/daily_acceptance.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class DailyAcceptanceTests(unittest.TestCase):
    def test_requires_fourteen_consecutive_days_and_no_failed_or_guarded_rows(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'history.sqlite'
            start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE dictations(ts REAL,insert_mode TEXT,guard_fired INTEGER,total_ms REAL,kind TEXT)')
                for day in range(14):
                    db.execute('INSERT INTO dictations VALUES(?,?,?,?,?)', ((start + dt.timedelta(days=day)).timestamp(), 'ax', 0, 700, 'dictation'))
            self.assertTrue(module.audit(path, start, start+dt.timedelta(days=15))['trial_evidence_pass'])
            with sqlite3.connect(path) as db: db.execute("UPDATE dictations SET insert_mode='failed' WHERE ts=?", (start.timestamp(),))
            self.assertFalse(module.audit(path, start, start+dt.timedelta(days=15))['trial_evidence_pass'])
            with sqlite3.connect(path) as db: db.execute('DELETE FROM dictations WHERE ts=?', ((start+dt.timedelta(days=5)).timestamp(),))
            self.assertEqual(module.audit(path, start, start+dt.timedelta(days=15))['longest_consecutive_days'], 8)

    def test_mode_buckets_are_disjoint(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'history.sqlite'
            start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
            with closing(sqlite3.connect(path)) as db:
                db.execute('CREATE TABLE dictations(ts REAL,insert_mode TEXT,guard_fired INTEGER,total_ms REAL,kind TEXT)')
                db.executemany(
                    'INSERT INTO dictations VALUES(?,?,?,?,?)',
                    [
                        (start.timestamp(), 'ax', 0, 700, 'dictation'),
                        ((start + dt.timedelta(hours=1)).timestamp(), 'paste', 0, 700, 'dictation'),
                        ((start + dt.timedelta(hours=2)).timestamp(), 'failed', 0, 700, 'dictation'),
                    ],
                )
                db.commit()
            day = module.audit(path, start, start + dt.timedelta(days=1))['days'][start.date().isoformat()]
            self.assertEqual(day['dictations'], 3)
            self.assertEqual(day['inserted'], 1)
            self.assertEqual(day['paste'], 1)
            self.assertEqual(day['unverified_insertions'], 1)

    def test_missing_schema_has_clear_error(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'history.sqlite'
            with closing(sqlite3.connect(path)) as db:
                db.commit()
            start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
            with self.assertRaisesRegex(ValueError, 'missing the dictations table') as error:
                module.audit(path, start, start + dt.timedelta(days=1))
            self.assertNotIn('OperationalError', str(error.exception))

    def test_missing_kind_column_fails_closed(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'history.sqlite'
            with closing(sqlite3.connect(path)) as db:
                db.execute('CREATE TABLE dictations(ts REAL,insert_mode TEXT,guard_fired INTEGER,total_ms REAL)')
                db.commit()
            start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
            with self.assertRaisesRegex(ValueError, 'missing required dictations columns: kind'):
                module.audit(path, start, start + dt.timedelta(days=1))

    def test_read_only_connection_is_explicitly_closed(self):
        class Cursor:
            def __init__(self, rows):
                self.rows = rows

            def __iter__(self):
                return iter(self.rows)

            def fetchall(self):
                return self.rows

        class Connection:
            def __init__(self):
                self.closed = False

            def execute(self, sql, params=()):
                if sql.startswith('PRAGMA'):
                    return Cursor([(0, 'ts'), (1, 'insert_mode'), (2, 'guard_fired'), (3, 'total_ms'), (4, 'kind')])
                return Cursor([])

            def close(self):
                self.closed = True

        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'history.sqlite'
            path.touch()
            connection = Connection()
            start = dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc)
            with patch.object(module.sqlite3, 'connect', return_value=connection):
                module.audit(path, start, start + dt.timedelta(days=1))
            self.assertTrue(connection.closed)
