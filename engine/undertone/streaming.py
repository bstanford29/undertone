"""Bounded cumulative-prefix transcription while a recording is active.

The caller owns the timer that calls ``submit_snapshot``. Each submitted audio
value must be a cumulative prefix from the same recording. A worker serializes
all model calls and keeps at most one pending snapshot, replacing it with the
newest prefix when the model is busy. ``finish`` always submits the complete
recording so a dropped intermediate snapshot cannot drop content from the
final result.
"""
from __future__ import annotations

from dataclasses import dataclass
import threading
import time
from typing import Callable

import numpy as np

from .audio import SAMPLE_RATE


@dataclass(frozen=True)
class StreamingSnapshot:
    """One cumulative-prefix model attempt and its timing/error receipt."""

    sequence: int
    audio_samples: int
    submitted_at: float
    started_at: float | None
    finished_at: float | None
    text: str
    sample_rate: int = SAMPLE_RATE
    error: str | None = None

    @property
    def audio_seconds(self) -> float:
        return self.audio_samples / self.sample_rate

    @property
    def compute_ms(self) -> float:
        if self.started_at is None or self.finished_at is None:
            return 0.0
        return (self.finished_at - self.started_at) * 1000.0


@dataclass(frozen=True)
class StreamingRun:
    """Completed streaming state, including the complete audio for recovery."""

    text: str
    snapshots: tuple[StreamingSnapshot, ...]
    final_snapshot: StreamingSnapshot | None
    final_audio: np.ndarray
    error: str | None = None

    @property
    def final_error(self) -> str | None:
        return self.final_snapshot.error if self.final_snapshot else self.error


@dataclass
class _PendingSnapshot:
    sequence: int
    audio: np.ndarray
    vocab: str
    submitted_at: float


class StreamingTranscriber:
    """Run cumulative-prefix STT on one serialized, bounded worker.

    ``submit_snapshot`` is intentionally non-blocking. If a call is in flight,
    the one pending value is replaced by the latest cumulative prefix. The
    final call from ``finish`` is therefore the authoritative full recording.
    """

    def __init__(
        self,
        transcriber,
        *,
        interval_s: float = 5.0,
        sample_rate: int = SAMPLE_RATE,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if interval_s <= 0:
            raise ValueError("interval_s must be positive")
        self.transcriber = transcriber
        self.interval_s = interval_s
        self.sample_rate = sample_rate
        self._clock = clock
        self._condition = threading.Condition(threading.RLock())
        self._pending: _PendingSnapshot | None = None
        self._snapshots: list[StreamingSnapshot] = []
        self._sequence = 0
        self._worker: threading.Thread | None = None
        self._started = False
        self._closing = False
        self._final_audio = np.zeros(0, dtype=np.float32)

    def start(self) -> None:
        """Start the worker for one recording."""
        with self._condition:
            self._start_locked()

    def submit_snapshot(self, audio: np.ndarray, vocab: str = "") -> int | None:
        """Queue a non-empty cumulative prefix, replacing stale pending work."""
        samples = _copy_audio(audio)
        if samples.size == 0:
            return None
        with self._condition:
            if not self._started:
                self._start_locked()
            if self._closing:
                raise RuntimeError("streaming transcriber is closed")
            self._sequence += 1
            sequence = self._sequence
            self._pending = _PendingSnapshot(
                sequence=sequence,
                audio=samples,
                vocab=vocab,
                submitted_at=self._clock(),
            )
            self._condition.notify()
            return sequence

    def finish(
        self,
        final_audio: np.ndarray,
        vocab: str = "",
        *,
        timeout: float | None = 30.0,
    ) -> StreamingRun:
        """Submit the complete recording, close the worker, and return its run."""
        complete = _copy_audio(final_audio)
        if complete.size:
            with self._condition:
                if not self._started:
                    self._start_locked()
                self._final_audio = complete.copy()
            self.submit_snapshot(complete, vocab=vocab)
        else:
            with self._condition:
                self._final_audio = complete.copy()
        return self.close(timeout=timeout)

    def close(self, *, timeout: float | None = 30.0) -> StreamingRun:
        """Stop accepting work and wait for the bounded worker to drain."""
        with self._condition:
            if not self._started:
                return self._make_run()
            self._closing = True
            worker = self._worker
            self._condition.notify()
        if worker is not None:
            worker.join(timeout=timeout)
            if worker.is_alive():
                raise TimeoutError("streaming transcription worker did not close")
        return self._make_run()

    @property
    def final_audio(self) -> np.ndarray:
        with self._condition:
            return self._final_audio.copy()

    def _run_worker(self) -> None:
        while True:
            with self._condition:
                while self._pending is None and not self._closing:
                    self._condition.wait()
                if self._pending is None:
                    return
                pending = self._pending
                self._pending = None

            started_at = self._clock()
            text = ""
            error = None
            try:
                text = self.transcriber.transcribe(pending.audio, vocab=pending.vocab)
                text = (text or "").strip()
            except Exception as exc:  # keep the full audio available to recover
                error = type(exc).__name__
            finished_at = self._clock()
            snapshot = StreamingSnapshot(
                sequence=pending.sequence,
                audio_samples=int(pending.audio.size),
                submitted_at=pending.submitted_at,
                started_at=started_at,
                finished_at=finished_at,
                text=text,
                sample_rate=self.sample_rate,
                error=error,
            )
            with self._condition:
                self._snapshots.append(snapshot)

    def _start_locked(self) -> None:
        if self._started:
            raise RuntimeError("streaming transcriber is already started")
        self._pending = None
        self._snapshots = []
        self._sequence = 0
        self._final_audio = np.zeros(0, dtype=np.float32)
        self._closing = False
        self._started = True
        self._worker = threading.Thread(
            target=self._run_worker,
            name="undertone-stt-stream",
            daemon=True,
        )
        self._worker.start()

    def _make_run(self) -> StreamingRun:
        with self._condition:
            snapshots = tuple(self._snapshots)
            final_audio = self._final_audio.copy()
        final_snapshot = snapshots[-1] if snapshots else None
        successful = [item for item in snapshots if item.error is None]
        text = ""
        if successful and not (final_snapshot and final_snapshot.error):
            text = successful[-1].text
        error = final_snapshot.error if final_snapshot and final_snapshot.error else None
        return StreamingRun(
            text=text,
            snapshots=snapshots,
            final_snapshot=final_snapshot,
            final_audio=final_audio,
            error=error,
        )


def _copy_audio(audio: np.ndarray) -> np.ndarray:
    values = np.asarray(audio, dtype=np.float32)
    if values.ndim != 1:
        values = values.reshape(-1)
    return values.copy()
