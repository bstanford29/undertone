"""Score brain-dump cleanup on the synthetic cases in bench/disfluency_cases.json.

Each case passes when the cleaned text keeps every `keep` phrase and drops every
`drop` phrase (case and punctuation ignored, whole words). The `keep` cases are
hard negatives: text that looks like a filler or a correction but is meaning.
Runs the real local Ollama model; the cases are synthetic, so text may print.

    PYTHONPATH=engine .venv/bin/python bench/eval_disfluency.py --tidy on
    PYTHONPATH=engine .venv/bin/python bench/eval_disfluency.py --tidy off --model qwen3.5:latest
"""
from __future__ import annotations

import argparse
import difflib
import json
import re
import statistics
import sys
import time
from collections import defaultdict
from pathlib import Path

ENGINE_DIR = Path(__file__).resolve().parents[1] / "engine"
if str(ENGINE_DIR) not in sys.path:
    sys.path.insert(0, str(ENGINE_DIR))

from undertone import config as settings
from undertone.cleanup import clean_result
from undertone.dictionary import DEFAULT_REPLACEMENTS, DEFAULT_TERMS

CASES = Path(__file__).with_name("disfluency_cases.json")


def normalize(text: str) -> str:
    text = text.lower().replace("’", "'")
    text = re.sub(r"[^\w\s']", " ", text)
    return " ".join(text.split())


def has_phrase(text: str, phrase: str) -> bool:
    return re.search(rf"(?<![\w']){re.escape(normalize(phrase))}(?![\w'])", normalize(text)) is not None


def score_case(case: dict, output: str) -> dict:
    missing = [phrase for phrase in case["keep"] if not has_phrase(output, phrase)]
    kept = [phrase for phrase in case["drop"] if has_phrase(output, phrase)]
    similarity = difflib.SequenceMatcher(None, normalize(case["expect"]).split(), normalize(output).split()).ratio()
    return {"pass": not missing and not kept, "missing": missing, "not_dropped": kept, "similarity": similarity}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tidy", choices=["on", "off"], default="on")
    parser.add_argument("--level", choices=["light", "medium", "high"], default="medium")
    parser.add_argument("--model", default=None, help="override the cleanup model for this level")
    parser.add_argument("--json", default=None, help="write per-case results here")
    parser.add_argument("--quiet", action="store_true", help="print failures only")
    args = parser.parse_args()

    config = dict(settings.DEFAULTS)
    config["tidy_speech"] = args.tidy == "on"
    if args.model:
        config["cleanup_high_model" if args.level == "high" else "cleanup_model"] = args.model
    dictionary = {"terms": list(DEFAULT_TERMS), "replacements": dict(DEFAULT_REPLACEMENTS)}
    cases = json.loads(CASES.read_text())["cases"]

    clean_result("Warm the cleanup model with this short sentence please.", args.level, dictionary, config)
    by_kind: dict[str, list[bool]] = defaultdict(list)
    rows = []
    timings = []
    for case in cases:
        started = time.perf_counter()
        result = clean_result(case["raw"], args.level, dictionary, config)
        timings.append(time.perf_counter() - started)
        output = result["clean_text"]
        scored = score_case(case, output)
        scored.update({"id": case["id"], "kind": case["kind"], "output": output, "guard_fired": result["guard_fired"]})
        rows.append(scored)
        by_kind[case["kind"]].append(scored["pass"])
        if not args.quiet or not scored["pass"]:
            mark = "PASS" if scored["pass"] else "FAIL"
            print(f"{mark} {case['id']:15s} {output}")
            if not scored["pass"]:
                print(f"     missing={scored['missing']} not_dropped={scored['not_dropped']}")

    model = config["cleanup_high_model"] if args.level == "high" else config["cleanup_model"]
    passed = sum(row["pass"] for row in rows)
    print(f"\nlevel={args.level} tidy={args.tidy} model={model}")
    for kind in sorted(by_kind):
        values = by_kind[kind]
        print(f"  {kind:12s} {sum(values)}/{len(values)}")
    print(f"  total        {passed}/{len(rows)}  mean similarity {statistics.mean(r['similarity'] for r in rows):.3f}"
          f"  median time {statistics.median(timings):.2f} s  guard fires {sum(r['guard_fired'] for r in rows)}")
    if args.json:
        Path(args.json).write_text(json.dumps({"model": model, "tidy": args.tidy, "level": args.level, "rows": rows}, indent=1))


if __name__ == "__main__":
    main()
