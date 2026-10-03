"""Measure one-shot, cumulative and pause-split STT on one public wav file.

The output is metrics-only. It deliberately never prints a transcript. Run
with the repository's Python environment on a Mac with mlx_whisper cached:

    PYTHONPATH=engine .venv/bin/python bench/eval_streaming.py --file bench/dictation.wav
    PYTHONPATH=engine .venv/bin/python bench/eval_streaming.py --compare-model mlx-community/whisper-small-mlx

Reported per mode: release tail (wall time after the key is released), total
model compute while recording, and whether the final normalized text matches
one-shot and spells the vocabulary words. Pause-split also reports whether
every cut landed inside silence on the real audio.
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
import time
from pathlib import Path
from typing import Any

ENGINE_DIR = Path(__file__).resolve().parents[1] / "engine"
if str(ENGINE_DIR) not in sys.path:
    sys.path.insert(0, str(ENGINE_DIR))

from undertone.audio import SAMPLE_RATE, load_wav
from undertone.stt import Transcriber
from undertone.streaming import (
    DEFAULT_VAD_RMS,
    PauseSplitTranscriber,
    StreamingTranscriber,
    frame_rms,
)


DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
PROPER_NOUNS = ("Ollama", "Qwen")


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.casefold()).strip()


def _prefix_ends(sample_count: int, interval_s: float) -> list[int]:
    step = max(1, int(round(interval_s * SAMPLE_RATE)))
    return list(range(step, sample_count, step))


def _run_once(transcriber: Transcriber, audio, vocab: str) -> tuple[dict[str, Any], float]:
    started = time.perf_counter()
    detailed = transcriber.transcribe_detailed(audio, vocab=vocab)
    return detailed, (time.perf_counter() - started) * 1000.0


def _feed_realtime(stream, audio, *, interval_s: float, vocab: str) -> None:
    """Submit cumulative prefixes at the recording's own pace."""
    prefix_ends = _prefix_ends(len(audio), interval_s)
    for end in prefix_ends:
        time.sleep(interval_s)
        stream.submit_snapshot(audio[:end], vocab=vocab)
    # The last prefix may end before the file. Let that residual hold time
    # elapse before measuring the release tail.
    elapsed_prefix_s = prefix_ends[-1] / SAMPLE_RATE if prefix_ends else 0.0
    time.sleep(max(0.0, len(audio) / SAMPLE_RATE - elapsed_prefix_s))


def _run_cumulative(transcriber, audio, *, interval_s: float, vocab: str) -> dict[str, Any]:
    stream = StreamingTranscriber(transcriber, interval_s=interval_s)
    stream.start()
    _feed_realtime(stream, audio, interval_s=interval_s, vocab=vocab)
    release_started = time.perf_counter()
    run = stream.finish(audio, vocab=vocab)
    release_tail_ms = (time.perf_counter() - release_started) * 1000.0
    compute_ms = [snapshot.compute_ms for snapshot in run.snapshots]
    return {
        "text": run.text,
        "interval_s": interval_s,
        "model_calls": len(run.snapshots),
        "snapshot_audio_seconds": [round(s.audio_seconds, 3) for s in run.snapshots],
        "release_tail_ms": round(release_tail_ms, 1),
        "total_compute_ms": round(sum(compute_ms), 1),
        "compute_median_ms": round(statistics.median(compute_ms), 1) if compute_ms else 0.0,
        "error": run.final_error,
    }


def _run_pause_split(transcriber, audio, *, interval_s: float, vocab: str) -> dict[str, Any]:
    stream = PauseSplitTranscriber(transcriber)
    stream.start()
    _feed_realtime(stream, audio, interval_s=interval_s, vocab=vocab)
    release_started = time.perf_counter()
    run = stream.finish(audio, vocab=vocab)
    release_tail_ms = (time.perf_counter() - release_started) * 1000.0
    called = [chunk for chunk in run.chunks if not chunk.skipped_silent]
    compute_ms = [chunk.compute_ms for chunk in called]
    levels = frame_rms(audio)
    frame = len(audio) // max(1, len(levels))
    cuts = [chunk.end_sample for chunk in run.chunks[:-1]]
    cuts_in_silence = all(
        levels[min(len(levels) - 1, cut // frame)] < DEFAULT_VAD_RMS for cut in cuts
    ) if cuts else True
    covered = (
        bool(run.chunks)
        and run.chunks[0].start_sample == 0
        and run.chunks[-1].end_sample == len(audio)
        and all(a.end_sample == b.start_sample for a, b in zip(run.chunks, run.chunks[1:]))
    ) or run.fallback_used
    tail = run.chunks[-1] if run.chunks else None
    return {
        "text": run.text,
        "interval_s": interval_s,
        "model_calls": len(called),
        "chunk_audio_seconds": [round(c.audio_seconds, 3) for c in called],
        "release_tail_ms": round(release_tail_ms, 1),
        "release_tail_audio_seconds": round(tail.audio_seconds, 3) if tail else 0.0,
        "total_compute_ms": round(sum(compute_ms), 1),
        "compute_median_ms": round(statistics.median(compute_ms), 1) if compute_ms else 0.0,
        "cuts": len(cuts),
        "cuts_in_silence": cuts_in_silence,
        "audio_covered_once": covered,
        "fallback_used": run.fallback_used,
        "error": run.final_error,
    }


def _checks(text: str, reference: str) -> dict[str, Any]:
    return {
        "matches_one_shot": _normalize(text) == _normalize(reference),
        "proper_nouns": {noun: noun.casefold() in text.casefold() for noun in PROPER_NOUNS},
    }


def _evaluate_model(model: str, audio, args) -> dict[str, Any]:
    transcriber = Transcriber(model=model, local_files_only=True)
    transcriber.warm_up()
    one_shot, one_shot_ms = _run_once(transcriber, audio, args.vocab)
    reference = one_shot["text"]
    report: dict[str, Any] = {
        "model": model,
        "one_shot": {
            "stt_ms": round(one_shot_ms, 1),
            "segments": one_shot.get("segments", {}),
            **_checks(reference, reference),
        },
    }
    if args.modes in {"all", "cumulative"}:
        cumulative = _run_cumulative(transcriber, audio, interval_s=args.interval, vocab=args.vocab)
        text = cumulative.pop("text")
        report["cumulative"] = {**cumulative, **_checks(text, reference)}
    if args.modes in {"all", "pause"}:
        pause = _run_pause_split(transcriber, audio, interval_s=args.pause_interval, vocab=args.vocab)
        text = pause.pop("text")
        report["pause_split"] = {**pause, **_checks(text, reference)}
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--file", default="bench/dictation.wav")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--compare-model", default=None, help="also time a second (smaller) whisper model")
    parser.add_argument("--interval", type=float, default=5.0, help="cumulative snapshot period in seconds")
    parser.add_argument("--pause-interval", type=float, default=1.0, help="pause-split snapshot period in seconds")
    parser.add_argument("--modes", choices=("all", "cumulative", "pause"), default="all")
    parser.add_argument("--vocab", default="Ollama, Qwen")
    args = parser.parse_args()
    if args.interval <= 0 or args.pause_interval <= 0:
        parser.error("intervals must be positive")

    try:
        import mlx_whisper  # noqa: F401
    except ImportError:
        print(
            "eval_streaming: mlx_whisper is not importable here. This benchmark needs an "
            "Apple Silicon Mac with the engine venv (uv pip install -e .) and the whisper "
            "model cached locally.",
            file=sys.stderr,
        )
        sys.exit(2)

    audio_path = Path(args.file).resolve()
    audio = load_wav(str(audio_path))
    metrics: dict[str, Any] = {
        "file": audio_path.name,
        "duration_s": round(len(audio) / SAMPLE_RATE, 3),
        "models": [_evaluate_model(args.model, audio, args)],
    }
    if args.compare_model:
        metrics["models"].append(_evaluate_model(args.compare_model, audio, args))

    print(json.dumps(metrics, sort_keys=True, indent=2))
    failed = [
        f"{entry['model']}/{mode}"
        for entry in metrics["models"]
        for mode in ("one_shot", "cumulative", "pause_split")
        if mode in entry
        and (
            entry[mode].get("error")
            or not entry[mode]["matches_one_shot"]
            or not all(entry[mode]["proper_nouns"].values())
            or entry[mode].get("cuts_in_silence") is False
            or entry[mode].get("audio_covered_once") is False
        )
    ]
    print("PASS" if not failed else "FAIL: " + ", ".join(failed))
    sys.exit(0 if not failed else 1)


if __name__ == "__main__":
    main()
