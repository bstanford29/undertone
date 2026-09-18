# Phase 2 measurements

Measured 2026-09-15 on this Mac, using local Ollama and cached Whisper.

**Implemented, but the Phase 2 acceptance targets are not all met.** Qwen's final 100-row similarity is 0.8943, below 0.9000. The public 15.506-second clip's three-run median loop is 1,278 ms, above 900 ms. Do not mark the phase complete based on these results.

## Cleanup

The evaluator now calls the production cleanup implementation. It measures retention against the raw input, applies dictionary replacements and the em-dash filter before the guard, and counts fallback/guard events. The fixed seed is 20260915; eligible recordings are 3–40 seconds. Only IDs and metrics leave the private dataset directory; no transcript text is in this report.

| Configuration | Rows | Mean similarity to reference | Median cleanup | Guard fires | Retention <60% | Em-dash violations |
|---|---:|---:|---:|---:|---:|---:|
| Previous standalone evaluator | 100 | 0.8857 | 537 ms | Not measured | Not measured against raw | Not measured |
| Selected Qwen conservative prompt | 100 | **0.8943** | **620 ms** | **0** | **0** | **0** |
| Selected Gemma High prompt | 30 | **0.9296** | **2,343 ms** | **0** | **0** | **0** |

The previous evaluator had one <60% flag against the reference formatted text, a different denominator from the required raw-input guard. Its prompt also differed from production, so it is a historical reference, not a controlled production baseline.

Qwen remains the default for speed. High uses Gemma with its own cleanup prompt. A preceding run of the identical selected Qwen prompt measured 505 ms median; the final proof run measured 620 ms. Latency is workload- and run-dependent.

### Bounded prompt comparison

On the same 30-row development sample, the conservative prompt scored 0.8685 and the self-correction alternative scored 0.8621. The API supports per-app prompt variants; it did not rely on the empty default variant map. The scripts now expose `--app-variant BUNDLE.ID=INSTRUCTION` to reproduce this without changing code.

The 30 development rows are included in the 100-row sample; this is not an independent held-out generalization result. Gemma's score is from 30 rows, not 100. Gemma with the Qwen prompt scored 0.8654; its selected model-specific prompt improved that to 0.9296.

## Complete engine loop

The saved `bench/dictation.wav` clip ran three times with warm Whisper, the selected Qwen prompt, insertion disabled, and isolated test history. Full-loop times: 1,368 / 1,266 / 1,278 ms; median **1,278 ms**. Median STT was about 206 ms. All three retained the report request, Wednesday correction, Tuesday absence, work-email delivery, and Northwind/Obsidian/Ollama/Qwen plan. Ollama and Qwen spelling, the retention guard and em-dash checks passed.

These are real model runs, not synthetic latency or a sum of unrelated median values. They do not prove microphone capture or actual app insertion.

## Streaming experiment

A single same-audio comparison used cumulative snapshots at 5, 10, 15 and 15.506 seconds:

- One-shot STT: 255.5 ms.
- Streaming release tail: 177.6 ms.
- Total streaming model compute: 647.7 ms.
- Final normalized transcript matched one-shot exactly; Ollama and Qwen were correct.

Streaming remains **off by default**. It preserves the full final audio and transcribes the complete recording again at release. It uses more total model work, and this experiment does not prove an end-to-end loop below 900 ms. It deliberately avoids stitching independent windows that could lose words at their boundaries.

## Checks and reproduction

34 synthetic Python tests passed, including migration preservation, final-output guards, network boundaries, literal dictionary replacements, focus-change insertion protection, bounded streaming work, retained audio after failures, and cached-only model loading.

Run from the repo root:

```sh
PYTHONPATH=engine .venv/bin/python -m unittest discover -s tests -v
PYTHONPATH=engine .venv/bin/python bench/eval_cleanup.py --model qwen3.5:latest --n 100 --pairs bench/private_eval/pairs.jsonl --output /tmp/undertone-qwen-proof.json
PYTHONPATH=engine .venv/bin/python bench/eval_cleanup.py --model gemma4:31b --level high --n 30 --pairs bench/private_eval/pairs.jsonl --output /tmp/undertone-gemma-proof.json
PYTHONPATH=engine .venv/bin/python bench/eval_streaming.py --file bench/dictation.wav
```

No microphone, Accessibility, clipboard, launchd installation or five-app insertion proof is claimed by Phase 2's measurements. The 60% guard is a floor against large content loss; it is not a semantic proof that every sentence survives every possible input.

## 2026-09-15 update: Ollama runner pin, few-shot prompt trial, short-utterance bypass

Three changes attempted on this Mac, plugged in, local Ollama at `localhost:11434`.

### 1. Pinned Ollama runner

`ollama_num_ctx` (default 8192) and `ollama_keep_alive` (default `60m`) are now explicit config keys, threaded through every `_call_ollama` call site (`cleanup.py` primary/fallback, `command.py` rewrite, `server.py` warm-up and meeting summary). `ollama ps` after a warm call shows `qwen3.5:latest` at `CONTEXT 8192`, confirming the pin. This keeps every internal caller on one fixed context size so the engine's own traffic never forces a model reload.

### 2. Few-shot prompt trial (bench/cleanup_test_v2.py SYSTEM_V2), adapted with {vocab}

Adapted `SYSTEM_V2` to use the `{vocab}` placeholder for rule 10 and swapped it in as the medium-level `SYSTEM_PROMPT`, then ran the full proof:

```
PYTHONPATH=engine .venv/bin/python bench/eval_cleanup.py --model qwen3.5:latest --n 100 --pairs bench/private_eval/pairs.jsonl --output /tmp/undertone-qwen-newprompt.json
```

| Configuration | Rows | Mean similarity | Median cleanup | Guard fires | Retention <60% | Em-dash violations |
|---|---:|---:|---:|---:|---:|---:|
| Previous production prompt (baseline, above) | 100 | 0.8943 | 620 ms | 0 | 0 | 0 |
| Few-shot candidate prompt | 100 | 0.8857 | 579 ms | 0 | 0 | 0 |

The candidate scored **below** the 0.8943 baseline (and below the 0.90 acceptance target), so it was **rejected**. `SYSTEM_PROMPT` in `engine/undertone/cleanup.py` was reverted to the previous production text; `HIGH_SYSTEM_PROMPT` was left untouched throughout. Qwen medium remains on the previous production prompt.

### 3. Short-utterance bypass

`clean_result` now skips the LLM for `medium`/`high` levels when the raw transcript has `short_utterance_words` (config key, default 6) or fewer words, using the deterministic light-clean path instead (`model: "light"`, `guard_fired: false`). Covered by `tests/test_cleanup.py::CleanupTests::test_short_utterance_bypasses_the_llm_for_medium_and_high`, `test_longer_utterance_still_calls_the_llm_for_medium`, and `test_short_utterance_threshold_is_configurable`.

### Verification

`PYTHONPATH=engine .venv/bin/python -m unittest discover -s tests -v`: 99 tests, all pass (includes 3 new short-utterance tests; existing tests were adjusted where fixture transcripts were at or under the new 6-word bypass boundary, and one mock signature update per new `num_ctx` kwarg).

Three `undertone once --file bench/dictation.wav --no-insert` runs, numbers only:

| Run | stt_ms | llm_ms | total_ms |
|---|---:|---:|---:|
| 1 | 193.5 | 1157.5 | 1353.4 |
| 2 | 200.5 | 1115.3 | 1318.1 |
| 3 | 186.1 | 1058.0 | 1246.7 |

Median: stt 193.5 ms, llm 1115.3 ms, total 1318.1 ms. This is above the earlier baseline (llm 976-1022 ms, total 1150-1200 ms) on this same machine; other large models were resident on this Ollama instance during the run (`gpt-oss:120b`, `llama3.3:70b`, several `gemma4`/`qwen3.5` variants per `ollama ps`), which is a plausible confound for the difference. All three runs kept every retained fact (report request, Wednesday correction, Tuesday absence, work-email delivery, Northwind/Obsidian/Ollama/Qwen plan) and correct Ollama/Qwen spelling; `guard_fired` was `false` and `model` was `qwen3.5:latest` on all three.

`ollama ps` after these runs: `qwen3.5:latest`, `CONTEXT 8192`, GPU-resident, confirming the pinned runner.
