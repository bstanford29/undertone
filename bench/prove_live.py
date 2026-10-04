"""Stream one wav through the live dictation ops and report release latency.

Metrics only: this never prints transcript text. It runs the real local
models (the configured STT backend and Ollama cleanup) against an isolated
config, dictionary, and history, so nothing it does touches the user's
Undertone data. It does not insert text or use the clipboard.

    PYTHONPATH=engine .venv/bin/python bench/prove_live.py --file bench/dictation.wav

The audio is fed at real-time pace in half-second frames, the way the app
streams it while the key is held, then `dictation.finish` is timed: the time
to the first emitted frame is what the user waits before text appears, and
the time to the final frame is the whole release. The same audio then goes
through the one-shot path (`transcribe` + `clean`) for comparison.
"""
from __future__ import annotations

import argparse
import base64
import difflib
import json
import re
import statistics
import sys
import tempfile
import time
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parents[1] / "engine"
if str(ENGINE_DIR) not in sys.path:
    sys.path.insert(0, str(ENGINE_DIR))

import numpy as np

from undertone import config, dictionary, history
from undertone.audio import SAMPLE_RATE, load_wav
from undertone.server import Engine


def _words(text: str) -> list[str]:
    return re.findall(r"[a-z0-9']+", text.lower())


def _word_error_rate(reference: str, hypothesis: str) -> float:
    ref, hyp = _words(reference), _words(hypothesis)
    if not ref:
        return 0.0 if not hyp else 1.0
    matcher = difflib.SequenceMatcher(a=ref, b=hyp, autojunk=False)
    errors = 0
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "equal":
            errors += max(i2 - i1, j2 - j1)
    return errors / len(ref)


def _word_diff(reference: str, hypothesis: str) -> list[str]:
    ref, hyp = _words(reference), _words(hypothesis)
    matcher = difflib.SequenceMatcher(a=ref, b=hyp, autojunk=False)
    return [f"{tag}: {' '.join(ref[i1:i2])!r} -> {' '.join(hyp[j1:j2])!r}"
            for tag, i1, i2, j1, j2 in matcher.get_opcodes() if tag != "equal"]


def _pcm16(samples: np.ndarray) -> str:
    return base64.b64encode((np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()).decode()


def run_live(engine: Engine, audio: np.ndarray, path: Path, *, level: str, chunk_s: float, pace: float) -> dict:
    started = engine.dispatch({"op": "dictation.start", "level": level})
    session_id = started["session_id"]
    step = int(chunk_s * SAMPLE_RATE)
    feed_started = time.perf_counter()
    busiest_frame_ms = 0.0
    for seq, start in enumerate(range(0, len(audio), step)):
        if pace > 0:
            due = feed_started + (start / SAMPLE_RATE) / pace
            delay = due - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        frame_started = time.perf_counter()
        engine.dispatch({"op": "dictation.audio", "session_id": session_id, "seq": seq,
                         "pcm16": _pcm16(audio[start : start + step])})
        busiest_frame_ms = max(busiest_frame_ms, (time.perf_counter() - frame_started) * 1000)
    progress_before_release = engine._live[1].progress() if engine._live else {}
    frames: list[tuple[float, int]] = []
    release_started = time.perf_counter()

    def emit(frame: dict) -> None:
        frames.append((time.perf_counter() - release_started, len(frame.get("chunk", ""))))

    response = engine.dispatch({"op": "dictation.finish", "session_id": session_id, "audio_path": str(path)}, emit=emit)
    release_ms = (time.perf_counter() - release_started) * 1000
    committed_chars = frames[0][1] if frames else 0
    clean_chars = len(response.get("clean") or "")
    return {
        "response": response,
        "first_text_ms": frames[0][0] * 1000 if frames else None,
        "release_ms": release_ms,
        "committed_fraction": committed_chars / clean_chars if clean_chars else 0.0,
        "busiest_frame_ms": busiest_frame_ms,
        "units_cleaned_before_release": progress_before_release.get("units_cleaned"),
        "committed_seconds_before_release": progress_before_release.get("committed_seconds"),
    }


def run_one_shot(engine: Engine, path: Path, *, level: str) -> dict:
    started = time.perf_counter()
    transcript = engine.dispatch({"op": "transcribe", "audio_path": str(path)})
    stt_ms = (time.perf_counter() - started) * 1000
    cleaned = engine.dispatch({"op": "clean", "raw": transcript["raw"], "level": level})
    total_ms = (time.perf_counter() - started) * 1000
    return {"raw": transcript["raw"], "clean": cleaned.get("clean_text") or cleaned.get("clean") or "",
            "stt_ms": stt_ms, "total_ms": total_ms, "guard_fired": cleaned.get("guard_fired")}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--file", type=Path, required=True, help="16 kHz mono wav, or anything load_wav resamples")
    parser.add_argument("--level", default="medium")
    parser.add_argument("--chunk-seconds", type=float, default=0.5)
    parser.add_argument("--pace", type=float, default=1.0, help="1.0 feeds in real time; 0 feeds as fast as possible")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--expect", action="append", default=[], help="word that must appear in the clean text (repeatable)")
    parser.add_argument("--json", action="store_true", help="print one JSON object instead of a table")
    parser.add_argument("--show-diff", action="store_true",
                        help="print the differing words between the one-shot and live raw text. "
                             "Only for public audio such as bench/dictation.wav, never private recordings")
    args = parser.parse_args()
    path = args.file.resolve()
    if not path.is_file():
        raise SystemExit(f"no such file: {path}")

    with tempfile.TemporaryDirectory(prefix="undertone-live-proof-") as directory:
        root = Path(directory)
        for module, directory_key, path_key, name in (
            (config, "CONFIG_DIR", "CONFIG_PATH", "config.yaml"),
            (dictionary, "DICTIONARY_DIR", "DICTIONARY_PATH", "dictionary.yaml"),
            (history, "HISTORY_DIR", "HISTORY_PATH", "history.sqlite"),
        ):
            setattr(module, directory_key, root)
            setattr(module, path_key, root / name)
        engine = Engine()
        engine.warm()
        status = engine.dispatch({"op": "status"})
        if status["whisper"] != "warm" or status["cleanup"] != "warm":
            raise RuntimeError("Local models could not warm")
        audio = load_wav(str(path))
        baseline = run_one_shot(engine, path, level=args.level)
        runs = [run_live(engine, audio, path, level=args.level, chunk_s=args.chunk_seconds, pace=args.pace)
                for _ in range(max(1, args.runs))]

    rows = []
    for index, run in enumerate(runs):
        response = run["response"]
        clean = response.get("clean") or ""
        rows.append({
            "run": index + 1,
            "audio_s": round(response.get("audio_seconds", len(audio) / SAMPLE_RATE), 1),
            "fallback": response.get("live_fallback"),
            "chunks": response.get("live_chunks"),
            "windows": response.get("live_windows"),
            "units": response.get("live_units"),
            "units_cleaned_before_release": run["units_cleaned_before_release"],
            "committed_s_before_release": round(run["committed_seconds_before_release"] or 0, 1),
            "first_text_ms": None if run["first_text_ms"] is None else round(run["first_text_ms"]),
            "release_ms": round(run["release_ms"]),
            "release_stt_ms": round(response.get("stt_ms", 0)),
            "release_llm_ms": round(response.get("llm_ms", 0)),
            "stt_total_ms": round(response.get("live_stt_total_ms", 0)),
            "llm_total_ms": round(response.get("live_llm_total_ms", 0)),
            "busiest_frame_ms": round(run["busiest_frame_ms"]),
            "boundary_disagreements": response.get("live_boundary_disagreements"),
            "committed_fraction": round(run["committed_fraction"], 2),
            "guard_fired": response.get("guard_fired"),
            "model": response.get("model"),
            "raw_wer_vs_one_shot": round(_word_error_rate(baseline["raw"], response.get("raw") or ""), 3),
            "clean_words": len(_words(clean)),
            "expected_words_present": {word: word.lower() in clean.lower() for word in args.expect},
        })
        if args.show_diff:
            rows[-1]["raw_diff"] = _word_diff(baseline["raw"], response.get("raw") or "")
    summary = {
        "file": path.name,
        "one_shot_stt_ms": round(baseline["stt_ms"]),
        "one_shot_total_ms": round(baseline["total_ms"]),
        "one_shot_clean_words": len(_words(baseline["clean"])),
        "one_shot_guard_fired": baseline["guard_fired"],
        "live_release_ms_median": round(statistics.median(row["release_ms"] for row in rows)),
        "runs": rows,
    }
    if args.json:
        print(json.dumps(summary, indent=2))
        return
    print(f"file: {summary['file']}")
    print(f"one-shot after release: stt {summary['one_shot_stt_ms']} ms, total {summary['one_shot_total_ms']} ms, "
          f"{summary['one_shot_clean_words']} clean words, guard {summary['one_shot_guard_fired']}")
    for row in rows:
        print(f"live run {row['run']}: audio {row['audio_s']} s, fallback {row['fallback']}, chunks {row['chunks']}, "
              f"windows {row['windows']}, units {row['units']} ({row['units_cleaned_before_release']} cleaned before release, "
              f"{row['committed_s_before_release']} s committed)")
        print(f"  release: first text {row['first_text_ms']} ms, done {row['release_ms']} ms "
              f"(stt {row['release_stt_ms']} ms, llm {row['release_llm_ms']} ms); "
              f"while recording: stt {row['stt_total_ms']} ms, llm {row['llm_total_ms']} ms, busiest frame {row['busiest_frame_ms']} ms")
        print(f"  text: {row['clean_words']} clean words, committed fraction {row['committed_fraction']}, "
              f"raw WER vs one-shot {row['raw_wer_vs_one_shot']}, boundary disagreements {row['boundary_disagreements']}, "
              f"guard {row['guard_fired']}, model {row['model']}, expected words {row['expected_words_present']}")
        for line in row.get("raw_diff", []):
            print(f"  raw diff {line}")


if __name__ == "__main__":
    main()
