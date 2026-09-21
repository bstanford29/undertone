from __future__ import annotations

import json
import socket
import stat
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from undertone import config, dictionary, history, learning
from undertone import cleanup
from undertone.server import Engine, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES, Server


class ServerTests(unittest.TestCase):
    def test_duplicate_start_cannot_enter_socket_cleanup(self):
        import fcntl
        from undertone import server
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "engine.sock"
            with open(str(path) + ".lock", "w") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                with patch.object(server, "_serve_owned") as owned:
                    with self.assertRaises(RuntimeError):
                        server.serve(path)
                    owned.assert_not_called()


    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        for module, directory_name, path_name, filename in (
            (history, 'HISTORY_DIR', 'HISTORY_PATH', 'history.sqlite'),
            (config, 'CONFIG_DIR', 'CONFIG_PATH', 'config.yaml'),
            (dictionary, 'DICTIONARY_DIR', 'DICTIONARY_PATH', 'dictionary.yaml'),
        ):
            for key, value in ((directory_name, root), (path_name, root / filename)):
                patcher = patch.object(module, key, value)
                patcher.start()
                self.addCleanup(patcher.stop)
        self.engine = Engine()
        self.path = root / 'engine.sock'
        self.server = Server(self.path, self.engine)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def test_persistent_framing_errors_and_request_ids(self):
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(str(self.path))
            stream = client.makefile('rwb')
            stream.write(b'not-json\n{"id":1,"op":"status"}\n{"id":2,"op":"unknown"}\n')
            stream.flush()
            first, second, third = [json.loads(stream.readline()) for _ in range(3)]
            self.assertEqual(first['error']['code'], 'invalid_json')
            self.assertEqual(second['id'], 1)
            self.assertEqual(second['whisper'], 'loading')
            self.assertEqual(third['id'], 2)
            self.assertEqual(third['error']['code'], 'invalid_request')
            stream.close()

    def test_socket_is_private_and_unterminated_frame_is_rejected(self):
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(self.path))
            client.sendall(b'{"id":1,"op":"status"}')
            client.shutdown(socket.SHUT_WR)
            response = json.loads(client.recv(4096))
        self.assertEqual(response["error"]["code"], "invalid_json")

    def test_oversized_frame_is_rejected(self):
        payload = b'{"id":1,"op":"status","padding":"' + b"x" * MAX_REQUEST_BYTES + b'"}\n'
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(self.path))
            client.sendall(payload)
            response = json.loads(client.recv(4096))
        self.assertEqual(response["error"]["code"], "too_large")

    def test_oversized_response_is_replaced_with_bounded_error(self):
        self.engine.dispatch = lambda request: {"blob": "x" * MAX_RESPONSE_BYTES}
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(str(self.path))
            client.sendall(b'{"id":1,"op":"status"}\n')
            response = json.loads(client.recv(4096))
        self.assertEqual(response["id"], 1)
        self.assertEqual(response["error"]["code"], "response_too_large")

    def test_status_remains_responsive_during_model_work(self):
        self.engine.lock.acquire()
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(1)
                client.connect(str(self.path))
                client.sendall(b'{"id":"status","op":"status"}\n')
                response = json.loads(client.recv(4096))
        finally:
            self.engine.lock.release()
        self.assertEqual(response["id"], "status")
        self.assertEqual(response["whisper"], "loading")

    def test_warm_surfaces_missing_model_message(self):
        class FakeTranscriber:
            def __init__(self, *args, **kwargs):
                pass

            def warm_up(self):
                pass

        with patch("undertone.stt.Transcriber", FakeTranscriber):
            with patch(
                "undertone.cleanup._call_ollama",
                side_effect=cleanup.OllamaModelNotFoundError(
                    "Ollama has no local copy of 'qwen3.5:latest'. Run: ollama pull qwen3.5:latest"
                ),
            ):
                self.engine.warm()

        self.assertEqual(
            self.engine.error,
            "Ollama has no local copy of 'qwen3.5:latest'. Run: ollama pull qwen3.5:latest",
        )
        self.assertEqual(self.engine.cleanup_status, "error")

    def test_warm_uses_generic_message_for_other_failures(self):
        with patch("undertone.stt.Transcriber", side_effect=RuntimeError("boom")):
            self.engine.warm()

        self.assertEqual(
            self.engine.error,
            "Local model warm-up failed. Check cached Whisper models and localhost Ollama.",
        )
        self.assertEqual(self.engine.cleanup_status, "error")

    def test_clean_and_transcribe_return_protocol_fields(self):
        with patch.object(cleanup, "clean_result", return_value={
            "clean": "Cleaned fixture.", "model": "fixture", "guard_fired": False,
        }, create=True):
            clean_response = self.engine.dispatch({"op": "clean", "raw": "raw fixture"})
        self.assertEqual(clean_response["clean"], "Cleaned fixture.")
        self.assertEqual(clean_response["model"], "fixture")

        class FakeTranscriber:
            def transcribe(self, audio, vocab=""):
                self.audio = audio
                self.vocab = vocab
                return "Transcript fixture"

            def transcribe_detailed(self, audio, vocab="", **kwargs):
                self.audio = audio
                self.vocab = vocab
                return {"text": "Transcript fixture", "no_speech": False, "reason": ""}

        fake = FakeTranscriber()
        self.engine.transcriber = fake
        audio_path = Path(self.temporary.name) / "fixture.wav"
        audio_path.write_bytes(b"fixture")
        with patch("undertone.audio.load_wav", return_value=np.ones(4, dtype=np.float32)):
            response = self.engine.dispatch({
                "op": "transcribe", "audio_path": str(audio_path), "vocab_extra": ["Qwen"],
            })
        self.assertEqual(response["raw"], "Transcript fixture")
        self.assertIn("Qwen", fake.vocab)
        self.assertFalse(response["no_speech"])
        self.assertEqual(response["reason"], "")

    def test_clean_passes_bounded_context_without_persisting_it(self):
        seen = {}

        def fake_clean(raw, level, terms, cfg, app=None, context=None):
            seen.update(raw=raw, app=app, context=context)
            return {"clean_text": raw, "model": "fixture", "guard_fired": False}

        with patch.object(cleanup, "clean_result", side_effect=fake_clean):
            result = self.engine.dispatch({
                "op": "clean", "raw": "Synthetic raw", "app": "test.app",
                "context": {"before": "before", "after": "after", "selected": "selected"},
            })
        self.assertEqual(result["clean"], "Synthetic raw")
        self.assertEqual(seen["context"]["selected"], "selected")
        with self.assertRaises(ValueError):
            self.engine.dispatch({
                "op": "clean", "raw": "Synthetic raw",
                "context": {"before": "x" * 2001, "after": "", "selected": ""},
            })

    def test_invalid_history_types_are_rejected(self):
        with self.assertRaises(ValueError):
            self.engine.dispatch({
                "op": "history.record", "raw_text": "x", "clean_text": "x",
                "guard_fired": "yes",
            })
        with self.assertRaises(ValueError):
            self.engine.dispatch({"op": "history.list", "limit": True})
        with self.assertRaises(ValueError):
            self.engine.dispatch({"op": "history.delete", "row_id": True})

    def test_history_round_trip_and_app_date_search_filters(self):
        entry = {'op':'history.record','raw_text':'Synthetic words','clean_text':'Synthetic words.',
                 'insert_mode':'type','guard_fired':True,'model':'fixture', 'app_bundle_id':'test.app'}
        row_id = self.engine.dispatch(entry)['row_id']
        row = self.engine.dispatch({'op':'history.last'})['row']
        self.assertEqual(row['id'], row_id)
        self.assertEqual(row['guard_fired'], 1)
        self.assertEqual(len(self.engine.dispatch({'op':'history.list','query':'Synthetic','app':'test.app'})['rows']), 1)
        self.assertEqual(self.engine.dispatch({'op':'history.list','app':'another.app'})['rows'], [])
        self.assertEqual(self.engine.dispatch({'op':'history.list','after':row['ts'] + 1})['rows'], [])
        with self.assertRaises(ValueError):
            self.engine.dispatch({**entry,'insert_mode':'paste'})

    def test_history_update_changes_only_insert_metadata(self):
        entry = {
            'op': 'history.record', 'raw_text': 'Durable raw words', 'clean_text': 'Durable clean words.',
            'stt_ms': 174.0, 'llm_ms': 783.0, 'insert_ms': 0.0, 'total_ms': 957.0,
            'audio_seconds': 15.0, 'insert_mode': 'skipped', 'guard_fired': True,
            'model': 'qwen3.5:latest', 'audio_path': '/tmp/durable.wav',
            'app_bundle_id': 'test.app',
        }
        row_id = self.engine.dispatch(entry)['row_id']
        before = self.engine.dispatch({'op': 'history.last'})['row']
        self.assertEqual(before['insert_mode'], 'skipped')

        response = self.engine.dispatch({
            'op': 'history.update', 'row_id': row_id, 'insert_mode': 'ax',
            'insert_ms': 30.0, 'total_ms': 987.0,
        })
        self.assertEqual(response['updated'], row_id)
        after = self.engine.dispatch({'op': 'history.last'})['row']
        for field in ('raw_text', 'clean_text', 'audio_seconds', 'guard_fired', 'model', 'audio_path', 'app_bundle_id'):
            self.assertEqual(after[field], before[field], field)
        self.assertEqual(after['insert_mode'], 'ax')
        self.assertEqual(after['insert_ms'], 30.0)
        self.assertEqual(after['total_ms'], 987.0)

        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'history.update', 'row_id': row_id, 'insert_mode': 'paste', 'insert_ms': 1, 'total_ms': 1})
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'history.update', 'row_id': row_id + 1000, 'insert_mode': 'failed', 'insert_ms': 1, 'total_ms': 1})

    def test_history_update_retains_edited_text(self):
        row_id = self.engine.dispatch({
            'op': 'history.record', 'raw_text': 'Dictated name', 'clean_text': 'Dictated name',
            'app_bundle_id': 'test.app',
        })['row_id']
        self.engine.dispatch({
            'op': 'history.update', 'row_id': row_id, 'insert_mode': 'ax',
            'insert_ms': 1.0, 'total_ms': 2.0, 'edited_text': 'Corrected name',
        })
        row = self.engine.dispatch({'op': 'history.last'})['row']
        self.assertEqual(row['edited_text'], 'Corrected name')

    def test_history_update_can_record_edit_without_changing_insert_receipt(self):
        row_id = self.engine.dispatch({
            'op': 'history.record', 'raw_text': 'Dictated name', 'clean_text': 'Dictated name',
            'app_bundle_id': 'test.app', 'insert_mode': 'ax',
        })['row_id']
        self.engine.dispatch({'op': 'history.update', 'row_id': row_id, 'edited_text': 'Corrected name'})
        row = self.engine.dispatch({'op': 'history.last'})['row']
        self.assertEqual(row['edited_text'], 'Corrected name')
        self.assertEqual(row['insert_mode'], 'ax')

    def test_learned_protocol_is_explicit_and_does_not_write_on_propose(self):
        row_id = self.engine.dispatch({
            'op': 'history.record', 'raw_text': 'Priya', 'clean_text': 'Priya',
            'app_bundle_id': 'test.app',
        })['row_id']
        with patch.object(dictionary, 'add_term') as add_term:
            response = self.engine.dispatch({
                'op': 'learned.propose', 'produced': 'Priya', 'replacement': 'Priya Vale',
                'row_id': row_id, 'app_bundle_id': 'test.app',
            })
            self.assertEqual(response['suggestion']['row_id'], row_id)
            add_term.assert_not_called()
            suggestion_id = response['suggestion']['id']
            self.assertEqual(len(self.engine.dispatch({'op': 'learned.list'})['suggestions']), 1)
            self.assertEqual(self.engine.dispatch({
                'op': 'learned.add', 'suggestion_id': suggestion_id,
            })['status'], 'added')
            add_term.assert_called_once_with('Priya Vale')

    def test_complete_preserves_raw_audio_and_rejects_inserted_rows(self):
        row_id = self.engine.dispatch({"op":"history.record", "raw_text":"Raw fixture words", "clean_text":"Raw fixture words", "insert_mode":"skipped", "audio_path":"/tmp/fixture.wav"})["row_id"]
        request = {"op":"history.complete", "row_id":row_id, "clean_text":"Raw fixture words.", "model":"fixture", "guard_fired":False, "llm_ms":12}
        self.engine.dispatch(request)
        row = self.engine.dispatch({"op":"history.last"})["row"]
        self.assertEqual(row["raw_text"], "Raw fixture words")
        self.assertEqual(row["audio_path"], "/tmp/fixture.wav")
        self.assertEqual(row["clean_text"], "Raw fixture words.")
        with self.assertRaises(ValueError): self.engine.dispatch({**request, "raw_text":"Overwrite"})
        self.engine.dispatch({"op":"history.update", "row_id":row_id, "insert_mode":"ax", "insert_ms":1, "total_ms":13})
        with self.assertRaises(ValueError): self.engine.dispatch(request)

    def test_dictionary_and_settings_persist(self):
        self.engine.dispatch({'op':'dictionary.add','term':'Fixture'})
        self.assertEqual(self.engine.dispatch({'op':'dictionary.list'})['terms'][0], 'Fixture')
        self.engine.dispatch({'op':'config.update','config':{'cleanup_level':'high','sounds':False}})
        saved = self.engine.dispatch({'op':'config.get'})['config']
        self.assertEqual(saved['cleanup_level'], 'high')
        self.assertFalse(saved['sounds'])
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op':'config.update','config':{'ollama_url':'https://example.com'}})

    def test_dictionary_add_supersedes_auto_learning_action(self):
        row_id = self.engine.dispatch({
            'op': 'history.record', 'raw_text': 'Valora', 'clean_text': 'Valora',
            'insert_mode': 'ax', 'app_bundle_id': 'test.app',
        })['row_id']
        self.engine.dispatch({'op': 'config.update', 'config': {'learn_from_corrections': True}})
        action = self.engine.dispatch({
            'op': 'learning.auto_learn', 'produced': 'Valora', 'replacement': 'Velora',
            'row_id': row_id, 'app_bundle_id': 'test.app',
        })
        self.engine.dispatch({'op': 'dictionary.add', 'term': 'VELORA'})
        self.assertEqual(
            self.engine.dispatch({'op': 'learning.undo', 'action_id': action['action_id']})['status'],
            'superseded',
        )
        self.assertIn('VELORA', self.engine.dispatch({'op': 'dictionary.list'})['terms'])

    def test_engine_startup_recovers_pending_manual_dictionary_write(self):
        with history._connect() as db:
            learning._ensure_schema(db)
            db.execute(
                "INSERT INTO dictionary_writes (term, created_at) VALUES (?, ?)",
                ("StartupTerm", 1.0),
            )

        Engine()
        self.assertIn('StartupTerm', dictionary.load_dictionary()['terms'])
        with history._connect() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM dictionary_writes").fetchone()[0], 0)

    def test_auto_learning_uses_persisted_setting_not_request_flag(self):
        row_id = self.engine.dispatch({
            'op': 'history.record', 'raw_text': 'Valora', 'clean_text': 'Valora',
            'insert_mode': 'ax', 'app_bundle_id': 'test.app',
        })['row_id']
        request = {
            'op': 'learning.auto_learn', 'produced': 'Valora', 'replacement': 'Velora',
            'row_id': row_id, 'app_bundle_id': 'test.app', 'enabled': True,
        }
        self.assertEqual(self.engine.dispatch(request)['status'], 'disabled')
        self.engine.dispatch({'op': 'config.update', 'config': {'learn_from_corrections': True}})
        self.assertEqual(self.engine.dispatch(request)['status'], 'learned')
        self.engine.dispatch({'op': 'config.update', 'config': {'learn_from_corrections': False}})
        self.assertEqual(self.engine.dispatch({**request, 'replacement': 'Vellora'})['status'], 'disabled')
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'config.update', 'config': {'learn_from_corrections': 'yes'}})

    def test_learning_lookup_dispatch_resolves_token_and_unknown_is_read_only(self):
        row_id = self.engine.dispatch({
            'op': 'history.record', 'raw_text': 'Valora', 'clean_text': 'Valora',
            'insert_mode': 'ax', 'app_bundle_id': 'test.app',
        })['row_id']
        self.engine.dispatch({'op': 'config.update', 'config': {'learn_from_corrections': True}})
        learned = self.engine.dispatch({
            'op': 'learning.auto_learn', 'produced': 'Valora', 'replacement': 'Velora',
            'row_id': row_id, 'app_bundle_id': 'test.app', 'client_token': 'server-token',
        })
        resolved = self.engine.dispatch({'op': 'learning.lookup', 'client_token': 'server-token'})
        self.assertEqual(resolved['status'], 'learned')
        self.assertEqual(resolved['action_id'], learned['action_id'])
        self.assertEqual(
            self.engine.dispatch({'op': 'learning.lookup', 'client_token': 'unknown-token'})['status'],
            'not_found',
        )

    def test_pill_settings_persist_and_validate(self):
        self.engine.dispatch({'op': 'config.update', 'config': {'pill_edge': 'left', 'pill_offset': 0.25, 'pill_persistent': False}})
        saved = self.engine.dispatch({'op': 'config.get'})['config']
        self.assertEqual(saved['pill_edge'], 'left')
        self.assertEqual(saved['pill_offset'], 0.25)
        self.assertFalse(saved['pill_persistent'])
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'config.update', 'config': {'pill_edge': 'diagonal'}})
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'config.update', 'config': {'pill_offset': 1.5}})
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'config.update', 'config': {'pill_offset': 'half'}})

    def test_meeting_dispatch_retains_failed_stt_and_recovers_exact_retry(self):
        calls = []

        def transcribe(path):
            calls.append(path)
            if len(calls) == 1:
                raise RuntimeError("fixture STT failure")
            return "Meeting fixture transcript"

        self.engine.meetings.transcribe = transcribe
        session = self.engine.dispatch({'op': 'meeting.start', 'title': 'Fixture meeting'})['session']
        session_id = session['session_id']
        audio_path = Path(self.temporary.name) / 'meeting.wav'
        audio_path.write_bytes(b'fixture audio')
        failed = self.engine.dispatch({
            'op': 'meeting.chunk', 'session_id': session_id, 'seq': 0,
            'audio_path': str(audio_path), 'speaker': 'others', 'offset_s': 0, 'duration_s': 1,
        })
        self.assertEqual(failed['status'], 'error')
        retained = self.engine.dispatch({'op': 'meeting.get', 'session_id': session_id})
        self.assertEqual(retained['session']['chunks'][0]['status'], 'error')
        audio_path.unlink()
        recovered = self.engine.dispatch({
            'op': 'meeting.chunk', 'session_id': session_id, 'seq': 0,
            'audio_path': str(audio_path), 'speaker': 'others', 'offset_s': 0, 'duration_s': 1,
        })
        self.assertEqual(recovered['text'], 'Meeting fixture transcript')
        self.assertEqual(len(calls), 2)

    def test_meeting_quiet_chunk_is_complete_and_skips_stt(self):
        self.engine.meetings.transcribe = lambda path: self.fail('quiet chunk must not invoke STT')
        session_id = self.engine.dispatch({'op': 'meeting.start'})['session']['session_id']
        audio_path = Path(self.temporary.name) / 'quiet.wav'
        audio_path.write_bytes(b'quiet fixture audio')
        result = self.engine.dispatch({
            'op': 'meeting.chunk', 'session_id': session_id, 'seq': 0,
            'audio_path': str(audio_path), 'speaker': 'others', 'offset_s': 0,
            'duration_s': 1, 'voice_activity': False,
        })
        self.assertEqual(result['status'], 'complete')
        self.assertFalse(result['voice_activity'])
        self.assertFalse(self.engine.dispatch({'op': 'meeting.get', 'session_id': session_id})['session']['chunks'][0]['voice_activity'])
        with self.assertRaises(ValueError):
            self.engine.dispatch({
                'op': 'meeting.chunk', 'session_id': session_id, 'seq': 0,
                'audio_path': str(audio_path), 'speaker': 'others', 'offset_s': 0,
                'duration_s': 1, 'voice_activity': 'false',
            })

    def test_meeting_end_without_configured_vault_saves_local_summary(self):
        self.engine.meetings.transcribe = lambda path: 'Meeting fixture transcript'
        self.engine.meetings.summarize = lambda section: 'Local meeting summary'
        session_id = self.engine.dispatch({'op': 'meeting.start'})['session']['session_id']
        audio_path = Path(self.temporary.name) / 'meeting.wav'
        audio_path.write_bytes(b'fixture audio')
        self.engine.dispatch({
            'op': 'meeting.chunk', 'session_id': session_id, 'seq': 0,
            'audio_path': str(audio_path), 'speaker': 'me', 'offset_s': 0, 'duration_s': 1,
        })
        result = self.engine.dispatch({'op': 'meeting.end', 'session_id': session_id})
        self.assertEqual(result['session']['summary'], 'Local meeting summary')
        self.assertIsNotNone(result['session']['ended_at'])
        self.assertTrue(result['session']['needs_vault'])
        self.assertEqual(result['session']['status'], 'needs_vault')
        self.assertEqual(self.engine.dispatch({'op': 'meeting.list'})['sessions'][0]['session_id'], session_id)

    def test_meeting_update_and_resummarize_dispatch(self):
        self.engine.meetings.transcribe = lambda path: 'Meeting fixture transcript'
        self.engine.meetings.summarize = lambda section, *, mode='final': (
            'Auto named meeting' if mode == 'title' else '## Key points\n- Fixture'
        )
        session_id = self.engine.dispatch({'op': 'meeting.start'})['session']['session_id']
        audio_path = Path(self.temporary.name) / 'meeting.wav'
        audio_path.write_bytes(b'fixture audio')
        self.engine.dispatch({
            'op': 'meeting.chunk', 'session_id': session_id, 'seq': 0,
            'audio_path': str(audio_path), 'speaker': 'me', 'offset_s': 0, 'duration_s': 1,
        })
        ended = self.engine.dispatch({'op': 'meeting.end', 'session_id': session_id})['session']
        self.assertEqual(ended['title'], 'Auto named meeting')
        self.assertEqual(ended['title_source'], 'auto')

        updated = self.engine.dispatch({
            'op': 'meeting.update', 'session_id': session_id,
            'title': 'My title', 'notes': 'My notes', 'summary': 'My summary',
        })['session']
        self.assertEqual((updated['title'], updated['notes'], updated['summary']),
                         ('My title', 'My notes', 'My summary'))
        self.assertEqual(updated['title_source'], 'user')
        self.assertTrue(updated['summary_edited'])

        again = self.engine.dispatch({'op': 'meeting.summarize', 'session_id': session_id})['session']
        self.assertEqual(again['summary'], '## Key points\n- Fixture')
        self.assertFalse(again['summary_edited'])
        self.assertEqual(again['title'], 'My title')
        self.assertEqual(again['notes'], 'My notes')
        listed = self.engine.dispatch({'op': 'meeting.list'})['sessions'][0]
        self.assertIn('my notes', listed['search_text'])
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'meeting.update', 'session_id': session_id, 'title': 5})

    def test_obsidian_vault_setting_requires_explicit_existing_directory(self):
        vault = Path(self.temporary.name) / 'vault'
        vault.mkdir()
        saved = self.engine.dispatch({'op': 'config.update', 'config': {'obsidian_vault_path': str(vault)}})
        self.assertEqual(saved['config']['obsidian_vault_path'], str(vault.resolve()))
        cleared = self.engine.dispatch({'op': 'config.update', 'config': {'obsidian_vault_path': ''}})
        self.assertIsNone(cleared['config']['obsidian_vault_path'])
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'config.update', 'config': {'obsidian_vault_path': 'relative-vault'}})

    def test_meeting_summary_uses_high_local_model_with_vault_export(self):
        vault = Path(self.temporary.name) / 'vault'
        vault.mkdir()
        self.engine.dispatch({'op': 'config.update', 'config': {'obsidian_vault_path': str(vault)}})
        self.engine.meetings.transcribe = lambda path: 'Meeting fixture transcript'
        session_id = self.engine.dispatch({'op': 'meeting.start', 'title': 'Summary fixture'})['session']['session_id']
        audio_path = Path(self.temporary.name) / 'meeting.wav'
        audio_path.write_bytes(b'fixture audio')
        self.engine.dispatch({
            'op': 'meeting.chunk', 'session_id': session_id, 'seq': 0,
            'audio_path': str(audio_path), 'speaker': 'me', 'offset_s': 0, 'duration_s': 1,
        })
        with patch('undertone.cleanup._call_ollama', return_value='Synthetic summary') as call:
            result = self.engine.dispatch({'op': 'meeting.end', 'session_id': session_id})
        self.assertEqual(result['session']['status'], 'ended')
        self.assertEqual(call.call_args.args[2], 'gemma4:31b')
        self.assertIn('Do not invent names, facts', call.call_args.args[0])

    def test_meeting_summary_does_not_hold_dictation_dispatch_lock(self):
        entered = threading.Event()
        release = threading.Event()
        finished = threading.Event()
        errors = []
        service = self.engine.meetings
        def blocked_end(*args, **kwargs):
            entered.set()
            if not release.wait(3):
                raise TimeoutError("test summary release")
            return {"status": "ended"}
        def end_meeting():
            try:
                self.engine.dispatch({"op": "meeting.end", "session_id": "fixture"})
            except Exception as error:
                errors.append(error)
        def fetch_history():
            try:
                self.engine.dispatch({"op": "history.list"})
                finished.set()
            except Exception as error:
                errors.append(error)
        with patch.object(service, "end", side_effect=blocked_end):
            worker = threading.Thread(target=end_meeting)
            worker.start()
            reader = None
            try:
                self.assertTrue(entered.wait(1))
                reader = threading.Thread(target=fetch_history)
                reader.start()
                self.assertTrue(finished.wait(1), "meeting summary blocked unrelated engine work")
            finally:
                release.set()
                worker.join(3)
                if reader: reader.join(3)
        self.assertEqual(errors, [])

    def test_stream_insert_config_accepts_bool_and_rejects_other_types(self):
        saved = self.engine.dispatch({'op': 'config.update', 'config': {'stream_insert': False}})
        self.assertFalse(saved['config']['stream_insert'])
        saved = self.engine.dispatch({'op': 'config.update', 'config': {'stream_insert': True}})
        self.assertTrue(saved['config']['stream_insert'])
        with self.assertRaises(ValueError):
            self.engine.dispatch({'op': 'config.update', 'config': {'stream_insert': 'yes'}})

    def test_clean_stream_emits_id_on_every_frame_and_final_done(self):
        raw = "one two three four five six seven eight nine ten"
        deltas = ["one two three four five six ", "seven eight nine ten"]

        def fake_stream(*args, **kwargs):
            yield from deltas

        with patch.object(cleanup, "_stream_ollama", side_effect=fake_stream):
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(self.path))
                stream = client.makefile("rwb")
                stream.write(json.dumps({"id": 9, "op": "clean.stream", "raw": raw, "level": "medium"}).encode() + b"\n")
                stream.flush()
                frames = []
                while True:
                    line = stream.readline()
                    self.assertTrue(line)
                    frame = json.loads(line)
                    frames.append(frame)
                    if frame.get("done") is True:
                        break
                stream.close()

        self.assertGreater(len(frames), 1)
        for frame in frames:
            self.assertEqual(frame["id"], 9)
            self.assertNotIn("error", frame)
        chunks = [frame for frame in frames if "chunk" in frame]
        self.assertTrue(chunks)
        for index, frame in enumerate(chunks):
            self.assertEqual(frame["seq"], index)
        final = frames[-1]
        self.assertTrue(final["done"])
        self.assertEqual(final["chunks_sent"], len(chunks))
        self.assertIn("clean", final)
        self.assertIn("llm_ms", final)
        committed = "".join(frame["chunk"] for frame in chunks)
        self.assertTrue(final["clean"].startswith(committed))

    def test_clean_stream_light_path_is_one_final_frame(self):
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(str(self.path))
            stream = client.makefile("rwb")
            stream.write(json.dumps({
                "id": 4, "op": "clean.stream", "raw": "um one two three", "level": "light",
            }).encode() + b"\n")
            stream.flush()
            frame = json.loads(stream.readline())
            stream.close()
        self.assertEqual(frame["id"], 4)
        self.assertTrue(frame["done"])
        self.assertEqual(frame["chunks_sent"], 0)
        self.assertIn("clean", frame)


if __name__ == '__main__':
    unittest.main()
