"""Measure cumulative-prefix STT against one-shot STT on a public wav file.

The output is metrics-only. It deliberately never prints either transcript.
Run with the repository's Python environment, for example:

    .venv/bin/python bench/eval_streaming.py --file bench/dictation.wav
"""
from __future__ import annotations

import argparse
import json
import re
import statistics
import sys
import time
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parents[1] / "engine"
if str(ENGINE_DIR) not in sys.path:
    sys.path.insert(0, str(ENGINE_DIR))

from undertone.audio import SAMPLE_RATE, load_wav
from undertone.stt import Transcriber
from undertone.streaming import StreamingTranscriber


DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text.casefold()).strip()


def _prefix_ends(sample_count: int, interval_s: float) -> list[int]:
    step = max(1, int(round(interval_s * SAMPLE_RATE)))
    return list(range(step, sample_count, step))


def _run_once(transcriber: Transcriber, audio, vocab: str) -> tuple[str, float]:
    started = time.perf_counter()
    text = transcriber.transcribe(audio, vocab=vocab)
    return text, (time.perf_counter() - started) * 1000.0


def _run_stream(
    transcriber: Transcriber,
    audio,
    *,
    interval_s: float,
    vocab: str,
) -> tuple[object, float]:
    stream = StreamingTranscriber(transcriber, interval_s=interval_s)
    stream.start()
    prefix_ends = _prefix_ends(len(audio), interval_s)
    for end in prefix_ends:
        time.sleep(interval_s)
        stream.submit_snapshot(audio[:end], vocab=vocab)

    # The last prefix may end before the file. Let that residual hold time
    # elapse before measuring the release tail.
    elapsed_prefix_s = prefix_ends[-1] / SAMPLE_RATE if prefix_ends else 0.0
    time.sleep(max(0.0, len(audio) / SAMPLE_RATE - elapsed_prefix_s))

    release_started = time.perf_counter()
    run = stream.finish(audio, vocab=vocab)
    release_tail_ms = (time.perf_counter() - release_started) * 1000.0
    return run, release_tail_ms


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", default="bench/dictation.wav")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--vocab", default="Ollama Qwen")
    args = parser.parse_args()
    if args.interval <= 0:
        parser.error("--interval must be positive")

    audio_path = Path(args.file).resolve()
    audio = load_wav(str(audio_path))
    transcriber = Transcriber(model=args.model, local_files_only=True)
    transcriber.warm_up()

    one_shot_text, one_shot_ms = _run_once(transcriber, audio, args.vocab)
    run, release_tail_ms = _run_stream(
        transcriber, audio, interval_s=args.interval, vocab=args.vocab
    )
    compute_ms = [snapshot.compute_ms for snapshot in run.snapshots]
    final_text = run.final_snapshot.text if run.final_snapshot else ""

    metrics = {
        "file": audio_path.name,
        "model": args.model,
        "duration_s": round(len(audio) / SAMPLE_RATE, 3),
        "interval_s": args.interval,
        "snapshots_completed": len(run.snapshots),
        "snapshot_audio_seconds": [
            round(snapshot.audio_seconds, 3) for snapshot in run.snapshots
        ],
        "one_shot_ms": round(one_shot_ms, 1),
        "stream_total_compute_ms": round(sum(compute_ms), 1),
        "stream_compute_median_ms": round(statistics.median(compute_ms), 1) if compute_ms else 0.0,
        "release_tail_ms": round(release_tail_ms, 1),
        "final_equivalent": _normalize(final_text) == _normalize(one_shot_text),
        "proper_nouns": {
            "Ollama": "ollama" in final_text.casefold(),
            "Qwen": "qwen" in final_text.casefold(),
        },
        "error": run.final_error,
    }
    print(json.dumps(metrics, sort_keys=True))


if __name__ == "__main__":
    main()
