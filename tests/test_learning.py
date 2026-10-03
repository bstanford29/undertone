from __future__ import annotations

import multiprocessing as mp
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from undertone import dictionary, history, learning


def _configure_learning_process(root):
    """Point a spawned worker at the test's synthetic stores."""
    root = Path(root)
    history.HISTORY_DIR = root
    history.HISTORY_PATH = root / "history.sqlite"
    dictionary.DICTIONARY_DIR = root
    dictionary.DICTIONARY_PATH = root / "dictionary.yaml"


def _auto_learn_race_worker(root, row_id, ready, release, results):
    try:
        _configure_learning_process(root)

        def gated_load():
            data = dictionary._load_dictionary()
            ready.set()
            if not release.wait(10):
                raise TimeoutError("race release timed out")
            return data

        dictionary.load_dictionary = gated_load
        results.put(
            ("auto", learning.auto_learn(
                "Valora", "Velora", row_id, "com.example.editor",
                enabled=True, client_token="race-auto-token",
            ))
        )
    except BaseException as exc:  # pragma: no cover - surfaced by parent assertion
        results.put(("auto_error", repr(exc)))


def _explicit_add_race_worker(root, started, results):
    try:
        _configure_learning_process(root)
        started.set()
        results.put(("manual", learning.add_explicit_term("VELORA")))
    except BaseException as exc:  # pragma: no cover - surfaced by parent assertion
        results.put(("manual_error", repr(exc)))


class LearningTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.patches = [
            patch.object(history, "HISTORY_DIR", root),
            patch.object(history, "HISTORY_PATH", root / "history.sqlite"),
            patch.object(dictionary, "DICTIONARY_DIR", root),
            patch.object(dictionary, "DICTIONARY_PATH", root / "dictionary.yaml"),
        ]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def _row(self, app="com.example.editor"):
        return history.record("produced", "replacement", 0, 0, 0, 0, "ax", 1, app)

    def test_propose_requires_history_row_to_belong_to_request_app(self):
        row_id = self._row()
        with self.assertRaises(ValueError):
            learning.propose("wrong", "right", row_id, "com.example.other")
        self.assertEqual(learning.list_suggestions(), [])

    def test_propose_is_bounded_and_duplicate_suppressed(self):
        row_id = self._row()
        suggestion = learning.propose("Priya", "Priya Vale", row_id, "com.example.editor")
        self.assertEqual(suggestion["reason"], "post_insert_edit")
        self.assertIsNone(learning.propose("Priya", "Priya Vale", row_id, "com.example.editor"))
        self.assertEqual(len(learning.list_suggestions()), 1)
        with self.assertRaises(ValueError):
            learning.propose("x" * 201, "right", row_id, "com.example.editor")
        with self.assertRaises(ValueError):
            learning.propose("one two three four five six seven eight nine ten eleven twelve thirteen", "right", row_id, "com.example.editor")

    def test_ignore_and_never_ask_persist_without_writing_dictionary(self):
        row_id = self._row()
        first = learning.propose("old", "new", row_id, "com.example.editor")
        second = learning.propose("other", "newer", row_id, "com.example.editor")
        with patch.object(dictionary, "add_term") as add_term:
            self.assertEqual(learning.act(first["id"], "ignore")["status"], "ignored")
            self.assertEqual(learning.act(second["id"], "never_ask")["status"], "never_ask")
        add_term.assert_not_called()
        self.assertEqual(learning.list_suggestions(), [])
        self.assertIsNone(learning.propose("other", "different", row_id, "com.example.editor"))

    def test_add_is_the_only_action_that_writes_dictionary_and_is_idempotent(self):
        row_id = self._row()
        suggestion = learning.propose("old", "new", row_id, "com.example.editor")
        with patch.object(dictionary, "add_term") as add_term:
            self.assertEqual(learning.act(suggestion["id"], "add")["status"], "added")
            self.assertEqual(learning.act(suggestion["id"], "add")["status"], "added")
        add_term.assert_called_once_with("new")
        self.assertEqual(learning.list_suggestions(), [])

    def test_auto_learn_is_disabled_without_touching_dictionary(self):
        row_id = self._row()
        result = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=False)
        self.assertEqual(result["status"], "disabled")
        self.assertNotIn("Velora", dictionary.load_dictionary()["terms"])

    def test_auto_learn_returns_one_action_and_undo_removes_only_that_term(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        self.assertEqual(learned["status"], "learned")
        self.assertIsInstance(learned["action_id"], int)
        self.assertEqual(learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)["status"], "already_known")
        self.assertIn("Velora", dictionary.load_dictionary()["terms"])

        undone = learning.undo(learned["action_id"])
        self.assertEqual(undone["status"], "removed")
        self.assertNotIn("Velora", dictionary.load_dictionary()["terms"])
        self.assertEqual(learning.undo(learned["action_id"])["status"], "undone")

    def test_auto_learn_dictionary_failure_leaves_recoverable_action(self):
        row_id = self._row()
        original_add_term = dictionary.add_term

        def save_then_fail(term):
            original_add_term(term)
            raise OSError("synthetic dictionary failure")

        with patch.object(dictionary, "add_term", side_effect=save_then_fail):
            with self.assertRaises(OSError):
                learning.auto_learn(
                    "Valora", "Velora", row_id, "com.example.editor", enabled=True,
                    client_token="recovery-token",
                )

        resolved = learning.lookup("recovery-token")
        self.assertEqual(resolved["status"], "learned")
        self.assertEqual(resolved["action_status"], "active")
        self.assertIn("Velora", dictionary.load_dictionary()["terms"])
        self.assertEqual(learning.undo(resolved["action_id"])["status"], "removed")
        self.assertNotIn("Velora", dictionary.load_dictionary()["terms"])

    def test_auto_learn_dictionary_failure_before_write_discards_preparing_action(self):
        row_id = self._row()
        with patch.object(dictionary, "add_term", side_effect=OSError("synthetic pre-write failure")):
            with self.assertRaises(OSError):
                learning.auto_learn(
                    "Valora", "Velora", row_id, "com.example.editor", enabled=True,
                    client_token="pre-write-token",
                )

        self.assertEqual(learning.lookup("pre-write-token")["status"], "not_found")
        self.assertNotIn("Velora", dictionary.load_dictionary()["terms"])
        with history._connect() as db:
            count = db.execute(
                "SELECT COUNT(*) FROM learning_actions WHERE client_token = ?",
                ("pre-write-token",),
            ).fetchone()[0]
        self.assertEqual(count, 0)

    def test_explicit_add_supersedes_an_interrupted_preparing_action(self):
        row_id = self._row()
        with patch.object(dictionary, "add_term", side_effect=OSError("synthetic pre-write failure")):
            with self.assertRaises(OSError):
                learning.auto_learn(
                    "Valora", "Velora", row_id, "com.example.editor", enabled=True,
                    client_token="explicit-owner-token",
                )

        learning.add_explicit_term("Velora")
        resolved = learning.lookup("explicit-owner-token")
        self.assertEqual(resolved["action_status"], "superseded")
        self.assertEqual(learning.undo(resolved["action_id"])["status"], "superseded")
        self.assertIn("Velora", dictionary.load_dictionary()["terms"])

    def test_auto_learn_already_saved_term_has_no_undo_action_or_duplicate(self):
        dictionary.add_term("Qwen")
        row_id = self._row()
        result = learning.auto_learn("Quinn", "Qwen", row_id, "com.example.editor", enabled=True)
        self.assertEqual(result["status"], "already_known")
        self.assertNotIn("action_id", result)
        self.assertEqual(sum(term.casefold() == "qwen" for term in dictionary.load_dictionary()["terms"]), 1)

    def test_auto_learn_rejects_multi_word_and_wrong_history_owner(self):
        row_id = self._row()
        with self.assertRaises(ValueError):
            learning.auto_learn("Valora", "Velora Prime", row_id, "com.example.editor", enabled=True)
        with self.assertRaises(ValueError):
            learning.auto_learn("Valora", "Velora", row_id, "com.example.other", enabled=True)

    def test_undo_consumes_preserved_action_without_removing_other_owner_term(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        with history._connect() as db:
            learning._ensure_schema(db)
            db.execute(
                """INSERT INTO learning_actions
                   (produced, term, term_key, row_id, app_bundle_id, created_at, status)
                   VALUES (?, ?, ?, ?, ?, ?, 'active')""",
                ("Valora", "Velora", "velora", row_id, "com.example.editor", 2.0),
            )
            second_action = db.execute("SELECT last_insert_rowid()").fetchone()[0]

        self.assertEqual(learning.undo(learned["action_id"])["status"], "preserved")
        self.assertIn("Velora", dictionary.load_dictionary()["terms"])
        self.assertEqual(learning.undo(learned["action_id"])["status"], "undone")
        self.assertIn("Velora", dictionary.load_dictionary()["terms"])
        self.assertEqual(learning.undo(second_action)["status"], "removed")
        self.assertNotIn("Velora", dictionary.load_dictionary()["terms"])

    def test_removing_term_supersedes_stale_action_before_relearning(self):
        row_id = self._row()
        first = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        dictionary.remove_term("Velora")
        second = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        self.assertEqual(second["status"], "learned")
        self.assertEqual(learning.undo(second["action_id"])["status"], "removed")
        self.assertNotIn("Velora", dictionary.load_dictionary()["terms"])
        self.assertEqual(learning.undo(first["action_id"])["status"], "superseded")
        self.assertEqual(learning.undo(first["action_id"])["status"], "superseded")

    def test_explicit_dictionary_add_transfers_recased_term_ownership(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        learning.add_explicit_term("VELORA")
        self.assertEqual(learning.undo(learned["action_id"])["status"], "superseded")
        self.assertIn("VELORA", dictionary.load_dictionary()["terms"])
        self.assertEqual(learning.undo(learned["action_id"])["status"], "superseded")

    def test_explicit_add_recovers_after_dictionary_write_interruption(self):
        row_id = self._row()
        learned = learning.auto_learn(
            "Valora", "Velora", row_id, "com.example.editor", enabled=True,
            client_token="manual-owner-token",
        )
        original_add_term = dictionary.add_term

        def save_then_fail(term):
            original_add_term(term)
            raise OSError("synthetic post-write failure")

        with patch.object(dictionary, "add_term", side_effect=save_then_fail):
            with self.assertRaises(OSError):
                learning.add_explicit_term("VELORA")

        with history._connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM dictionary_writes").fetchone()[0], 1)
        learning.recover_pending_dictionary_writes()
        self.assertEqual(learning.lookup("manual-owner-token")["action_status"], "superseded")
        self.assertEqual(learning.undo(learned["action_id"])["status"], "superseded")
        self.assertIn("VELORA", dictionary.load_dictionary()["terms"])
        with history._connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM dictionary_writes").fetchone()[0], 0)

    def test_recovered_explicit_add_supersedes_newer_automatic_action(self):
        row_id = self._row()
        with patch.object(dictionary, "add_term", side_effect=OSError("synthetic pre-write failure")):
            with self.assertRaises(OSError):
                learning.add_explicit_term("Velora")

        learned = learning.auto_learn(
            "Valora", "Velora", row_id, "com.example.editor", enabled=True,
            client_token="newer-auto-action",
        )
        learning.recover_pending_dictionary_writes()

        self.assertEqual(learning.lookup("newer-auto-action")["action_status"], "superseded")
        self.assertEqual(learning.undo(learned["action_id"])["status"], "superseded")
        self.assertIn("Velora", dictionary.load_dictionary()["terms"])

    def test_explicit_remove_cancels_matching_pending_dictionary_write(self):
        dictionary.add_term("TransientTerm")
        with history._connect() as db:
            learning._ensure_schema(db)
            db.execute(
                "INSERT INTO dictionary_writes (term, created_at) VALUES (?, ?)",
                ("TransientTerm", 1.0),
            )

        learning.remove_explicit_term("transientterm")
        learning.recover_pending_dictionary_writes()
        self.assertNotIn("TransientTerm", dictionary.load_dictionary()["terms"])
        with history._connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM dictionary_writes").fetchone()[0], 0)

    def test_undo_recovers_pending_manual_owner_before_removing_term(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        with history._connect() as db:
            learning._ensure_schema(db)
            db.execute(
                "INSERT INTO dictionary_writes (term, created_at) VALUES (?, ?)",
                ("VELORA", 1.0),
            )

        self.assertEqual(learning.undo(learned["action_id"])["status"], "superseded")
        self.assertIn("VELORA", dictionary.load_dictionary()["terms"])
        with history._connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM dictionary_writes").fetchone()[0], 0)

    def test_accepted_suggestion_transfers_same_term_ownership(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        suggestion = learning.propose("Valora", "Velora", row_id, "com.example.editor")
        self.assertEqual(learning.act(suggestion["id"], "add")["status"], "added")
        self.assertEqual(learning.act(suggestion["id"], "add")["status"], "added")
        self.assertEqual(learning.undo(learned["action_id"])["status"], "superseded")
        self.assertIn("Velora", dictionary.load_dictionary()["terms"])

    def test_accepted_suggestion_recovers_journaled_dictionary_write(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        suggestion = learning.propose("Valora", "VELORA", row_id, "com.example.editor")
        original_add_term = dictionary.add_term

        def save_then_fail(term):
            original_add_term(term)
            raise OSError("synthetic suggestion post-write failure")

        with patch.object(dictionary, "add_term", side_effect=save_then_fail):
            with self.assertRaises(OSError):
                learning.act(suggestion["id"], "add")

        self.assertEqual(learning.act(suggestion["id"], "add")["status"], "added")
        self.assertEqual(learning.undo(learned["action_id"])["status"], "superseded")
        self.assertIn("VELORA", dictionary.load_dictionary()["terms"])

    def test_explicit_unrelated_add_preserves_other_action_and_is_idempotent(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        learning.add_explicit_term("Qwen")
        learning.add_explicit_term("qwen")
        self.assertEqual(learning.undo(learned["action_id"])["status"], "removed")
        terms = dictionary.load_dictionary()["terms"]
        self.assertEqual(sum(term.casefold() == "qwen" for term in terms), 1)
        self.assertNotIn("Velora", terms)

    def test_auto_learn_client_token_is_idempotent_and_lookup_resolves(self):
        row_id = self._row()
        first = learning.auto_learn(
            "Valora", "Velora", row_id, "com.example.editor", enabled=True,
            client_token="velora-token",
        )
        self.assertEqual(first["action_status"], "active")
        second = learning.auto_learn(
            "Valora", "Velora", row_id, "com.example.editor", enabled=True,
            client_token="velora-token",
        )
        self.assertEqual(second["action_id"], first["action_id"])
        resolved = learning.lookup("velora-token")
        self.assertEqual(resolved["status"], "learned")
        self.assertEqual(resolved["action_id"], first["action_id"])
        self.assertEqual(resolved["term"], "Velora")

    def test_learning_lookup_rejects_unknown_or_invalid_tokens(self):
        self.assertEqual(learning.lookup("missing-token")["status"], "not_found")
        with self.assertRaises(ValueError):
            learning.lookup("bad token")
        with self.assertRaises(ValueError):
            learning.lookup("x" * (learning.MAX_CLIENT_TOKEN_CHARS + 1))

    def test_learning_schema_migrates_actions_without_client_token(self):
        with history._connect() as db:
            db.execute(
                """CREATE TABLE learning_actions (
                   id INTEGER PRIMARY KEY AUTOINCREMENT,
                   produced TEXT NOT NULL, term TEXT NOT NULL, term_key TEXT NOT NULL,
                   row_id INTEGER NOT NULL, app_bundle_id TEXT NOT NULL,
                   created_at REAL NOT NULL, status TEXT NOT NULL DEFAULT 'active'
                )"""
            )
        self.assertEqual(learning.lookup("legacy-token")["status"], "not_found")
        with history._connect() as db:
            columns = {row[1] for row in db.execute("PRAGMA table_info(learning_actions)")}
        self.assertIn("client_token", columns)

    def test_undo_reports_absent_when_manual_removal_left_no_term(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        dictionary.remove_term("Velora")
        self.assertEqual(learning.undo(learned["action_id"])["status"], "absent")

    def _assert_manual_handoff_preserves_term(self, *, suggestion):
        row_id = self._row()
        pending = learning.propose("Valora", "VELORA", row_id, "com.example.editor") if suggestion else None
        original_begin = learning._begin_ownership_transaction
        calls = 0

        def interleave_after_journal(db):
            nonlocal calls
            calls += 1
            if calls == 2:
                # The durable manual journal releases its first writer lock.
                # A separate connection now represents auto-learn phase one.
                db.commit()
                with history._connect() as competing:
                    competing.execute(
                        """INSERT INTO learning_actions
                           (produced, term, term_key, row_id, app_bundle_id,
                            created_at, client_token, status)
                           VALUES (?, ?, ?, ?, ?, ?, ?, 'preparing')""",
                        ("Valora", "Velora", "velora", row_id, "com.example.editor",
                         1.0, "manual-handoff-token"),
                    )
            original_begin(db)

        with patch.object(learning, "_begin_ownership_transaction", side_effect=interleave_after_journal):
            if suggestion:
                learning.act(pending["id"], "add")
            else:
                learning.add_explicit_term("VELORA")
        self.assertEqual(calls, 2)
        resolved = learning.lookup("manual-handoff-token")
        self.assertEqual(resolved["action_status"], "superseded")
        self.assertEqual(learning.undo(resolved["action_id"])["status"], "superseded")
        self.assertEqual(dictionary.load_dictionary()["terms"][0], "VELORA")

    def test_explicit_add_supersedes_auto_action_created_during_journal_handoff(self):
        self._assert_manual_handoff_preserves_term(suggestion=False)

    def test_suggestion_add_supersedes_auto_action_created_during_journal_handoff(self):
        self._assert_manual_handoff_preserves_term(suggestion=True)

    def test_auto_learn_cannot_claim_concurrent_explicit_add(self):
        """A concurrent explicit addition remains user-owned across auto handoff."""
        row_id = self._row()
        context = mp.get_context("spawn")
        ready = context.Event()
        release = context.Event()
        manual_started = context.Event()
        results = context.Queue()
        root = str(self.temporary.name)
        auto = context.Process(
            target=_auto_learn_race_worker,
            args=(root, row_id, ready, release, results),
        )
        manual = context.Process(
            target=_explicit_add_race_worker,
            args=(root, manual_started, results),
        )
        def stop_workers():
            release.set()
            for worker in (auto, manual):
                if worker.pid is not None:
                    worker.join(2)
                    if worker.is_alive():
                        worker.terminate()
                        worker.join(2)
            results.close()
            results.join_thread()

        self.addCleanup(stop_workers)
        auto.start()
        self.assertTrue(ready.wait(5), "auto worker did not reach the gated absence read")
        # No competing writer can claim the term while absence is being read.
        # This assertion deterministically fails on the pre-fix implementation.
        with sqlite3.connect(Path(root) / "history.sqlite", timeout=0) as competing:
            with self.assertRaisesRegex(sqlite3.OperationalError, "locked"):
                competing.execute("BEGIN IMMEDIATE")
        manual.start()
        self.assertTrue(manual_started.wait(5), "manual worker did not start")
        release.set()
        auto.join(10)
        manual.join(10)
        self.assertFalse(auto.is_alive())
        self.assertFalse(manual.is_alive())
        messages = [results.get(timeout=2) for _ in range(2)]
        errors = [message for message in messages if message[0].endswith("_error")]
        self.assertEqual(errors, [])
        auto_result = next(message[1] for message in messages if message[0] == "auto")
        self.assertEqual(auto_result["status"], "learned")
        self.assertEqual(learning.lookup("race-auto-token")["action_status"], "superseded")
        self.assertEqual(dictionary.load_dictionary()["terms"][0], "VELORA")
        self.assertEqual(learning.undo(auto_result["action_id"])["status"], "superseded")
        self.assertIn("VELORA", dictionary.load_dictionary()["terms"])


if __name__ == "__main__":
    unittest.main()
