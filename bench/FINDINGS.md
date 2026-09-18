# Local dictation bench, 2026-09-15

Goal: prove a local dictation cleanup step works with models already on this Mac before building an app.
Hardware: an Apple Silicon Mac with 128 GB of unified memory. Runtimes: Ollama (localhost:11434), mlx_whisper (uv tool), mlx-openai-server.

## Speech to text
- mlx-community/whisper-large-v3-turbo via mlx_whisper: 0.63 s cold, 0.20 s warm for a 15 s clip.
- Passing a vocabulary string as `initial_prompt` fixed "Alima" -> "Ollama" and "Quinn" -> "Qwen" at the STT layer.
- Run whisper in-process and keep it loaded. The CLI pays ~4 s of startup per call.

## Cleanup step (warm model, seconds per case, prompt v2 few-shot)
| model | speed | quality notes |
|---|---|---|
| gemma3:4b | 0.2-0.5 | Answered a question in the transcript with v1 prompt. v2 fixed that but it dropped punctuation on long input. Not trustworthy. |
| qwen2.5:7b | 0.3-0.8 | Good on synthetic cases. Dropped a whole sentence on the real whisper transcript. Risky. |
| qwen3.5:latest (9.7B) | 0.6-1.1 | Keeps content. Weak filler removal ("you know, the one"). Em dashes. |
| Qwen3-30B-A3B (MLX) | 0.6-0.9 | Fast. Over-formats prose into bullet lists. Em dashes. Dropped "Remind me". |
| gemma4:31b | 1.5-3.4 | Best quality. Correct self-corrections, list handling, name repair. Slowest. |
| gpt-oss:20b | 2.4-3.9 | Burns the token budget on reasoning even with think=false. Skip. |

## Takeaways
1. Pipeline works end to end with local parts. Nothing needs the cloud.
2. Quality is prompt-bound more than model-bound for the 7B-10B tier. Rule 7 (format lists) is too aggressive; tighten to explicit enumerations only.
3. Put the personal dictionary in BOTH whisper's initial_prompt and the cleanup system prompt.
4. Candidate default: gemma4:31b for quality, qwen3.5 for speed. Decide after a prompt v3 pass.
5. Never trust a model that drops sentences. Add a length-ratio guard: if output words < 60% of input words, fall back to raw text with punctuation only.

Scripts: cleanup_test.py (v1), cleanup_test_v2.py (few-shot), mlx_test.py, whisper_warm.py, e2e_test.py. Audio: dictation.wav (macOS `say`).
