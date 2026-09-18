"""Evaluate an Ollama model's dictation-cleanup quality against a reference
formatted transcript, and optionally benchmark local STT against the
reference ASR text.

Reads pairs from a private eval set at bench/private_eval/pairs.jsonl. That
set is not included in this repo; build your own from your own dictation
history, one JSON object per line with asr, formatted, duration_s, app,
id, and e2e_latency_ms fields.

Usage:
    python3 bench/eval_cleanup.py --model qwen3.5:latest --n 40 [--stt]
"""
from __future__ import annotations

import argparse
import difflib
import json
import random
import re
import statistics
import string
import subprocess
import sys
import time
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parents[1] / "engine"
if str(ENGINE_DIR) not in sys.path:
    sys.path.insert(0, str(ENGINE_DIR))

from undertone.cleanup import clean_result
from undertone.config import DEFAULTS
from undertone.dictionary import DEFAULT_REPLACEMENTS, DEFAULT_TERMS

BENCH_DIR = Path(__file__).resolve().parent
OUT_DIR = BENCH_DIR / "private_eval"
PAIRS_PATH = OUT_DIR / "pairs.jsonl"
AUDIO16K_DIR = OUT_DIR / "audio16k"

MLX_WHISPER_PY = str(Path.home() / ".local" / "share" / "uv" / "tools" / "mlx-whisper" / "bin" / "python")
STT_HELPER = BENCH_DIR / "stt_helper.py"

SEED = 20260915
MIN_DURATION_S = 3
MAX_DURATION_S = 40


def parse_app_variants(values: list[str]) -> dict[str, str]:
    variants = {}
    for value in values:
        bundle, separator, instruction = value.partition("=")
        if not separator or not bundle.strip() or not instruction.strip():
            raise ValueError("--app-variant must be BUNDLE.ID=INSTRUCTION")
        variants[bundle.strip()] = instruction.strip()
    return variants


def normalize(text: str) -> str:
    text = text.lower()
    text = text.translate(str.maketrans("", "", string.punctuation))
    text = re.sub(r"\s+", " ", text).strip()
    return text


def similarity(a: str, b: str) -> float:
    return difflib.SequenceMatcher(None, normalize(a), normalize(b)).ratio()


def word_ratio(candidate: str, reference: str) -> float:
    ref_words = len(reference.split())
    if ref_words == 0:
        return 1.0 if not candidate.split() else 0.0
    return len(candidate.split()) / ref_words


def word_error_rate(hypothesis: str, reference: str) -> float:
    ref_words = normalize(reference).split()
    hyp_words = normalize(hypothesis).split()
    if not ref_words:
        return 0.0 if not hyp_words else 1.0

    # Standard Levenshtein distance over words.
    m, n = len(ref_words), len(hyp_words)
    dp = list(range(n + 1))
    for i in range(1, m + 1):
        prev = dp[0]
        dp[0] = i
        for j in range(1, n + 1):
            tmp = dp[j]
            if ref_words[i - 1] == hyp_words[j - 1]:
                dp[j] = prev
            else:
                dp[j] = 1 + min(prev, dp[j], dp[j - 1])
            prev = tmp
    return dp[n] / m


def load_sample(n: int, pairs_path: Path = PAIRS_PATH) -> list[dict]:
    pairs = []
    with pairs_path.open() as f:
        for line in f:
            pairs.append(json.loads(line))

    candidates = [
        p for p in pairs
        if p.get("duration_s") is not None
        and MIN_DURATION_S <= p["duration_s"] <= MAX_DURATION_S
    ]
    candidates.sort(key=lambda p: p["id"])  # deterministic order before shuffle
    rng = random.Random(SEED)
    rng.shuffle(candidates)
    return candidates[:n]


def run_cleanup(
    model: str,
    asr_text: str,
    level: str,
    app: str | None = None,
    app_style: bool = True,
    app_variants: dict[str, str] | None = None,
) -> tuple[dict, float]:
    config = dict(DEFAULTS)
    config["cleanup_high_model" if level == "high" else "cleanup_model"] = model
    config["app_prompt_variants"] = dict(
        DEFAULTS.get("app_prompt_variants") or {} if app_variants is None else app_variants
    )
    if not app_style:
        config["app_prompt_variants"] = {}
    dictionary = {"terms": list(DEFAULT_TERMS), "replacements": dict(DEFAULT_REPLACEMENTS)}
    start = time.time()
    result = clean_result(asr_text, level, dictionary, config, app=app if app_style else None)
    return result, (time.time() - start) * 1000.0


def run_stt(sample: list[dict]) -> dict[str, dict]:
    wav_paths = []
    for p in sample:
        wav_path = AUDIO16K_DIR / f"{p['id']}.wav"
        if wav_path.exists():
            wav_paths.append(str(wav_path))

    if not wav_paths:
        return {}

    result = subprocess.run(
        [MLX_WHISPER_PY, str(STT_HELPER), *wav_paths],
        capture_output=True, text=True, timeout=1800,
    )
    out = {}
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        row_id = Path(obj["path"]).stem
        out[row_id] = obj
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--n", type=int, default=40)
    parser.add_argument("--pairs", type=Path, default=PAIRS_PATH)
    parser.add_argument("--level", choices=["medium", "high"], default="medium")
    parser.add_argument("--app", default=None, help="bundle id used for the optional app prompt variant")
    parser.add_argument("--no-app-style", action="store_true", help="disable per-app prompt variants")
    parser.add_argument(
        "--app-variant", action="append", default=[], metavar="BUNDLE.ID=INSTRUCTION",
        help="explicit app prompt variant; repeat for multiple bundle IDs",
    )
    parser.add_argument("--output", type=Path, default=None, help="metrics JSON output path")
    parser.add_argument("--stt", action="store_true")
    args = parser.parse_args()
    try:
        app_variants = parse_app_variants(args.app_variant)
    except ValueError as exc:
        parser.error(str(exc))

    sample = load_sample(args.n, args.pairs)
    print(f"Sampled {len(sample)} rows (seed={SEED}, duration {MIN_DURATION_S}-{MAX_DURATION_S}s)")

    stt_results: dict[str, dict] = {}
    if args.stt:
        print("Running mlx_whisper STT on matching audio16k clips...")
        stt_results = run_stt(sample)
        print(f"STT produced {len(stt_results)} transcripts")

    rows = []
    flagged = []
    for p in sample:
        row_app = args.app or p.get("app")
        result, our_latency_ms = run_cleanup(
            args.model,
            p["asr"],
            args.level,
            app=row_app,
            app_style=not args.no_app_style,
            app_variants=app_variants if args.app_variant else None,
        )
        our_output = result["clean_text"]

        sim = similarity(our_output, p["formatted"])
        wratio = word_ratio(our_output, p["formatted"])
        retention = word_ratio(our_output, p["asr"])

        row = {
            "id": p["id"],
            "app": row_app,
            "similarity": sim,
            "word_ratio": wratio,
            "retention_ratio": retention,
            "em_dash_count": our_output.count("—"),
            "our_latency_ms": our_latency_ms,
            "reference_latency_ms": p.get("e2e_latency_ms"),
            "guard_fired": bool(result["guard_fired"]),
            "fallback_attempted": bool(result["fallback_attempted"]),
            "model_used": result["model"],
        }

        stt_entry = stt_results.get(p["id"])
        if stt_entry is not None and stt_entry.get("ok"):
            stt_sim = similarity(stt_entry["text"], p["asr"])
            stt_wer = word_error_rate(stt_entry["text"], p["asr"])
            row["stt_similarity"] = stt_sim
            row["stt_wer"] = stt_wer
            row["stt_latency_ms"] = stt_entry["ms"]

        rows.append(row)

        if retention < 0.6 or sim < 0.5:
            flagged.append(row["id"])

    print("\nid                                    sim    wratio  retain  guard  fallback  our_ms  ref_ms" + ("  stt_sim  stt_wer" if args.stt else ""))
    for r in rows:
        base = f"{r['id']}  {r['similarity']:.3f}  {r['word_ratio']:.3f}  {r['retention_ratio']:.3f}  {int(r['guard_fired'])}      {int(r['fallback_attempted'])}         {r['our_latency_ms']:.0f}  {r['reference_latency_ms'] if r['reference_latency_ms'] is not None else 'n/a'}"
        if args.stt and "stt_similarity" in r:
            base += f"  {r['stt_similarity']:.3f}  {r['stt_wer']:.3f}"
        print(base)

    sims = [r["similarity"] for r in rows]
    wratios = [r["word_ratio"] for r in rows]
    retentions = [r["retention_ratio"] for r in rows]
    our_lat = [r["our_latency_ms"] for r in rows]
    ref_lat = [r["reference_latency_ms"] for r in rows if r["reference_latency_ms"] is not None]

    print(f"\n=== Means (model={args.model}, n={len(rows)}) ===")
    if sims:
        print(f"similarity: mean={statistics.mean(sims):.3f}")
    if wratios:
        print(f"word_ratio: mean={statistics.mean(wratios):.3f}")
    if retentions:
        print(f"raw retention ratio: mean={statistics.mean(retentions):.3f}")
    if our_lat:
        print(f"our latency (ms): mean={statistics.mean(our_lat):.0f}, median={statistics.median(our_lat):.0f}")
    if ref_lat:
        print(f"reference e2e latency (ms): mean={statistics.mean(ref_lat):.0f}")

    stt_sims = [r["stt_similarity"] for r in rows if "stt_similarity" in r]
    stt_wers = [r["stt_wer"] for r in rows if "stt_wer" in r]
    if stt_sims:
        print(f"STT similarity: mean={statistics.mean(stt_sims):.3f}")
    if stt_wers:
        print(f"STT WER: mean={statistics.mean(stt_wers):.3f}")

    guard_count = sum(1 for r in rows if r["guard_fired"])
    fallback_count = sum(1 for r in rows if r["fallback_attempted"])
    print(f"guard fires: {guard_count}")
    print(f"fallback attempts: {fallback_count}")

    if flagged:
        print(f"\nFlagged rows (raw retention<0.6 or similarity<0.5): {len(flagged)}")
        for row_id in flagged:
            print(f"  {row_id}")
    else:
        print("\nNo rows flagged.")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    model_slug = args.model.replace(":", "_").replace("/", "_")
    results_path = args.output or OUT_DIR / f"results_{model_slug}_{args.level}{'_noapp' if args.no_app_style else ''}.json"
    app_summary = {}
    for app_name in sorted({r["app"] or "unknown" for r in rows}):
        app_rows = [r for r in rows if (r["app"] or "unknown") == app_name]
        app_summary[app_name] = {
            "n": len(app_rows),
            "mean_similarity": statistics.mean(r["similarity"] for r in app_rows),
            "mean_retention_ratio": statistics.mean(r["retention_ratio"] for r in app_rows),
            "median_latency_ms": statistics.median(r["our_latency_ms"] for r in app_rows),
            "guard_fires": sum(1 for r in app_rows if r["guard_fired"]),
            "fallback_attempts": sum(1 for r in app_rows if r["fallback_attempted"]),
        }
    summary = {
        "model": args.model,
        "level": args.level,
        "n": len(rows),
        "mean_similarity": statistics.mean(sims) if sims else None,
        "mean_word_ratio": statistics.mean(wratios) if wratios else None,
        "mean_retention_ratio": statistics.mean(retentions) if retentions else None,
        "median_latency_ms": statistics.median(our_lat) if our_lat else None,
        "retention_violations": sum(r["retention_ratio"] < 0.6 for r in rows),
        "em_dash_violations": sum(r["em_dash_count"] > 0 for r in rows),
        "guard_fires": guard_count,
        "fallback_attempts": fallback_count,
        "per_app": app_summary,
    }
    results_path.parent.mkdir(parents=True, exist_ok=True)
    results_path.write_text(json.dumps({"summary": summary, "rows": rows, "flagged": flagged}, indent=2))
    print(f"\nWrote {results_path}")


if __name__ == "__main__":
    main()
