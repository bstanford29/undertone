from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from undertone import dictionary, history, learning


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

    def test_accepted_suggestion_transfers_same_term_ownership(self):
        row_id = self._row()
        learned = learning.auto_learn("Valora", "Velora", row_id, "com.example.editor", enabled=True)
        suggestion = learning.propose("Valora", "Velora", row_id, "com.example.editor")
        self.assertEqual(learning.act(suggestion["id"], "add")["status"], "added")
        self.assertEqual(learning.act(suggestion["id"], "add")["status"], "added")
        self.assertEqual(learning.undo(learned["action_id"])["status"], "superseded")
        self.assertIn("Velora", dictionary.load_dictionary()["terms"])

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


if __name__ == "__main__":
    unittest.main()
