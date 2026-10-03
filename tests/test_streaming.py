from __future__ import annotations

import threading
import time
import unittest
from pathlib import Path
import sys
from unittest.mock import patch

import numpy as np

from undertone.audio import Recorder
from undertone.stt import DEFAULT_STT_MODEL, Transcriber
from undertone.streaming import PauseSplitTranscriber, StreamingTranscriber, find_pauses


class FakeTranscriber:
    def __init__(self, *, started: threading.Event | None = None, release: threading.Event | None = None, fail=False, fail_sizes=()):
        self.started = started
        self.release = release
        self.fail = fail
        self.fail_sizes = set(fail_sizes)
        self.calls: list[tuple[int, str]] = []
        self.active = 0
        self.max_active = 0
        self._lock = threading.Lock()

    def transcribe(self, audio, vocab=""):
        with self._lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
            self.calls.append((len(audio), vocab))
        if self.started:
            self.started.set()
        if self.release:
            self.release.wait(timeout=2)
        if self.fail or len(audio) in self.fail_sizes:
            with self._lock:
                self.active -= 1
            raise RuntimeError("synthetic model failure")
        with self._lock:
            self.active -= 1
        return f"prefix-{len(audio)}"


class RecorderSnapshotTests(unittest.TestCase):
    def test_snapshot_is_complete_and_does_not_expose_chunk_list(self):
        recorder = Recorder()
        first = np.array([1, 2], dtype=np.float32)
        second = np.array([3], dtype=np.float32)
        recorder._chunks = [first, second]

        snapshot = recorder.snapshot()
        first[0] = 99

        np.testing.assert_array_equal(snapshot, [1, 2, 3])

    def test_empty_snapshot_is_safe(self):
        recorder = Recorder()
        self.assertEqual(recorder.snapshot().size, 0)

    def test_snapshot_can_run_while_callback_appends(self):
        recorder = Recorder()
        chunk = np.ones((2, 1), dtype=np.float32)

        def append_chunks():
            for _ in range(100):
                recorder._callback(chunk, 2, None, None)

        appender = threading.Thread(target=append_chunks)
        appender.start()
        sizes = []
        while appender.is_alive():
            sizes.append(recorder.snapshot().size)
        appender.join()
        sizes.append(recorder.snapshot().size)

        self.assertEqual(sizes[-1], 200)
        self.assertTrue(all(left <= right for left, right in zip(sizes, sizes[1:])))


class SttLoadingTests(unittest.TestCase):
    def test_transcriber_defaults_to_cached_only_model_resolution(self):
        with patch("undertone.stt._resolve_model", return_value="/cached/model") as resolve:
            transcriber = Transcriber()

        self.assertEqual(transcriber.model, "/cached/model")
        resolve.assert_called_once_with(DEFAULT_STT_MODEL, local_files_only=True)

    def test_model_resolution_requests_local_files_only(self):
        with patch("huggingface_hub.snapshot_download", return_value="/cached/model") as download:
            transcriber = Transcriber("org/model", local_files_only=True)

        self.assertEqual(transcriber.model, "/cached/model")
        download.assert_called_once_with(repo_id="org/model", local_files_only=True)

    def test_empty_audio_returns_without_importing_mlx(self):
        transcriber = Transcriber(str(Path(__file__).parent), local_files_only=True)
        with patch.dict(sys.modules, {"mlx_whisper": None}):
            self.assertEqual(transcriber.transcribe(np.zeros(0, dtype=np.float32)), "")


class StreamingTranscriberTests(unittest.TestCase):
    def test_latest_pending_prefix_is_bounded_and_final_prefix_is_complete(self):
        started = threading.Event()
        release = threading.Event()
        fake = FakeTranscriber(started=started, release=release)
        stream = StreamingTranscriber(fake)

        stream.start()
        self.assertEqual(stream.submit_snapshot(np.ones(2), vocab="Qwen"), 1)
        self.assertTrue(started.wait(timeout=2))
        self.assertEqual(stream.submit_snapshot(np.ones(3)), 2)
        self.assertEqual(stream.submit_snapshot(np.ones(4)), 3)

        release.set()
        run = stream.finish(np.ones(7), vocab="Qwen")

        self.assertEqual(fake.max_active, 1)
        self.assertEqual([size for size, _ in fake.calls], [2, 7])
        self.assertEqual(run.text, "prefix-7")
        self.assertEqual(run.final_snapshot.audio_samples, 7)
        self.assertEqual(len(run.snapshots), 2)

    def test_empty_audio_does_not_call_model_or_hallucinate(self):
        fake = FakeTranscriber()
        stream = StreamingTranscriber(fake)

        self.assertIsNone(stream.submit_snapshot(np.zeros(0, dtype=np.float32)))
        run = stream.finish(np.zeros(0, dtype=np.float32))

        self.assertEqual(fake.calls, [])
        self.assertEqual(run.text, "")
        self.assertIsNone(run.final_snapshot)
        self.assertEqual(run.final_audio.size, 0)

    def test_model_error_keeps_complete_audio_for_recovery(self):
        fake = FakeTranscriber(fail=True)
        stream = StreamingTranscriber(fake)
        complete = np.arange(6, dtype=np.float32)

        run = stream.finish(complete, vocab="Ollama")

        self.assertEqual(run.final_error, "RuntimeError")
        np.testing.assert_array_equal(run.final_audio, complete)
        np.testing.assert_array_equal(stream.final_audio, complete)
        self.assertEqual(run.text, "")

    def test_final_error_never_returns_an_older_partial_prefix(self):
        started = threading.Event()
        release = threading.Event()
        fake = FakeTranscriber(started=started, release=release, fail_sizes={7})
        stream = StreamingTranscriber(fake)
        stream.start()
        stream.submit_snapshot(np.ones(2))
        self.assertTrue(started.wait(timeout=2))
        release.set()
        first = stream.finish(np.ones(7))

        self.assertEqual(first.final_error, "RuntimeError")
        self.assertEqual(first.text, "")

    def test_close_drains_pending_work_without_race(self):
        fake = FakeTranscriber()
        stream = StreamingTranscriber(fake)
        stream.start()
        stream.submit_snapshot(np.ones(5))

        run = stream.close(timeout=2)

        self.assertEqual(len(run.snapshots), 1)
        self.assertEqual(run.snapshots[0].audio_samples, 5)
        with self.assertRaises(RuntimeError):
            stream.submit_snapshot(np.ones(1))

    def test_close_timeout_is_bounded_and_can_be_completed_later(self):
        started = threading.Event()
        release = threading.Event()
        fake = FakeTranscriber(started=started, release=release)
        stream = StreamingTranscriber(fake)
        stream.start()
        stream.submit_snapshot(np.ones(5))
        self.assertTrue(started.wait(timeout=2))

        with self.assertRaises(TimeoutError):
            stream.close(timeout=0.001)

        release.set()
        run = stream.close(timeout=2)
        self.assertEqual(len(run.snapshots), 1)


SR = 16000


def _speech(seconds: float, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return (rng.standard_normal(int(SR * seconds)) * 0.1).astype(np.float32)


def _silence(seconds: float) -> np.ndarray:
    return np.zeros(int(SR * seconds), dtype=np.float32)


def _recording(*parts: np.ndarray) -> np.ndarray:
    return np.concatenate(parts).astype(np.float32)


class ChunkFake:
    """Records every slice it is asked to transcribe, with its context."""

    def __init__(self, *, fail_on_call: int | None = None):
        self.calls: list[dict] = []
        self.fail_on_call = fail_on_call
        self._lock = threading.Lock()

    def transcribe(self, audio, vocab="", context=""):
        with self._lock:
            self.calls.append({"samples": len(audio), "vocab": vocab, "context": context, "audio": np.asarray(audio).copy()})
            index = len(self.calls)
        if self.fail_on_call == index:
            raise RuntimeError("synthetic model failure")
        return f"chunk{index} of {len(audio)}"


def _assert_in_silence(audio: np.ndarray, sample: int, pad: int = SR // 100):
    window = audio[max(0, sample - pad): sample + pad]
    assert np.all(np.abs(window) < 1e-6), f"cut at {sample} is not inside silence"


class FindPausesTests(unittest.TestCase):
    def test_short_gaps_are_ignored_and_long_gaps_found(self):
        audio = _recording(_speech(1.0), _silence(0.1), _speech(1.0), _silence(0.5), _speech(0.5), _silence(0.4))
        pauses = find_pauses(audio, min_pause_s=0.3)
        self.assertEqual(len(pauses), 2)
        for start, end in pauses:
            self.assertGreaterEqual(end - start, int(0.3 * SR))
            self.assertTrue(np.all(audio[start:end] == 0))

    def test_no_speech_means_one_pause(self):
        self.assertEqual(find_pauses(_silence(1.0), min_pause_s=0.3), [(0, SR)])
        self.assertEqual(find_pauses(_speech(1.0), min_pause_s=0.3), [])


class PauseSplitTranscriberTests(unittest.TestCase):
    def _run(self, audio: np.ndarray, snapshot_s: float, fake: ChunkFake, **kwargs):
        stream = PauseSplitTranscriber(fake, **kwargs)
        stream.start()
        step = int(snapshot_s * SR)
        for end in range(step, len(audio), step):
            stream.submit_snapshot(audio[:end], vocab="Ollama, Qwen")
        run = stream.finish(audio, vocab="Ollama, Qwen")
        return stream, run

    def test_cuts_fall_in_silence_and_audio_is_covered_exactly_once(self):
        audio = _recording(
            _speech(2.0, 1), _silence(0.5), _speech(1.5, 2), _silence(0.2), _speech(1.0, 3),
            _silence(0.6), _speech(2.5, 4), _silence(0.4), _speech(0.8, 5),
        )
        fake = ChunkFake()
        stream, run = self._run(audio, 1.0, fake)

        self.assertIsNone(run.error)
        self.assertFalse(run.fallback_used)
        chunks = run.chunks
        self.assertGreater(len(chunks), 2)
        # Coverage: contiguous, starting at 0, ending at the last sample.
        self.assertEqual(chunks[0].start_sample, 0)
        self.assertEqual(chunks[-1].end_sample, len(audio))
        for left, right in zip(chunks, chunks[1:]):
            self.assertEqual(left.end_sample, right.start_sample)
        # Every interior boundary is inside silence (0.2 s gap is too short to cut).
        for chunk in chunks[:-1]:
            _assert_in_silence(audio, chunk.end_sample)
        self.assertTrue(chunks[-1].final)
        # The model saw exactly the audio of each non-silent chunk, in order.
        spoken = [chunk for chunk in chunks if not chunk.skipped_silent]
        self.assertEqual(len(fake.calls), len(spoken))
        for call, chunk in zip(fake.calls, spoken):
            np.testing.assert_array_equal(call["audio"], audio[chunk.start_sample:chunk.end_sample])
        self.assertEqual(run.text, " ".join(chunk.text for chunk in spoken))

    def test_release_transcribes_only_the_tail_after_the_last_cut(self):
        audio = _recording(_speech(3.0, 1), _silence(0.5), _speech(3.0, 2), _silence(0.5), _speech(1.0, 3))
        fake = ChunkFake()
        stream = PauseSplitTranscriber(fake)
        stream.start()
        stream.submit_snapshot(audio[: int(4.0 * SR)], vocab="")
        stream.submit_snapshot(audio[: int(7.5 * SR)], vocab="")
        committed = stream.committed_samples
        self.assertGreater(committed, int(6.0 * SR))
        run = stream.finish(audio, vocab="")

        tail = fake.calls[-1]
        self.assertEqual(tail["samples"], len(audio) - committed)
        self.assertEqual(run.chunks[-1].start_sample, committed)
        self.assertTrue(run.chunks[-1].final)
        self.assertLess(tail["samples"], int(2.0 * SR))

    def test_committed_text_is_passed_as_context_not_vocab(self):
        audio = _recording(_speech(2.0, 1), _silence(0.5), _speech(2.0, 2), _silence(0.5), _speech(1.0, 3))
        fake = ChunkFake()
        self._run(audio, 1.0, fake)
        self.assertEqual(fake.calls[0]["context"], "")
        self.assertEqual(fake.calls[1]["context"], "chunk1 of %d" % fake.calls[0]["samples"])
        self.assertTrue(fake.calls[2]["context"].endswith("chunk2 of %d" % fake.calls[1]["samples"]))
        self.assertTrue(all(call["vocab"] == "Ollama, Qwen" for call in fake.calls))

    def test_chunk_error_falls_back_to_full_recording(self):
        audio = _recording(_speech(2.0, 1), _silence(0.5), _speech(2.0, 2), _silence(0.5), _speech(1.0, 3))
        fake = ChunkFake(fail_on_call=2)
        _, run = self._run(audio, 1.0, fake)

        self.assertTrue(run.fallback_used)
        self.assertIsNone(run.error)
        self.assertIsNone(run.final_error)
        self.assertEqual(fake.calls[-1]["samples"], len(audio))
        self.assertEqual(run.text, f"chunk{len(fake.calls)} of {len(audio)}")
        np.testing.assert_array_equal(run.final_audio, audio)

    def test_fallback_failure_keeps_audio_and_reports_error(self):
        audio = _recording(_speech(2.0, 1), _silence(0.5), _speech(1.0, 2))

        class AlwaysFails(ChunkFake):
            def transcribe(self, audio, vocab="", context=""):
                raise RuntimeError("down")

        _, run = self._run(audio, 1.0, AlwaysFails())
        self.assertEqual(run.final_error, "RuntimeError")
        self.assertEqual(run.text, "")
        np.testing.assert_array_equal(run.final_audio, audio)

    def test_continuous_speech_without_pauses_is_one_release_call(self):
        audio = _speech(6.0, 7)
        fake = ChunkFake()
        _, run = self._run(audio, 1.0, fake)
        self.assertEqual(len(fake.calls), 1)
        self.assertEqual(fake.calls[0]["samples"], len(audio))
        self.assertEqual(run.chunks[0].start_sample, 0)

    def test_short_final_tail_recovers_the_previous_chunk_instead_of_gating_it(self):
        # A last word of 0.3 s after a pause is under the STT duration gate.
        audio = _recording(_speech(2.0, 1), _silence(0.5), _speech(0.3, 2))
        fake = ChunkFake()
        stream = PauseSplitTranscriber(fake)
        stream.start()
        stream.submit_snapshot(audio[: int(2.4 * SR)], vocab="")
        committed = stream.committed_samples
        self.assertGreater(committed, int(2.0 * SR))
        run = stream.finish(audio, vocab="")

        self.assertIsNone(run.error)
        self.assertEqual(len(run.chunks), 1)
        self.assertEqual((run.chunks[0].start_sample, run.chunks[0].end_sample), (0, len(audio)))
        self.assertEqual(fake.calls[-1]["samples"], len(audio))
        self.assertEqual(run.text, f"chunk{len(fake.calls)} of {len(audio)}")

    def test_silent_short_tail_is_not_merged(self):
        audio = _recording(_speech(2.0, 1), _silence(0.5), _silence(0.3))
        fake = ChunkFake()
        stream = PauseSplitTranscriber(fake)
        stream.start()
        stream.submit_snapshot(audio[: int(2.4 * SR)], vocab="")
        run = stream.finish(audio, vocab="")
        self.assertEqual(len(run.chunks), 2)
        self.assertEqual(run.chunks[-1].end_sample, len(audio))

    def test_backend_without_prompt_support_still_streams(self):
        class NoPromptFake(ChunkFake):
            # Parakeet-style: accepts and ignores vocab and context.
            def transcribe(self, audio, vocab="", context=""):
                return super().transcribe(audio, vocab="", context="")

        audio = _recording(_speech(2.0, 1), _silence(0.5), _speech(2.0, 2))
        fake = NoPromptFake()
        _, run = self._run(audio, 1.0, fake)
        self.assertIsNone(run.error)
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual(run.chunks[-1].end_sample, len(audio))

    def test_empty_recording_makes_no_calls(self):
        fake = ChunkFake()
        stream = PauseSplitTranscriber(fake)
        self.assertIsNone(stream.submit_snapshot(np.zeros(0, dtype=np.float32)))
        run = stream.finish(np.zeros(0, dtype=np.float32))
        self.assertEqual(fake.calls, [])
        self.assertEqual(run.text, "")
        self.assertIsNone(run.error)


if __name__ == "__main__":
    unittest.main()
