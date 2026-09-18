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
from undertone.streaming import StreamingTranscriber


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


if __name__ == "__main__":
    unittest.main()
