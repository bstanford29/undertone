from __future__ import annotations

import base64
import json
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from undertone import cleanup, config, dictionary, history
from undertone.live import (
    opens_with_correction,
    LiveDictation,
    WindowedTranscriber,
    adaptive_rms_threshold,
    assign_words,
    plan_units,
    quietest_cut,
)
from undertone.server import Engine, Server
from undertone.stt import Word, words_from_tokens

SR = 16000
WORD_S = 0.3
BASE_AMPLITUDE = 0.05
AMPLITUDE_STEP = 0.01


def _label(index: int) -> str:
    # Every fifth word ends a sentence so unit planning has real boundaries.
    return f"w{index}." if index % 5 == 4 else f"w{index}"


def _word(index: int, seconds: float = WORD_S) -> np.ndarray:
    """A block whose amplitude encodes which word it is."""
    amplitude = BASE_AMPLITUDE + AMPLITUDE_STEP * index
    signs = np.where(np.arange(int(SR * seconds)) % 2 == 0, 1.0, -1.0)
    return (amplitude * signs).astype(np.float32)


def _pause(seconds: float) -> np.ndarray:
    return np.zeros(int(SR * seconds), dtype=np.float32)


def _sentences(count: int, *, gap_s: float = 0.1, pause_s: float = 0.5) -> np.ndarray:
    """``count`` words, a long pause after every sentence end, short gaps elsewhere."""
    parts: list[np.ndarray] = []
    for index in range(count):
        parts.append(_word(index))
        parts.append(_pause(pause_s if _label(index).endswith(".") else gap_s))
    return np.concatenate(parts)


class AmplitudeFake:
    """Reads the words back out of the amplitude-coded audio, with timestamps.

    ``lag_s`` shifts every reported start later, like a decoder that emits a
    token after its acoustic evidence. ``fail_windows`` raises on those window
    calls (1-based) to exercise the fallbacks.
    """

    backend = "fake"
    model = "fake-model"

    def __init__(self, *, lag_s: float = 0.0, fail_windows: tuple[int, ...] = (),
                 relabel: dict[int, str] | None = None):
        self.lag_s = lag_s
        self.fail_windows = set(fail_windows)
        self.relabel = relabel or {}
        self.word_calls: list[dict] = []
        self.whole_calls: list[int] = []
        self._lock = threading.Lock()

    def _scan(self, audio: np.ndarray) -> list[Word]:
        audio = np.asarray(audio, dtype=np.float32)
        loud = np.abs(audio) > 1e-4
        words: list[Word] = []
        index = 0
        while index < loud.size:
            if not loud[index]:
                index += 1
                continue
            start = index
            while index < loud.size and loud[index]:
                index += 1
            amplitude = float(np.max(np.abs(audio[start:index])))
            number = int(round((amplitude - BASE_AMPLITUDE) / AMPLITUDE_STEP))
            label = self.relabel.get(number, _label(number))
            words.append(Word(label, start / SR + self.lag_s, index / SR + self.lag_s))
        return words

    def transcribe_words(self, audio, vocab="", context=""):
        with self._lock:
            self.word_calls.append({"samples": len(audio), "vocab": vocab, "context": context, "at": time.monotonic()})
            call = len(self.word_calls)
        if call in self.fail_windows:
            raise RuntimeError("synthetic window failure")
        return self._scan(audio)

    def transcribe(self, audio, vocab="", context=""):
        with self._lock:
            self.whole_calls.append(len(audio))
        return " ".join(word.text for word in self._scan(audio))


def _fake_cleaner(calls: list[dict], *, fail_on: int | None = None):
    lock = threading.Lock()

    def clean(raw, level, dictionary_data, cfg, app=None, context=None):
        with lock:
            calls.append({"raw": raw, "context": context, "at": time.monotonic(), "app": app})
            count = len(calls)
        if fail_on == count:
            raise RuntimeError("synthetic cleanup failure")
        return {"clean_text": "[" + raw.upper() + "]", "model": "fake-llm", "guard_fired": False}

    return clean


def _feed(session: LiveDictation, audio: np.ndarray, *, step_s: float = 0.5, skip_seq: int | None = None) -> None:
    step = int(step_s * SR)
    seq = 0
    for start in range(0, len(audio), step):
        if seq == skip_seq:
            seq += 1
        session.append(audio[start : start + step], seq=seq)
        seq += 1


def _wait_until(predicate, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


class HelperTests(unittest.TestCase):
    def test_correction_phrases_only_count_when_they_open_the_text(self):
        self.assertTrue(opens_with_correction("No wait, Wednesday not Tuesday"))
        self.assertTrue(opens_with_correction("um scratch that"))
        self.assertTrue(opens_with_correction("Actually, no. Make it Friday."))
        self.assertFalse(opens_with_correction("meaning that we start over there"))
        self.assertFalse(opens_with_correction("the plan was fine but no wait"))
        self.assertFalse(opens_with_correction(""))

    def test_plan_units_closes_at_sentence_end_after_min_words_or_at_cap(self):
        texts = ["one two.", "three four five.", "six seven", "eight nine ten eleven.", "twelve"]
        self.assertEqual(plan_units(texts, min_words=4, max_words=40), [2, 2])
        self.assertEqual(plan_units(texts, min_words=1, max_words=40), [1, 1, 2])
        self.assertEqual(plan_units(["a b", "c d", "e f"], min_words=3, max_words=4), [2])

    def test_adaptive_threshold_tracks_the_room_floor_within_bounds(self):
        quiet = np.full(200, 0.0005, dtype=np.float32)
        self.assertEqual(adaptive_rms_threshold(quiet), 0.004)
        noisy = np.concatenate([np.full(100, 0.006, dtype=np.float32), np.full(100, 0.2, dtype=np.float32)])
        self.assertAlmostEqual(adaptive_rms_threshold(noisy), 0.015, places=6)
        loud_floor = np.full(200, 0.5, dtype=np.float32)
        self.assertEqual(adaptive_rms_threshold(loud_floor), 0.02)
        self.assertEqual(adaptive_rms_threshold(np.full(10, 0.5, dtype=np.float32)), 0.004)

    def test_assign_words_uses_start_time_inside_the_recording(self):
        words = [Word("a", 0.0, 0.2), Word("b", 0.5, 0.7), Word("c", 1.0, 1.2)]
        kept = assign_words(words, window_start=SR, start=SR + int(0.4 * SR), end=SR + int(0.9 * SR), sample_rate=SR)
        self.assertEqual([word.text for word in kept], ["b"])

    def test_quietest_cut_finds_the_gap(self):
        audio = np.concatenate([_word(1, 1.0), _pause(0.3), _word(2, 1.0)])
        cut = quietest_cut(audio, earliest=0, latest=len(audio), sample_rate=SR)
        self.assertTrue(SR * 1.0 <= cut <= SR * 1.3)
        self.assertIsNone(quietest_cut(audio, earliest=0, latest=10, sample_rate=SR))

    def test_words_from_tokens_groups_on_leading_space(self):
        class Token:
            def __init__(self, text, start, duration):
                self.text, self.start, self.duration = text, start, duration
                self.end = start + duration

        tokens = [Token(" hel", 0.0, 0.1), Token("lo", 0.1, 0.1), Token(" world", 0.4, 0.2), Token(".", 0.6, 0.05)]
        words = words_from_tokens(tokens)
        self.assertEqual([(w.text, round(w.start, 2), round(w.end, 2)) for w in words],
                         [("hello", 0.0, 0.2), ("world.", 0.4, 0.65)])


class WindowedTranscriberTests(unittest.TestCase):
    def _run(self, audio: np.ndarray, fake: AmplitudeFake, *, step_s: float = 0.5, **kwargs):
        chunks_seen: list = []
        # Four seconds of left context keeps these short synthetic clips from
        # being decoded whole, so the window logic is what gets exercised.
        kwargs.setdefault("left_context_s", 4.0)
        stream = WindowedTranscriber(fake, on_chunk=chunks_seen.append, **kwargs)
        step = int(step_s * SR)
        for end in range(step, len(audio), step):
            stream.submit(audio[:end])
        run = stream.finish(audio)
        return stream, run, chunks_seen

    def test_cuts_land_in_pauses_and_every_word_is_kept_exactly_once(self):
        audio = _sentences(15)
        fake = AmplitudeFake()
        _, run, seen = self._run(audio, fake)

        self.assertIsNone(run.error)
        self.assertGreaterEqual(len(run.chunks), 3)
        self.assertEqual(run.chunks[0].start_sample, 0)
        self.assertEqual(run.chunks[-1].end_sample, len(audio))
        for left, right in zip(run.chunks, run.chunks[1:]):
            self.assertEqual(left.end_sample, right.start_sample)
            window = audio[left.end_sample - SR // 100 : left.end_sample + SR // 100]
            self.assertTrue(np.all(np.abs(window) < 1e-6), "cut is not inside silence")
        self.assertTrue(run.chunks[-1].final)
        expected = [_label(index) for index in range(15)]
        self.assertEqual(run.text.split(), expected)
        self.assertEqual([chunk.sequence for chunk in seen], [chunk.sequence for chunk in run.chunks])
        self.assertEqual(run.boundary_disagreements, 0)
        # Each interior chunk was decoded inside a window larger than itself.
        for chunk in run.chunks[1:-1]:
            self.assertLess(chunk.window_start, chunk.start_sample)
            self.assertGreater(chunk.window_end, chunk.end_sample)

    def test_short_recordings_decode_the_tail_with_the_whole_clip_as_context(self):
        audio = _sentences(15)
        fake = AmplitudeFake()
        stream = WindowedTranscriber(fake)
        step = SR // 2
        for end in range(step, len(audio), step):
            stream.submit(audio[:end])
        run = stream.finish(audio)
        self.assertIsNone(run.error)
        self.assertEqual(run.chunks[-1].window_start, 0)
        self.assertEqual(fake.word_calls[-1]["samples"], len(audio))
        self.assertEqual(run.text.split(), [_label(index) for index in range(15)])

    def test_release_only_decodes_the_tail_window(self):
        audio = _sentences(15)
        fake = AmplitudeFake()
        stream = WindowedTranscriber(fake, left_context_s=4.0)
        step = SR // 2
        for end in range(step, len(audio), step):
            stream.submit(audio[:end])
        # Let the windows cut while "recording" finish decoding before release.
        self.assertTrue(_wait_until(lambda: all(chunk.done for chunk in stream.chunks)))
        before = len(fake.word_calls)
        committed = stream.committed_samples
        self.assertGreater(committed, 0)
        run = stream.finish(audio)
        self.assertLessEqual(len(fake.word_calls) - before, 2)
        tail_call = fake.word_calls[-1]
        self.assertLess(tail_call["samples"], len(audio))
        self.assertEqual(run.chunks[-1].start_sample, committed)

    def test_emission_lag_does_not_lose_or_duplicate_words(self):
        audio = _sentences(15)
        _, run, _ = self._run(audio, AmplitudeFake(lag_s=0.12))
        self.assertEqual(run.text.split(), [_label(index) for index in range(15)])
        self.assertEqual(run.boundary_disagreements, 0)

    def test_long_breathless_speech_is_cut_at_its_quietest_point(self):
        # 12 words with 60 ms gaps: no pause long enough, so a cut is forced.
        audio = _sentences(12, gap_s=0.06, pause_s=0.06)
        fake = AmplitudeFake()
        _, run, _ = self._run(audio, fake, max_chunk_s=2.5)
        self.assertGreaterEqual(len(run.chunks), 2)
        self.assertTrue(any(chunk.forced_cut for chunk in run.chunks))
        self.assertEqual(run.text.split(), [_label(index) for index in range(12)])

    def test_window_failure_marks_the_chunk(self):
        audio = _sentences(15)
        fake = AmplitudeFake(fail_windows=(1,))
        _, run, seen = self._run(audio, fake)
        self.assertEqual(run.error, "RuntimeError")
        self.assertEqual(run.chunks[0].error, "RuntimeError")
        self.assertIsNone(run.chunks[0].text)
        self.assertEqual(seen[0].error, "RuntimeError")

    def test_silence_only_makes_no_model_calls_and_one_empty_chunk(self):
        audio = _pause(3.0)
        fake = AmplitudeFake()
        _, run, _ = self._run(audio, fake)
        self.assertEqual(run.text, "")
        self.assertEqual(len(run.chunks), 1)
        self.assertIsNone(run.error)

    def test_context_carries_earlier_text_not_vocab(self):
        audio = _sentences(15)
        fake = AmplitudeFake()
        self._run(audio, fake, vocab="Ollama, Qwen")
        self.assertEqual(fake.word_calls[0]["context"], "")
        self.assertTrue(all(call["vocab"] == "Ollama, Qwen" for call in fake.word_calls))
        self.assertIn("w4.", fake.word_calls[-1]["context"])


class LiveDictationTests(unittest.TestCase):
    def _session(self, fake, calls, **kwargs):
        return LiveDictation(
            fake, _fake_cleaner(calls, **kwargs.pop("cleaner", {})), level="medium", dictionary={"terms": []},
            config={}, app="test.app", context={"before": "Earlier text.", "after": "", "selected": ""},
            vocab="Ollama, Qwen", min_unit_words=3, max_unit_words=40, **kwargs,
        )

    def test_units_are_cleaned_while_recording_and_release_emits_them_first(self):
        audio = _sentences(15)
        fake = AmplitudeFake()
        calls: list[dict] = []
        session = self._session(fake, calls)
        _feed(session, audio)
        self.assertTrue(_wait_until(lambda: session.progress()["units_cleaned"] >= 2))
        cleaned_before_release = len(calls)
        self.assertGreaterEqual(cleaned_before_release, 2)

        frames: list[dict] = []
        result = session.finish(audio, emit=frames.append)

        self.assertIsNone(result.error)
        self.assertIsNone(result.fallback)
        self.assertEqual(result.raw.split(), [_label(index) for index in range(15)])
        self.assertEqual(len(frames), 1)
        self.assertTrue(result.clean.startswith(frames[0]["chunk"]))
        self.assertEqual(frames[0]["chunk"], result.committed_clean)
        self.assertEqual(result.clean, " ".join(unit.clean for unit in result.units))
        self.assertTrue(result.units[-1].final)
        self.assertEqual(result.model, "fake-llm")
        self.assertFalse(result.guard_fired)
        self.assertFalse(result.stream_interrupted)
        # The release path cleaned only the last unit.
        self.assertEqual(len(calls) - cleaned_before_release, 1)
        self.assertIn("w14.", calls[-1]["raw"])
        self.assertNotIn("w0 ", calls[-1]["raw"] + " ")
        # Later units see the cleaned text before them, after the app's own text.
        self.assertTrue(calls[1]["context"]["before"].startswith("Earlier text."))
        self.assertIn("[W0 W1 W2 W3 W4.]", calls[1]["context"]["before"])
        self.assertEqual(calls[0]["app"], "test.app")

    def test_seq_gap_falls_back_to_the_complete_recording(self):
        audio = _sentences(10)
        fake = AmplitudeFake()
        calls: list[dict] = []
        session = self._session(fake, calls)
        _feed(session, audio, skip_seq=2)
        frames: list[dict] = []
        result = session.finish(audio, emit=frames.append)
        self.assertEqual(result.fallback, "seq_gap")
        self.assertEqual(frames, [])
        self.assertEqual(fake.whole_calls, [len(audio)])
        self.assertEqual(result.raw.split(), [_label(index) for index in range(10)])
        self.assertEqual(result.clean, "[" + result.raw.upper() + "]")
        self.assertEqual(calls[-1]["raw"], result.raw)
        self.assertEqual(calls[-1]["context"]["before"], "Earlier text.")

    def test_recording_longer_than_streamed_audio_uses_the_recording(self):
        audio = _sentences(10)
        fake = AmplitudeFake()
        calls: list[dict] = []
        session = self._session(fake, calls)
        _feed(session, audio[: len(audio) - SR])
        result = session.finish(audio, emit=lambda frame: self.fail("nothing may be emitted"))
        self.assertEqual(result.fallback, "audio_mismatch")
        self.assertEqual(fake.whole_calls, [len(audio)])
        self.assertEqual(result.raw.split(), [_label(index) for index in range(10)])

    def test_window_failure_before_release_falls_back_without_emitting(self):
        audio = _sentences(15)
        fake = AmplitudeFake(fail_windows=(1,))
        calls: list[dict] = []
        session = self._session(fake, calls)
        _feed(session, audio)
        self.assertTrue(_wait_until(lambda: len(fake.word_calls) >= 1))
        time.sleep(0.05)
        result = session.finish(audio, emit=lambda frame: self.fail("nothing may be emitted"))
        self.assertEqual(result.fallback, "stt_chunk")
        self.assertEqual(result.raw.split(), [_label(index) for index in range(15)])
        self.assertEqual(len(calls), 1)

    def test_tail_failure_after_emission_redoes_only_the_uncovered_audio(self):
        audio = _sentences(15)
        fake = AmplitudeFake()
        calls: list[dict] = []
        session = self._session(fake, calls)
        _feed(session, audio)
        self.assertTrue(_wait_until(lambda: session.progress()["units_cleaned"] >= 2))
        # Every window from now on fails, including the release window.
        fake.fail_windows = set(range(len(fake.word_calls) + 1, len(fake.word_calls) + 10))
        frames: list[dict] = []
        result = session.finish(audio, emit=frames.append)
        self.assertEqual(len(frames), 1)
        self.assertIsNone(result.fallback)
        self.assertFalse(result.stream_interrupted)
        self.assertEqual(len(fake.whole_calls), 1)
        self.assertLess(fake.whole_calls[0], len(audio))
        self.assertEqual(result.raw.split(), [_label(index) for index in range(15)])
        self.assertTrue(result.clean.startswith(frames[0]["chunk"]))

    def test_cleanup_exception_keeps_raw_text_and_marks_guard(self):
        audio = _sentences(15)
        fake = AmplitudeFake()
        calls: list[dict] = []
        session = self._session(fake, calls, cleaner={"fail_on": 1})
        _feed(session, audio)
        self.assertTrue(_wait_until(lambda: session.progress()["units_cleaned"] >= 2))
        result = session.finish(audio)
        self.assertTrue(result.guard_fired)
        self.assertEqual(result.units[0].error, "RuntimeError")
        self.assertTrue(result.units[0].clean.startswith("W0"))
        self.assertEqual(result.raw.split(), [_label(index) for index in range(15)])

    def test_correction_after_a_pause_cleans_the_whole_recording_once(self):
        # Word 5 opens the chunk after the first sentence's pause; "scratch
        # that" there refers back to the unit that was already cleaned.
        fake = AmplitudeFake(relabel={5: "scratch", 6: "that"})
        calls: list[dict] = []
        session = self._session(fake, calls)
        audio = _sentences(15)
        _feed(session, audio)
        self.assertTrue(_wait_until(lambda: session.progress()["units_cleaned"] >= 1))
        frames: list[dict] = []
        result = session.finish(audio, emit=frames.append)
        self.assertEqual(frames, [])
        self.assertEqual(result.fallback, "correction")
        self.assertEqual(fake.whole_calls, [])
        self.assertEqual(result.raw.split()[5:7], ["scratch", "that"])
        self.assertEqual(result.clean, "[" + result.raw.upper() + "]")
        self.assertEqual(calls[-1]["raw"], result.raw)

    def test_silent_recording_is_no_speech(self):
        fake = AmplitudeFake()
        calls: list[dict] = []
        session = self._session(fake, calls)
        _feed(session, _pause(2.0))
        result = session.finish(_pause(2.0), emit=lambda frame: self.fail("nothing may be emitted"))
        self.assertTrue(result.no_speech)
        self.assertEqual(result.raw, "")
        self.assertEqual(calls, [])

    def test_cancel_closes_workers(self):
        fake = AmplitudeFake()
        session = self._session(fake, [])
        _feed(session, _sentences(10))
        session.cancel()
        with self.assertRaises(RuntimeError):
            session.append(_pause(0.5), seq=99)


class LiveServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        for module, directory_name, path_name, filename in (
            (history, "HISTORY_DIR", "HISTORY_PATH", "history.sqlite"),
            (config, "CONFIG_DIR", "CONFIG_PATH", "config.yaml"),
            (dictionary, "DICTIONARY_DIR", "DICTIONARY_PATH", "dictionary.yaml"),
        ):
            for key, value in ((directory_name, root), (path_name, root / filename)):
                patcher = patch.object(module, key, value)
                patcher.start()
                self.addCleanup(patcher.stop)
        self.engine = Engine()
        self.fake = AmplitudeFake()
        self.engine.transcriber = self.fake
        self.calls: list[dict] = []
        patcher = patch.object(cleanup, "clean_result", side_effect=_fake_cleaner(self.calls))
        patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def _pcm16(samples: np.ndarray) -> str:
        return base64.b64encode((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()).decode()

    def test_dispatch_round_trip_streams_committed_text_then_the_result(self):
        started = self.engine.dispatch({
            "op": "dictation.start", "app": "test.app", "vocab_extra": ["Qwen"],
            "context": {"before": "Earlier.", "after": "", "selected": ""},
        })
        session_id = started["session_id"]
        self.assertEqual(started["backend"], "fake")
        # 25 words with the default 8-word unit policy: two units are cleaned
        # while "recording" and the last sentence is the release tail.
        audio = _sentences(25)
        step = SR // 2
        for seq, start in enumerate(range(0, len(audio), step)):
            progress = self.engine.dispatch({
                "op": "dictation.audio", "session_id": session_id, "seq": seq,
                "pcm16": self._pcm16(audio[start : start + step]),
            })
            self.assertEqual(progress["seq"], seq)
        self.assertTrue(_wait_until(lambda: self.engine._live[1].progress()["units_cleaned"] >= 2))
        frames: list[dict] = []
        response = self.engine.dispatch({"op": "dictation.finish", "session_id": session_id}, emit=frames.append)
        self.assertEqual(len(frames), 1)
        self.assertTrue(response["done"])
        self.assertEqual(response["chunks_sent"], 1)
        self.assertTrue(response["clean"].startswith(frames[0]["chunk"]))
        self.assertEqual(response["raw"].split(), [_label(index) for index in range(25)])
        self.assertEqual(response["model"], "fake-llm")
        self.assertFalse(response["guard_fired"])
        self.assertFalse(response["no_speech"])
        self.assertIsNone(response["live_fallback"])
        self.assertGreaterEqual(response["live_units"], 3)
        self.assertIsNone(self.engine._live)
        self.assertEqual(self.engine.whisper_status, "warm")
        with self.assertRaises(ValueError):
            self.engine.dispatch({"op": "dictation.finish", "session_id": session_id})

    def test_audio_frames_are_validated(self):
        session_id = self.engine.dispatch({"op": "dictation.start"})["session_id"]
        with self.assertRaises(ValueError):
            self.engine.dispatch({"op": "dictation.audio", "session_id": session_id, "seq": -1, "pcm16": "AAAA"})
        with self.assertRaises(ValueError):
            self.engine.dispatch({"op": "dictation.audio", "session_id": session_id, "seq": 0, "pcm16": "not base64!"})
        with self.assertRaises(ValueError):
            self.engine.dispatch({"op": "dictation.audio", "session_id": "nope", "seq": 0, "pcm16": "AAAA"})
        self.assertEqual(self.engine.dispatch({"op": "dictation.cancel", "session_id": session_id}), {"cancelled": True})
        self.assertIsNone(self.engine._live)

    def test_a_new_start_replaces_an_unfinished_session(self):
        first = self.engine.dispatch({"op": "dictation.start"})["session_id"]
        second = self.engine.dispatch({"op": "dictation.start"})["session_id"]
        self.assertNotEqual(first, second)
        with self.assertRaises(ValueError):
            self.engine.dispatch({"op": "dictation.audio", "session_id": first, "seq": 0, "pcm16": "AAAA"})

    def test_socket_handler_streams_finish_frames(self):
        path = Path(self.temporary.name) / "engine.sock"
        server = Server(path, self.engine)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        audio = _sentences(25)
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(str(path))
            stream = client.makefile("rwb")

            def request(payload: dict) -> dict:
                stream.write(json.dumps(payload).encode() + b"\n")
                stream.flush()
                return json.loads(stream.readline())

            session_id = request({"id": 1, "op": "dictation.start"})["session_id"]
            step = SR // 2
            for seq, start in enumerate(range(0, len(audio), step)):
                reply = request({"id": 10 + seq, "op": "dictation.audio", "session_id": session_id, "seq": seq,
                                 "pcm16": self._pcm16(audio[start : start + step])})
                self.assertEqual(reply["id"], 10 + seq)
            self.assertTrue(_wait_until(lambda: self.engine._live[1].progress()["units_cleaned"] >= 2))
            stream.write(json.dumps({"id": 99, "op": "dictation.finish", "session_id": session_id}).encode() + b"\n")
            stream.flush()
            first = json.loads(stream.readline())
            self.assertEqual(first["id"], 99)
            self.assertIn("chunk", first)
            final = json.loads(stream.readline())
            self.assertEqual(final["id"], 99)
            self.assertTrue(final["done"])
            self.assertTrue(final["clean"].startswith(first["chunk"]))


if __name__ == "__main__":
    unittest.main()
