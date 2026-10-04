"""Live dictation: transcribe at pauses and clean in sentence units while the
hold key is down, so release only has to finish the last few words.

Two workers run while the app streams audio in:

``WindowedTranscriber`` cuts the recording only inside pauses (an energy VAD
whose threshold adapts to the room). Each chunk's words are decoded inside a
window that also holds a few seconds of the audio before and after it, and
only the words whose timestamps fall inside the chunk are kept. The chunk is
therefore never an utterance start or end for the model, so punctuation and
capitalization at its edges are decided with real context. Every sample is
covered by exactly one chunk and no word straddles a cut.

``LiveDictation`` groups finished chunk texts into cleanup units that end at a
sentence boundary (or at a word cap) and cleans each unit once, with the
cleaned text before it as reference context. ``finish`` first emits the
cleaned text that is already final as one streamed chunk, so the app can type
it the moment the key is released, then decodes only the audio after the last
cut, cleans that last unit, and returns the whole result. The returned
``clean`` always starts with the emitted text.

Never drop content: the complete recording is kept. If the streamed audio is
incomplete, or a chunk failed before anything was emitted, ``finish`` runs the
non-live path instead (one transcription and one cleanup of the complete
recording). A cleanup exception keeps the unit's raw text with basic
capitalization and marks the guard, exactly as ``clean_result`` does.
"""
from __future__ import annotations

import logging
import re
import threading
import time
from dataclasses import dataclass, replace
from typing import Any, Callable

import numpy as np

from .audio import SAMPLE_RATE
from .cleanup import _raw_fallback_text
from .streaming import DEFAULT_FRAME_MS, DEFAULT_VAD_RMS, context_tail, find_pauses, frame_rms
from .stt import Word, restore_sound_alikes

logger = logging.getLogger("undertone.live")

DEFAULT_MIN_PAUSE_S = 0.4
DEFAULT_MIN_CHUNK_S = 1.0
# Without a pause this long, a cut is forced at the quietest point so the
# cleanup pipeline keeps moving during one long breathless sentence.
DEFAULT_MAX_CHUNK_S = 12.0
LEFT_CONTEXT_S = 4.0
RIGHT_CONTEXT_S = 1.0
MAX_RIGHT_CONTEXT_S = 3.0
FORCED_CUT_WINDOW_MS = 100
FORCED_CUT_TAIL_GUARD_S = 0.5

DEFAULT_MIN_UNIT_WORDS = 8
DEFAULT_MAX_UNIT_WORDS = 40
SENTENCE_END = (".", "?", "!")
# Reference text sent with each unit: the cleaned text so far (preceded by the
# app's own text before the caret) and a little of what follows the caret.
# Both are deliberately smaller than the 2000-char protocol cap so the prompt
# stays short for every unit.
CONTEXT_BEFORE_CHARS = 600
CONTEXT_AFTER_CHARS = 300
# The energy VAD adapts to the room: the threshold is a multiple of a low
# percentile of frame RMS, floored at the fixed default and capped so quiet
# speech is never read as a pause.
VAD_FLOOR_PERCENTILE = 10
VAD_FLOOR_GAIN = 2.5
VAD_MAX_RMS = 0.02
VAD_ADAPT_MIN_S = 1.0
# Streamed audio must match the recording on disk this closely to be used as
# the complete recording; otherwise the file wins and the non-live path runs.
AUDIO_MATCH_TOLERANCE_S = 0.25
INITIAL_BUFFER_SECONDS = 30


def _join(parts: list[str]) -> str:
    return " ".join(part.strip() for part in parts if part and part.strip()).strip()


def _ends_sentence(text: str) -> bool:
    stripped = text.rstrip()
    return bool(stripped) and stripped.endswith(SENTENCE_END)


def _normalize_word(text: str) -> str:
    return "".join(char for char in text.lower() if char.isalnum())


# Phrases that take back something already said. When one opens a chunk cut at
# a pause, it usually refers to text in an earlier unit, which per-unit cleanup
# cannot edit, so release falls back to cleaning the whole recording at once.
CORRECTION_PHRASES = (
    "no wait", "wait no", "scratch that", "strike that", "i mean", "i meant",
    "make that", "delete that", "never mind", "nevermind", "let me rephrase",
    "rephrase that", "start over", "start again", "undo that", "actually no",
)
CORRECTION_LEAD_WORDS = 4
_CORRECTION_RE = re.compile(
    r"\b(?:" + "|".join(re.escape(phrase) for phrase in CORRECTION_PHRASES) + r")\b"
)


def opens_with_correction(text: str, *, lead_words: int = CORRECTION_LEAD_WORDS) -> bool:
    """True when one of the correction phrases sits in the first few words."""
    lead = " ".join(_normalize_word(word) for word in text.split()[:lead_words])
    return bool(_CORRECTION_RE.search(lead))


def adaptive_rms_threshold(
    levels: np.ndarray,
    *,
    base: float = DEFAULT_VAD_RMS,
    minimum_frames: int = int(VAD_ADAPT_MIN_S * 1000 / DEFAULT_FRAME_MS),
) -> float:
    """Pause threshold for this room: a multiple of the quiet-frame level."""
    if levels.size < minimum_frames:
        return base
    floor = float(np.percentile(levels, VAD_FLOOR_PERCENTILE))
    return float(min(VAD_MAX_RMS, max(base, floor * VAD_FLOOR_GAIN)))


def plan_units(
    texts: list[str],
    *,
    min_words: int = DEFAULT_MIN_UNIT_WORDS,
    max_words: int = DEFAULT_MAX_UNIT_WORDS,
) -> list[int]:
    """Lengths (in chunks) of the complete units at the front of ``texts``.

    A unit closes at the first chunk where the accumulated text has at least
    ``min_words`` words and ends a sentence, or reaches ``max_words``.
    Trailing chunks that close no unit are left for later.
    """
    units: list[int] = []
    words = 0
    count = 0
    for text in texts:
        count += 1
        words += len(text.split())
        if (words >= min_words and _ends_sentence(text)) or words >= max_words:
            units.append(count)
            words = 0
            count = 0
    return units


# ----- speech chunks ----------------------------------------------------------


@dataclass(frozen=True)
class LiveChunk:
    """One pause-delimited span of the recording and, once decoded, its words."""

    sequence: int
    start_sample: int
    end_sample: int
    forced_cut: bool = False
    final: bool = False
    text: str | None = None
    words: tuple[Word, ...] = ()
    window_start: int = 0
    window_end: int = 0
    started_at: float | None = None
    finished_at: float | None = None
    error: str | None = None
    sample_rate: int = SAMPLE_RATE

    @property
    def done(self) -> bool:
        return self.text is not None or self.error is not None

    @property
    def audio_seconds(self) -> float:
        return (self.end_sample - self.start_sample) / self.sample_rate

    @property
    def compute_ms(self) -> float:
        if self.started_at is None or self.finished_at is None:
            return 0.0
        return (self.finished_at - self.started_at) * 1000.0


@dataclass
class _WindowJob:
    targets: list[int]
    audio: np.ndarray
    window_start: int
    window_end: int


@dataclass(frozen=True)
class WindowedRun:
    chunks: tuple[LiveChunk, ...]
    boundary_disagreements: int
    windows: int

    @property
    def error(self) -> str | None:
        failed = [chunk.error for chunk in self.chunks if chunk.error is not None]
        return failed[0] if failed else None

    @property
    def text(self) -> str:
        return _join([chunk.text or "" for chunk in self.chunks])


def assign_words(words: list[Word], *, window_start: int, start: int, end: int, sample_rate: int) -> list[Word]:
    """Words whose start time lands inside [start, end) of the recording."""
    kept: list[Word] = []
    for word in words:
        position = window_start + int(round(word.start * sample_rate))
        if start <= position < end:
            kept.append(word)
    return kept


def quietest_cut(
    audio: np.ndarray,
    *,
    earliest: int,
    latest: int,
    sample_rate: int = SAMPLE_RATE,
    window_ms: int = FORCED_CUT_WINDOW_MS,
) -> int | None:
    """Middle of the quietest ``window_ms`` span between ``earliest`` and ``latest``."""
    window = max(1, int(sample_rate * window_ms / 1000))
    if latest - earliest < window:
        return None
    region = np.asarray(audio[earliest:latest], dtype=np.float32)
    squared = np.square(region)
    energy = np.convolve(squared, np.ones(window, dtype=np.float32), mode="valid")
    offset = int(np.argmin(energy))
    return earliest + offset + window // 2


class WindowedTranscriber:
    """Pause-cut chunks, each decoded inside a window of its neighbours."""

    def __init__(
        self,
        transcriber,
        *,
        sample_rate: int = SAMPLE_RATE,
        vocab: str = "",
        min_pause_s: float = DEFAULT_MIN_PAUSE_S,
        rms_threshold: float = DEFAULT_VAD_RMS,
        min_chunk_s: float = DEFAULT_MIN_CHUNK_S,
        max_chunk_s: float = DEFAULT_MAX_CHUNK_S,
        frame_ms: int = DEFAULT_FRAME_MS,
        left_context_s: float = LEFT_CONTEXT_S,
        right_context_s: float = RIGHT_CONTEXT_S,
        max_right_context_s: float = MAX_RIGHT_CONTEXT_S,
        clock: Callable[[], float] = time.monotonic,
        on_chunk: Callable[[LiveChunk], None] | None = None,
    ) -> None:
        if min_pause_s <= 0 or min_chunk_s <= 0 or max_chunk_s < min_chunk_s:
            raise ValueError("invalid chunking bounds")
        self.transcriber = transcriber
        self.sample_rate = sample_rate
        self.vocab = vocab
        self.min_pause_s = min_pause_s
        self.rms_threshold = rms_threshold
        self.min_chunk_s = min_chunk_s
        self.max_chunk_s = max_chunk_s
        self.frame_ms = frame_ms
        self.left_context = int(left_context_s * sample_rate)
        self.right_context = int(right_context_s * sample_rate)
        self.max_right_context = int(max_right_context_s * sample_rate)
        self.on_chunk = on_chunk
        self._clock = clock
        self._condition = threading.Condition(threading.RLock())
        self._chunks: list[LiveChunk] = []
        self._next_to_schedule = 0
        self._jobs: list[_WindowJob] = []
        self._peeked: dict[int, str] = {}
        self._worker: threading.Thread | None = None
        self._closing = False
        self._finished = False
        self.boundary_disagreements = 0
        self.windows = 0

    @property
    def committed_samples(self) -> int:
        with self._condition:
            return self._chunks[-1].end_sample if self._chunks else 0

    @property
    def chunks(self) -> tuple[LiveChunk, ...]:
        with self._condition:
            return tuple(self._chunks)

    # ----- cutting ------------------------------------------------------

    def submit(self, audio: np.ndarray) -> int:
        """Cut the uncommitted part of the cumulative ``audio`` at completed pauses."""
        samples = np.asarray(audio, dtype=np.float32).reshape(-1)
        with self._condition:
            if self._finished:
                raise RuntimeError("windowed transcriber is finished")
            added = 0
            for cut, forced in self._new_cuts_locked(samples):
                start = self._chunks[-1].end_sample if self._chunks else 0
                self._chunks.append(LiveChunk(
                    sequence=len(self._chunks) + 1, start_sample=start, end_sample=cut,
                    forced_cut=forced, sample_rate=self.sample_rate,
                ))
                added += 1
            self._schedule_ready_locked(samples, final=False)
        return added

    def _new_cuts_locked(self, samples: np.ndarray) -> list[tuple[int, bool]]:
        start = self._chunks[-1].end_sample if self._chunks else 0
        if samples.size <= start:
            return []
        uncommitted = samples[start:]
        frame = max(1, int(self.sample_rate * self.frame_ms / 1000))
        min_chunk = int(self.min_chunk_s * self.sample_rate)
        cuts: list[tuple[int, bool]] = []
        last = start
        for pause_start, pause_end in find_pauses(
            uncommitted, sample_rate=self.sample_rate, frame_ms=self.frame_ms,
            min_pause_s=self.min_pause_s, rms_threshold=self.rms_threshold,
        ):
            if pause_end >= uncommitted.size - frame:
                # Still inside this pause: cut once speech resumes, so a long
                # think never turns into a run of empty chunks.
                break
            cut = start + (pause_start + pause_end) // 2
            if cut - last < min_chunk:
                continue
            cuts.append((cut, False))
            last = cut
        if not cuts and samples.size - last >= int(self.max_chunk_s * self.sample_rate):
            cut = quietest_cut(
                samples,
                earliest=last + min_chunk,
                latest=samples.size - int(FORCED_CUT_TAIL_GUARD_S * self.sample_rate),
                sample_rate=self.sample_rate,
            )
            if cut is not None:
                cuts.append((cut, True))
        return cuts

    # ----- windows --------------------------------------------------------

    def _schedule_ready_locked(self, samples: np.ndarray, *, final: bool) -> None:
        """Queue every chunk whose right context has arrived, oldest first."""
        while self._next_to_schedule < len(self._chunks):
            index = self._next_to_schedule
            chunk = self._chunks[index]
            if index + 1 < len(self._chunks):
                right_end = min(self._chunks[index + 1].end_sample, chunk.end_sample + self.max_right_context)
            elif final:
                right_end = samples.size
            elif samples.size - chunk.end_sample >= self.right_context:
                right_end = min(samples.size, chunk.end_sample + self.max_right_context)
            else:
                return
            if final and index == len(self._chunks) - 1:
                return
            self._enqueue_locked([index], samples, right_end)
            self._next_to_schedule = index + 1

    def _enqueue_locked(self, targets: list[int], samples: np.ndarray, window_end: int) -> None:
        first = self._chunks[targets[0]]
        window_start = max(0, first.start_sample - self.left_context)
        if targets[0] > 0:
            window_start = max(window_start, self._chunks[targets[0] - 1].start_sample)
        window_end = min(window_end, samples.size)
        self._jobs.append(_WindowJob(
            targets=list(targets), audio=np.array(samples[window_start:window_end], dtype=np.float32, copy=True),
            window_start=window_start, window_end=window_end,
        ))
        if self._worker is None:
            self._worker = threading.Thread(target=self._run_worker, name="undertone-live-stt", daemon=True)
            self._worker.start()
        self._condition.notify_all()

    def finish(self, final_audio: np.ndarray, *, timeout: float | None = 60.0) -> WindowedRun:
        """Decode the tail (with the last chunk for context), then drain and close."""
        samples = np.asarray(final_audio, dtype=np.float32).reshape(-1)
        with self._condition:
            if self._finished:
                raise RuntimeError("windowed transcriber is finished")
            self._finished = True
            committed = self._chunks[-1].end_sample if self._chunks else 0
            if samples.size < committed:
                raise ValueError("final audio is shorter than the audio already cut")
            self._schedule_ready_locked(samples, final=True)
            self._chunks.append(LiveChunk(
                sequence=len(self._chunks) + 1, start_sample=committed, end_sample=samples.size,
                final=True, sample_rate=self.sample_rate,
            ))
            targets = list(range(self._next_to_schedule, len(self._chunks)))
            self._enqueue_locked(targets, samples, samples.size)
            self._next_to_schedule = len(self._chunks)
        self.close(timeout=timeout)
        with self._condition:
            return WindowedRun(tuple(self._chunks), self.boundary_disagreements, self.windows)

    def close(self, *, timeout: float | None = 60.0) -> None:
        with self._condition:
            self._closing = True
            worker = self._worker
            self._condition.notify_all()
        if worker is not None:
            worker.join(timeout=timeout)
            if worker.is_alive():
                raise TimeoutError("live transcription worker did not close")

    def _run_worker(self) -> None:
        while True:
            with self._condition:
                while not self._jobs and not self._closing:
                    self._condition.wait()
                if not self._jobs:
                    return
                job = self._jobs.pop(0)
                context = context_tail([chunk.text or "" for chunk in self._chunks if chunk.text])
                targets = [self._chunks[index] for index in job.targets]
            started_at = self._clock()
            error = None
            words: list[Word] = []
            try:
                words = list(self.transcriber.transcribe_words(job.audio, vocab=self.vocab, context=context))
            except Exception as exc:
                error = type(exc).__name__
                logger.warning("live window failed (%s); audio retained", error)
            finished_at = self._clock()
            updates: list[LiveChunk] = []
            for chunk in targets:
                kept = assign_words(
                    words, window_start=job.window_start, start=chunk.start_sample,
                    end=chunk.end_sample, sample_rate=self.sample_rate,
                )
                text = restore_sound_alikes(_join([word.text for word in kept]), self.vocab) if error is None else None
                updates.append(replace(
                    chunk, text=text, words=tuple(kept), window_start=job.window_start,
                    window_end=job.window_end, started_at=started_at, finished_at=finished_at, error=error,
                ))
            peek_index = job.targets[-1] + 1
            peek_words = assign_words(
                words, window_start=job.window_start, start=targets[-1].end_sample,
                end=job.window_end, sample_rate=self.sample_rate,
            ) if error is None else []
            with self._condition:
                self.windows += 1
                for updated in updates:
                    self._chunks[updated.sequence - 1] = updated
                    expected = self._peeked.pop(updated.sequence - 1, None)
                    if expected is not None and updated.words:
                        if _normalize_word(updated.words[0].text) != expected:
                            self.boundary_disagreements += 1
                if peek_words and error is None:
                    self._peeked[peek_index] = _normalize_word(peek_words[0].text)
                report = self.on_chunk
            if report is not None:
                for updated in updates:
                    report(updated)


# ----- cleanup units ---------------------------------------------------------


@dataclass(frozen=True)
class LiveUnit:
    """One cleanup unit: whole STT chunks, cleaned once, in order."""

    sequence: int
    raw: str
    chunk_sequences: tuple[int, ...]
    queued_at: float
    clean: str = ""
    model: str | None = None
    guard_fired: bool = False
    started_at: float | None = None
    finished_at: float | None = None
    error: str | None = None
    final: bool = False

    @property
    def done(self) -> bool:
        return self.finished_at is not None

    @property
    def compute_ms(self) -> float:
        if self.started_at is None or self.finished_at is None:
            return 0.0
        return (self.finished_at - self.started_at) * 1000.0


@dataclass(frozen=True)
class LiveResult:
    raw: str
    clean: str
    model: str | None
    guard_fired: bool
    stt_ms: float
    llm_ms: float
    release_ms: float
    stt_total_ms: float
    llm_total_ms: float
    units: tuple[LiveUnit, ...]
    chunks: tuple[LiveChunk, ...]
    committed_clean: str
    fallback: str | None
    no_speech: bool
    reason: str
    error: str | None
    stream_interrupted: bool
    audio_seconds: float
    boundary_disagreements: int = 0
    windows: int = 0


class LiveDictation:
    """One hold-to-talk recording transcribed and cleaned as it is spoken."""

    def __init__(
        self,
        transcriber,
        cleaner: Callable[..., dict[str, Any]],
        *,
        level: str,
        dictionary: dict[str, Any],
        config: dict[str, Any],
        app: str | None = None,
        context: dict[str, str] | None = None,
        vocab: str = "",
        sample_rate: int = SAMPLE_RATE,
        min_unit_words: int = DEFAULT_MIN_UNIT_WORDS,
        max_unit_words: int = DEFAULT_MAX_UNIT_WORDS,
        min_pause_s: float = DEFAULT_MIN_PAUSE_S,
        rms_threshold: float = DEFAULT_VAD_RMS,
        adaptive_vad: bool = True,
        clock: Callable[[], float] = time.monotonic,
        **stt_options: Any,
    ) -> None:
        if min_unit_words < 1 or max_unit_words < min_unit_words:
            raise ValueError("unit word bounds are invalid")
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.level = level
        self.dictionary = dictionary
        self.config = config
        self.app = app
        self.context = dict(context or {})
        self.vocab = vocab
        self.sample_rate = sample_rate
        self.min_unit_words = min_unit_words
        self.max_unit_words = max_unit_words
        self.base_rms_threshold = rms_threshold
        self.adaptive_vad = adaptive_vad
        self._clock = clock
        self._stt = WindowedTranscriber(
            transcriber, sample_rate=sample_rate, vocab=vocab, min_pause_s=min_pause_s,
            rms_threshold=rms_threshold, clock=clock, on_chunk=self._on_chunk, **stt_options,
        )
        self._condition = threading.Condition(threading.RLock())
        self._buffer = np.zeros(INITIAL_BUFFER_SECONDS * sample_rate, dtype=np.float32)
        self._samples = 0
        self._levels: list[np.ndarray] = []
        self._next_seq = 0
        self._degraded: str | None = None
        self._chunks: list[LiveChunk] = []
        self._unit_chunk_end = 0
        self._units: list[LiveUnit] = []
        self._queue: list[LiveUnit] = []
        self._unit_sequence = 0
        self._worker: threading.Thread | None = None
        self._closing = False
        self._finishing = False
        self._closed = False
        self.created_at = clock()
        self.last_activity = clock()

    # ----- recording -----------------------------------------------------

    def append(self, samples: np.ndarray, *, seq: int | None = None) -> dict[str, Any]:
        """Add the next streamed audio and cut any chunk that ended in a pause."""
        values = np.asarray(samples, dtype=np.float32).reshape(-1)
        with self._condition:
            if self._closed or self._finishing:
                raise RuntimeError("live dictation is finished")
            if seq is not None:
                if seq != self._next_seq:
                    self._degraded = self._degraded or "seq_gap"
                self._next_seq = seq + 1
            self.last_activity = self._clock()
            if values.size:
                needed = self._samples + values.size
                if needed > self._buffer.size:
                    grown = np.zeros(max(needed, self._buffer.size * 2), dtype=np.float32)
                    grown[: self._samples] = self._buffer[: self._samples]
                    self._buffer = grown
                self._buffer[self._samples : needed] = values
                self._samples = needed
                self._levels.append(frame_rms(values, sample_rate=self.sample_rate))
                if self.adaptive_vad:
                    self._stt.rms_threshold = adaptive_rms_threshold(
                        np.concatenate(self._levels), base=self.base_rms_threshold
                    )
            cumulative = self._buffer[: self._samples]
        if values.size:
            self._stt.submit(cumulative)
        return self.progress()

    def progress(self) -> dict[str, Any]:
        with self._condition:
            units = len(self._units)
            cleaned = sum(1 for unit in self._units if unit.done)
            received = self._samples
        return {
            "received_seconds": received / self.sample_rate,
            "committed_seconds": self._stt.committed_samples / self.sample_rate,
            "units": units,
            "units_cleaned": cleaned,
        }

    @property
    def streamed_audio(self) -> np.ndarray:
        with self._condition:
            return self._buffer[: self._samples].copy()

    # ----- speech chunks -> cleanup units --------------------------------

    def _on_chunk(self, chunk: LiveChunk) -> None:
        with self._condition:
            self._chunks.append(chunk)
            if not self._finishing:
                self._form_units_locked()

    def _form_units_locked(self) -> None:
        texts: list[str] = []
        for chunk in self._chunks[self._unit_chunk_end :]:
            if chunk.error is not None or chunk.final:
                # Never clean past a failed chunk; finish decides the fallback.
                break
            texts.append(chunk.text or "")
        for length in plan_units(texts, min_words=self.min_unit_words, max_words=self.max_unit_words):
            members = self._chunks[self._unit_chunk_end : self._unit_chunk_end + length]
            self._unit_chunk_end += length
            self._enqueue_unit_locked(members, final=False)

    def _enqueue_unit_locked(
        self, members: list[LiveChunk], *, final: bool, raw: str | None = None
    ) -> LiveUnit:
        self._unit_sequence += 1
        unit = LiveUnit(
            sequence=self._unit_sequence,
            raw=raw if raw is not None else _join([chunk.text or "" for chunk in members]),
            chunk_sequences=tuple(chunk.sequence for chunk in members),
            queued_at=self._clock(),
            final=final,
        )
        if not unit.raw:
            unit = replace(unit, started_at=unit.queued_at, finished_at=unit.queued_at)
            self._units.append(unit)
            return unit
        self._units.append(unit)
        self._queue.append(unit)
        if self._worker is None:
            self._worker = threading.Thread(
                target=self._run_cleanup_worker, name="undertone-live-cleanup", daemon=True
            )
            self._worker.start()
        self._condition.notify_all()
        return unit

    def _context_before_locked(self) -> str:
        cleaned = _join([unit.clean for unit in self._units if unit.done])
        before = _join([self.context.get("before", ""), cleaned])
        return before[-CONTEXT_BEFORE_CHARS:]

    def _run_cleanup_worker(self) -> None:
        while True:
            with self._condition:
                while not self._queue and not self._closing:
                    self._condition.wait()
                if not self._queue:
                    return
                unit = self._queue.pop(0)
                context = {
                    "before": self._context_before_locked(),
                    "after": self.context.get("after", "")[:CONTEXT_AFTER_CHARS],
                    "selected": "",
                }
            started_at = self._clock()
            try:
                result = self.cleaner(
                    unit.raw, self.level, self.dictionary, self.config, app=self.app, context=context
                )
                clean = str(result.get("clean_text", result.get("text", "")))
                model = result.get("model")
                guard = bool(result.get("guard_fired", False))
                error = None
            except Exception as exc:
                logger.warning("live cleanup unit failed (%s); keeping raw text", type(exc).__name__)
                clean = _raw_fallback_text(unit.raw)
                model = None
                guard = True
                error = type(exc).__name__
            done = replace(
                unit, clean=clean, model=model, guard_fired=guard,
                started_at=started_at, finished_at=self._clock(), error=error,
            )
            with self._condition:
                index = next(i for i, item in enumerate(self._units) if item.sequence == unit.sequence)
                self._units[index] = done
                self._condition.notify_all()

    def _committed_clean_locked(self) -> str:
        cleans: list[str] = []
        for unit in self._units:
            if not unit.done:
                break
            cleans.append(unit.clean)
        return _join(cleans)

    def _close_cleanup_worker(self, timeout: float | None) -> None:
        with self._condition:
            self._closing = True
            worker = self._worker
            self._condition.notify_all()
        if worker is not None:
            worker.join(timeout=timeout)
            if worker.is_alive():
                raise TimeoutError("live cleanup worker did not close")

    # ----- release ---------------------------------------------------------

    def finish(
        self,
        final_audio: np.ndarray | None = None,
        *,
        emit: Callable[[dict[str, Any]], None] | None = None,
        timeout: float | None = 60.0,
    ) -> LiveResult:
        """Emit the final cleaned text so far, decode the tail, and return everything."""
        release_started = self._clock()
        with self._condition:
            if self._closed:
                raise RuntimeError("live dictation is finished")
            self._finishing = True
            streamed = self._buffer[: self._samples].copy()
            fallback = self._degraded
            chunk_error = any(chunk.error is not None for chunk in self._chunks)
        audio = streamed
        if final_audio is not None:
            complete = np.asarray(final_audio, dtype=np.float32).reshape(-1)
            mismatch = abs(complete.size - streamed.size) > AUDIO_MATCH_TOLERANCE_S * self.sample_rate
            if fallback or mismatch:
                audio = complete
                fallback = fallback or "audio_mismatch"
        if fallback or chunk_error:
            return self._finish_whole(audio, fallback or "stt_chunk", release_started, timeout)

        with self._condition:
            committed = self._committed_clean_locked()
            committed_audio_end = max(
                (chunk.end_sample for chunk in self._chunks[: self._unit_chunk_end]), default=0
            )

        # The tail window is short, so decoding it before emitting costs little
        # and lets the correction check see the whole recording first.
        stt_started = self._clock()
        run = self._stt.finish(audio, timeout=timeout)
        stt_ms = (self._clock() - stt_started) * 1000.0
        interrupted = False
        tail_raw = ""
        with self._condition:
            remaining = list(self._chunks[self._unit_chunk_end :])
            unit_raws = [unit.raw for unit in self._units]
        if run.error:
            if not committed:
                return self._finish_whole(audio, "stt_chunk", release_started, timeout, stt_ms=stt_ms)
            # The committed units stand, so only the uncovered tail is redone.
            retry_started = self._clock()
            try:
                tail_raw = (self.transcriber.transcribe(
                    audio[committed_audio_end:], vocab=self.vocab, context=context_tail(unit_raws),
                ) or "").strip()
            except Exception as exc:
                logger.warning("live tail retry failed (%s); audio retained", type(exc).__name__)
                interrupted = True
            stt_ms += (self._clock() - retry_started) * 1000.0
            later_openings = [tail_raw]
        else:
            tail_raw = _join([chunk.text or "" for chunk in remaining])
            later_openings = [chunk.text or "" for chunk in run.chunks[1:]]
        if committed and any(opens_with_correction(text) for text in later_openings):
            return self._finish_whole(
                audio, "correction", release_started, timeout, stt_ms=stt_ms, raw=_join(unit_raws + [tail_raw]),
            )

        emitted = bool(committed)
        if emitted and emit is not None:
            emit({"seq": 0, "chunk": committed})

        llm_started = self._clock()
        with self._condition:
            tail_unit = self._enqueue_unit_locked(remaining, final=True, raw=tail_raw) if tail_raw else None
        self._close_cleanup_worker(timeout)
        with self._condition:
            units = tuple(self._units)
            self._closed = True
        llm_ms = (self._clock() - llm_started) * 1000.0
        del tail_unit
        return self._result(
            units, run.chunks, committed, audio, stt_ms=stt_ms, llm_ms=llm_ms,
            release_started=release_started, fallback=None, interrupted=interrupted,
            stt_total_ms=sum(chunk.compute_ms for chunk in run.chunks),
            boundary_disagreements=run.boundary_disagreements, windows=run.windows,
        )

    def cancel(self) -> None:
        """Drop the session without a result; retained audio stays with the app."""
        with self._condition:
            if self._closed:
                return
            self._finishing = True
        self._drain_quietly(5.0)
        with self._condition:
            self._closed = True

    # ----- fallbacks and results ----------------------------------------

    def _finish_whole(
        self,
        audio: np.ndarray,
        fallback: str,
        release_started: float,
        timeout: float | None,
        *,
        stt_ms: float = 0.0,
        raw: str | None = None,
    ) -> LiveResult:
        """The non-live path on the complete recording. Nothing was emitted.

        ``raw`` skips the transcription when the live windows already decoded
        every word and only the cleanup has to start over.
        """
        logger.info("live dictation fell back to the whole recording (%s)", fallback)
        self._drain_quietly(timeout)
        stt_started = self._clock()
        if raw is None:
            try:
                raw = (self.transcriber.transcribe(audio, vocab=self.vocab) or "").strip()
            except Exception as exc:
                return self._error_result(type(exc).__name__, release_started, audio, fallback=fallback)
        stt_ms += (self._clock() - stt_started) * 1000.0
        llm_started = self._clock()
        units: tuple[LiveUnit, ...] = ()
        if raw:
            try:
                result = self.cleaner(
                    raw, self.level, self.dictionary, self.config, app=self.app, context=self.context or None,
                )
                clean = str(result.get("clean_text", result.get("text", "")))
                model = result.get("model")
                guard = bool(result.get("guard_fired", False))
                error = None
            except Exception as exc:
                clean, model, guard, error = _raw_fallback_text(raw), None, True, type(exc).__name__
            now = self._clock()
            units = (LiveUnit(
                sequence=1, raw=raw, chunk_sequences=(), queued_at=llm_started, clean=clean, model=model,
                guard_fired=guard, started_at=llm_started, finished_at=now, error=error, final=True,
            ),)
        llm_ms = (self._clock() - llm_started) * 1000.0
        with self._condition:
            self._closed = True
        return self._result(
            units, (), "", audio, stt_ms=stt_ms, llm_ms=llm_ms, release_started=release_started,
            fallback=fallback, interrupted=False, stt_total_ms=stt_ms,
            boundary_disagreements=self._stt.boundary_disagreements, windows=self._stt.windows,
        )

    def _drain_quietly(self, timeout: float | None) -> None:
        try:
            self._stt.close(timeout=timeout)
        except TimeoutError:
            logger.warning("live transcription worker still busy while closing")
        try:
            self._close_cleanup_worker(timeout)
        except TimeoutError:
            logger.warning("live cleanup worker still busy while closing")

    def _error_result(
        self, error: str, release_started: float, audio: np.ndarray, *, fallback: str | None = None,
    ) -> LiveResult:
        with self._condition:
            self._closed = True
        return LiveResult(
            raw="", clean="", model=None, guard_fired=False, stt_ms=0.0, llm_ms=0.0,
            release_ms=(self._clock() - release_started) * 1000.0, stt_total_ms=0.0, llm_total_ms=0.0,
            units=(), chunks=(), committed_clean="", fallback=fallback, no_speech=False, reason="",
            error=error, stream_interrupted=False, audio_seconds=audio.size / self.sample_rate,
        )

    def _result(
        self,
        units: tuple[LiveUnit, ...],
        chunks: tuple[LiveChunk, ...],
        committed: str,
        audio: np.ndarray,
        *,
        stt_ms: float,
        llm_ms: float,
        release_started: float,
        fallback: str | None,
        interrupted: bool,
        stt_total_ms: float,
        boundary_disagreements: int = 0,
        windows: int = 0,
    ) -> LiveResult:
        raw = _join([unit.raw for unit in units])
        clean = _join([unit.clean for unit in units])
        if committed and not clean.startswith(committed):
            # The protocol promise is that typed text is a prefix of the result.
            logger.warning("live result did not extend the emitted text; keeping the emitted prefix")
            clean = committed
            interrupted = True
        llm_models = [unit.model for unit in units if unit.model and unit.model != "light"]
        if llm_models:
            model: str | None = llm_models[-1]
        elif any(unit.model == "light" for unit in units):
            model = "light"
        else:
            model = None
        no_speech = not raw
        return LiveResult(
            raw=raw,
            clean=clean,
            model=model,
            guard_fired=any(unit.guard_fired for unit in units),
            stt_ms=stt_ms,
            llm_ms=llm_ms,
            release_ms=(self._clock() - release_started) * 1000.0,
            stt_total_ms=stt_total_ms,
            llm_total_ms=sum(unit.compute_ms for unit in units),
            units=units,
            chunks=chunks,
            committed_clean=committed,
            fallback=fallback,
            no_speech=no_speech,
            reason="no_speech_segments" if no_speech else "",
            error=None,
            stream_interrupted=interrupted,
            audio_seconds=audio.size / self.sample_rate,
            boundary_disagreements=boundary_disagreements,
            windows=windows,
        )
