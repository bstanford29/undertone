"""Transcription while a recording is active, in two modes.

``StreamingTranscriber`` (cumulative): the caller owns the timer that calls
``submit_snapshot``. Each submitted audio value must be a cumulative prefix
from the same recording. A worker serializes all model calls and keeps at most
one pending snapshot, replacing it with the newest prefix when the model is
busy. ``finish`` always submits the complete recording so a dropped
intermediate snapshot cannot drop content from the final result.

``PauseSplitTranscriber`` (pause-split): the same timer and cumulative prefix
contract, but a small energy VAD finds pauses in the new audio and each
finished speech chunk is transcribed exactly once, with the committed text
tail as context. Cuts land only inside silence, so no word is split. At
release only the audio after the last committed cut is transcribed. If any
chunk fails, ``finish`` transcribes the complete recording instead, so the
mode cannot drop content.
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
    chunks: tuple[StreamingChunk, ...] = ()
    fallback_used: bool = False

    @property
    def final_error(self) -> str | None:
        return self.final_snapshot.error if self.final_snapshot else self.error


@dataclass(frozen=True)
class StreamingChunk:
    """One pause-delimited slice transcribed exactly once."""

    sequence: int
    start_sample: int
    end_sample: int
    submitted_at: float
    started_at: float | None
    finished_at: float | None
    text: str
    sample_rate: int = SAMPLE_RATE
    error: str | None = None
    skipped_silent: bool = False
    final: bool = False

    @property
    def audio_seconds(self) -> float:
        return (self.end_sample - self.start_sample) / self.sample_rate

    @property
    def compute_ms(self) -> float:
        if self.started_at is None or self.finished_at is None:
            return 0.0
        return (self.finished_at - self.started_at) * 1000.0


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


DEFAULT_FRAME_MS = 20
DEFAULT_PAUSE_S = 0.3
DEFAULT_VAD_RMS = 0.004
DEFAULT_MIN_CHUNK_S = 1.0
CONTEXT_TAIL_WORDS = 40


def frame_rms(audio: np.ndarray, *, sample_rate: int = SAMPLE_RATE, frame_ms: int = DEFAULT_FRAME_MS) -> np.ndarray:
    """RMS per fixed frame; a trailing partial frame is dropped."""
    frame = max(1, int(sample_rate * frame_ms / 1000))
    count = len(audio) // frame
    if count == 0:
        return np.zeros(0, dtype=np.float32)
    frames = np.asarray(audio[: count * frame], dtype=np.float32).reshape(count, frame)
    return np.sqrt(np.mean(np.square(frames), axis=1))


def find_pauses(
    audio: np.ndarray,
    *,
    sample_rate: int = SAMPLE_RATE,
    frame_ms: int = DEFAULT_FRAME_MS,
    min_pause_s: float = DEFAULT_PAUSE_S,
    rms_threshold: float = DEFAULT_VAD_RMS,
) -> list[tuple[int, int]]:
    """Return [start, end) sample ranges that stay below the threshold long enough.

    A pause that is still running at the end of ``audio`` is included; its end
    is the last whole frame, so a cut inside it is still inside silence.
    """
    levels = frame_rms(audio, sample_rate=sample_rate, frame_ms=frame_ms)
    frame = max(1, int(sample_rate * frame_ms / 1000))
    min_frames = max(1, int(round(min_pause_s * 1000 / frame_ms)))
    quiet = levels < rms_threshold
    pauses: list[tuple[int, int]] = []
    run_start: int | None = None
    for index, is_quiet in enumerate(np.append(quiet, False)):
        if is_quiet and run_start is None:
            run_start = index
        elif not is_quiet and run_start is not None:
            if index - run_start >= min_frames:
                pauses.append((run_start * frame, index * frame))
            run_start = None
    return pauses


def context_tail(texts: list[str], *, words: int = CONTEXT_TAIL_WORDS) -> str:
    joined = " ".join(text.strip() for text in texts if text and text.strip())
    return " ".join(joined.split()[-words:])


class PauseSplitTranscriber:
    """Commit speech chunks at pauses while recording; only the tail at release.

    Audio between cuts is covered exactly once. ``submit_snapshot`` runs the
    VAD on the new audio only and queues finished chunks on one serialized
    worker in order, so each chunk sees the text before it as context.
    """

    def __init__(
        self,
        transcriber,
        *,
        sample_rate: int = SAMPLE_RATE,
        min_pause_s: float = DEFAULT_PAUSE_S,
        rms_threshold: float = DEFAULT_VAD_RMS,
        min_chunk_s: float = DEFAULT_MIN_CHUNK_S,
        frame_ms: int = DEFAULT_FRAME_MS,
        clock: Callable[[], float] = time.monotonic,
        on_chunk: Callable[[StreamingChunk], None] | None = None,
    ) -> None:
        if min_pause_s <= 0:
            raise ValueError("min_pause_s must be positive")
        self.transcriber = transcriber
        self.sample_rate = sample_rate
        self.min_pause_s = min_pause_s
        self.rms_threshold = rms_threshold
        self.min_chunk_s = min_chunk_s
        self.frame_ms = frame_ms
        # Called on the worker thread, outside the lock, after each transcribed
        # chunk completes and only when the chunk still counts (a chunk that
        # ``finish`` re-covered with a short tail is never reported).
        self.on_chunk = on_chunk
        self._clock = clock
        self._condition = threading.Condition(threading.RLock())
        self._queue: list[tuple[StreamingChunk, np.ndarray, str]] = []
        self._chunks: list[StreamingChunk] = []
        self._last_chunk: StreamingChunk | None = None
        self._superseded: set[int] = set()
        self._committed_end = 0
        self._sequence = 0
        self._worker: threading.Thread | None = None
        self._started = False
        self._closing = False
        self._final_audio = np.zeros(0, dtype=np.float32)

    def start(self) -> None:
        with self._condition:
            self._start_locked()

    @property
    def committed_samples(self) -> int:
        with self._condition:
            return self._committed_end

    def submit_snapshot(self, audio: np.ndarray, vocab: str = "") -> int | None:
        """Commit every chunk that ends in a pause inside the new audio."""
        samples = _copy_audio(audio)
        committed = 0
        with self._condition:
            if not self._started:
                self._start_locked()
            if self._closing:
                raise RuntimeError("streaming transcriber is closed")
            start = self._committed_end
            if samples.size <= start:
                return None
            for cut in self._cuts(samples, start):
                self._enqueue_locked(samples[start:cut], start, cut, vocab, final=False)
                start = cut
                committed += 1
            self._condition.notify()
        return committed or None

    def finish(
        self,
        final_audio: np.ndarray,
        vocab: str = "",
        *,
        timeout: float | None = 30.0,
    ) -> StreamingRun:
        """Transcribe only the uncommitted tail, then fall back on any error."""
        complete = _copy_audio(final_audio)
        with self._condition:
            if not self._started:
                self._start_locked()
            self._final_audio = complete.copy()
            start = min(self._committed_end, complete.size)
            tail = complete[start:]
            previous = self._last_chunk
            if (
                0 < tail.size < int(self.min_chunk_s * self.sample_rate)
                and previous is not None
                and not self._is_silent(tail)
            ):
                # A tail too short for whisper's duration gate could lose the
                # last word. Re-cover the previous chunk with it instead and
                # discard that chunk's own result, so coverage stays exact.
                self._queue = [item for item in self._queue if item[0].sequence != previous.sequence]
                self._superseded.add(previous.sequence)
                start = previous.start_sample
            if complete.size > start:
                self._enqueue_locked(complete[start:], start, complete.size, vocab, final=True)
                self._condition.notify()
        run = self.close(timeout=timeout)
        if run.error is None or complete.size == 0:
            return run
        # Never drop content: a failed chunk means the whole recording is
        # transcribed once more from the retained audio.
        started_at = self._clock()
        try:
            text = (self.transcriber.transcribe(complete, vocab=vocab) or "").strip()
            error = None
        except Exception as exc:
            text = ""
            error = type(exc).__name__
        finished_at = self._clock()
        fallback = StreamingChunk(
            sequence=run.chunks[-1].sequence + 1 if run.chunks else 1,
            start_sample=0,
            end_sample=int(complete.size),
            submitted_at=started_at,
            started_at=started_at,
            finished_at=finished_at,
            text=text,
            sample_rate=self.sample_rate,
            error=error,
            final=True,
        )
        return StreamingRun(
            text=text,
            snapshots=(),
            final_snapshot=None,
            final_audio=complete,
            error=error,
            chunks=run.chunks + (fallback,),
            fallback_used=True,
        )

    def close(self, *, timeout: float | None = 30.0) -> StreamingRun:
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

    def _cuts(self, samples: np.ndarray, start: int) -> list[int]:
        """Cut points inside pauses after ``start``; each chunk long enough."""
        pauses = find_pauses(
            samples[start:],
            sample_rate=self.sample_rate,
            frame_ms=self.frame_ms,
            min_pause_s=self.min_pause_s,
            rms_threshold=self.rms_threshold,
        )
        min_chunk = int(self.min_chunk_s * self.sample_rate)
        cuts: list[int] = []
        last = start
        for pause_start, pause_end in pauses:
            cut = start + (pause_start + pause_end) // 2
            if cut - last < min_chunk:
                continue
            cuts.append(cut)
            last = cut
        return cuts

    def _is_silent(self, clip: np.ndarray) -> bool:
        levels = frame_rms(clip, sample_rate=self.sample_rate, frame_ms=self.frame_ms)
        return bool(np.all(levels < self.rms_threshold))

    def _enqueue_locked(self, clip: np.ndarray, start: int, end: int, vocab: str, *, final: bool) -> None:
        self._sequence += 1
        silent = self._is_silent(clip)
        chunk = StreamingChunk(
            sequence=self._sequence,
            start_sample=start,
            end_sample=end,
            submitted_at=self._clock(),
            started_at=None,
            finished_at=None,
            text="",
            sample_rate=self.sample_rate,
            skipped_silent=silent and not final,
            final=final,
        )
        self._committed_end = end
        self._last_chunk = chunk
        if chunk.skipped_silent:
            # Nothing was said: no model call, but the span is still covered.
            self._chunks.append(chunk)
            return
        self._queue.append((chunk, clip.copy(), vocab))

    def _run_worker(self) -> None:
        while True:
            with self._condition:
                while not self._queue and not self._closing:
                    self._condition.wait()
                if not self._queue:
                    return
                chunk, clip, vocab = self._queue.pop(0)
                context = context_tail(
                    [item.text for item in self._chunks if item.error is None and item.sequence not in self._superseded]
                )

            started_at = self._clock()
            text = ""
            error = None
            try:
                text = self.transcriber.transcribe(clip, vocab=vocab, context=context)
                text = (text or "").strip()
            except Exception as exc:
                error = type(exc).__name__
            finished_at = self._clock()
            done = StreamingChunk(
                sequence=chunk.sequence,
                start_sample=chunk.start_sample,
                end_sample=chunk.end_sample,
                submitted_at=chunk.submitted_at,
                started_at=started_at,
                finished_at=finished_at,
                text=text,
                sample_rate=chunk.sample_rate,
                error=error,
                final=chunk.final,
            )
            with self._condition:
                self._chunks.append(done)
                report = self.on_chunk if done.sequence not in self._superseded else None
            if report is not None:
                report(done)

    def _start_locked(self) -> None:
        if self._started:
            raise RuntimeError("streaming transcriber is already started")
        self._queue = []
        self._chunks = []
        self._last_chunk = None
        self._superseded = set()
        self._committed_end = 0
        self._sequence = 0
        self._final_audio = np.zeros(0, dtype=np.float32)
        self._closing = False
        self._started = True
        self._worker = threading.Thread(
            target=self._run_worker,
            name="undertone-stt-pause-split",
            daemon=True,
        )
        self._worker.start()

    def _make_run(self) -> StreamingRun:
        with self._condition:
            chunks = tuple(
                sorted(
                    (item for item in self._chunks if item.sequence not in self._superseded),
                    key=lambda item: item.sequence,
                )
            )
            final_audio = self._final_audio.copy()
        failed = [chunk for chunk in chunks if chunk.error is not None]
        error = failed[0].error if failed else None
        text = "" if error else " ".join(chunk.text for chunk in chunks if chunk.text).strip()
        return StreamingRun(
            text=text,
            snapshots=(),
            final_snapshot=None,
            final_audio=final_audio,
            error=error,
            chunks=chunks,
        )


def _copy_audio(audio: np.ndarray) -> np.ndarray:
    values = np.asarray(audio, dtype=np.float32)
    if values.ndim != 1:
        values = values.reshape(-1)
    return values.copy()
