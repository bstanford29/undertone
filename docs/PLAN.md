# Undertone build plan

Local dictation for macOS with no cloud. This file is the build brief. The visual versions are `docs/plan.html` (the plan) and `docs/mockups.html` (the UI, with the pill animation). When they disagree, this file wins.

Status as of 2026-09-15: Phase 0 and Phase 1 done. Phase 2 is next.

## What is proven

Measured on an Apple Silicon Mac with models warm.

| Stage | Runs on | Time | Note |
|---|---|---|---|
| Speech-to-text, 15 s clip | whisper-large-v3-turbo via mlx_whisper | 0.17 to 0.20 s | Vocabulary in `initial_prompt` fixes proper nouns |
| Cleanup, fast | qwen3.5:latest via Ollama | 0.6 to 1.1 s | Default. Keeps every sentence |
| Cleanup, quality | gemma4:31b via Ollama | 1.5 to 3.4 s | "High" level, Command Mode, meeting summaries |
| Whole loop | engine prototype | 957 ms | `undertone once --file bench/dictation.wav` |

Rejected: qwen2.5:7b (dropped a sentence on real audio), gemma3:4b (answered a question in the transcript), gpt-oss:20b (burns the budget on reasoning). Details in `bench/FINDINGS.md`.

Cleanup quality is scored against a private set of the author's own dictations, not included in this repo (see `bench/eval_cleanup.py`). Speech-to-text word error rate against the same set was 4.5%.

## Architecture

Two processes.

- **Engine** (`engine/undertone/`, Python 3.12, exists). Owns the models. mlx_whisper in-process and kept warm. Ollama over HTTP. SQLite history at `~/.undertone/history.sqlite`. YAML config and dictionary in `~/.undertone/`. Runs as a launchd agent in Phase 3.
- **App** (`app/`, Swift and SwiftUI, Phase 3). Owns everything that needs the OS: the hold key, microphone, the pill overlay, sounds, text insertion, system audio for meetings, menu bar, windows. Talks to the engine over a Unix socket at `~/.undertone/engine.sock` with newline-delimited JSON.

Until the app exists, `engine/undertone/hotkey.py` is a temporary hold-to-talk listener using pynput and F13.

### Engine socket protocol (Phase 3)

Requests are one JSON object per line. Responses mirror the `id`.

```
{"id":1,"op":"transcribe","audio_path":"/tmp/u.wav","vocab_extra":["Priya"]}
{"id":1,"raw":"...","stt_ms":174}
{"id":2,"op":"clean","raw":"...","level":"medium","app":"com.openai.codex","context":{"before":"...","after":"","selected":""}}
{"id":2,"clean":"...","llm_ms":783,"model":"qwen3.5:latest","guard_fired":false}
{"id":3,"op":"command","selected":"...","instruction":"make this shorter"}
{"id":4,"op":"history.list","limit":50,"query":"report","app":null}
{"id":5,"op":"history.last"}
{"id":6,"op":"dictionary.add","term":"Qwen"}
{"id":7,"op":"meeting.start"} / {"op":"meeting.chunk","path":"..."} / {"op":"meeting.end"}
{"id":8,"op":"status"}  -> {"whisper":"warm","cleanup":"warm","model":"qwen3.5:latest"}
```

## Hard rules

1. **Dictation never writes the clipboard.** Dictation types synthesized Unicode keystrokes into the focused app. The Accessibility API is used only for command-mode replacement and undo, where the exact selection matters. Paste-with-restore exists behind `insert_mode: paste` in config, off by default, logged loudly. "Copy last transcript" is the only clipboard write, and only on request.
2. **Never drop content.** If the cleaner's output is under 60% of the input word count, retry once on the fallback model, then insert the raw text with basic capitalization and mark the history row `guard_fired`.
3. **Never answer the transcript.** The cleanup prompt keeps questions as the speaker's words. The eval flags this.
4. **Nothing leaves the machine.** No network calls except localhost Ollama.
5. **Keep every dictation.** History rows are never pruned automatically.
6. **No em dashes in output.** The cleanup prompt says so. Add a post-filter that replaces them with commas or periods.

## Feature map

| Feature | Undertone | Phase |
|---|---|---|
| Hold to dictate | fn key hold (F13 in prototype). Double-tap locks on for long dictation | 1, 3 |
| Cleanup levels None, Light, Medium, High | none = raw; light = regex fillers + punctuation, no LLM; medium = qwen3.5; high = gemma4:31b | 1 done |
| Never touches clipboard | Rule 1 | 1 done |
| History with audio | SQLite row per dictation: raw, cleaned, edited, app, timings, audio path, insert mode, guard flag | 1 done |
| Last transcript back, copy raw or cleaned, undo AI edit | Menu items and hotkeys: ⌥⇧V insert again, ⌥⇧Z undo AI edit, ⌥⇧C copy last | 3 |
| History window | Search, filter by app and date, Raw / Cleaned / Diff tabs, audio playback, insert again, copy, add words to dictionary, delete | 3 |
| Personal dictionary | `terms` fed to whisper initial_prompt (cap ~180 tokens, recent first) and the cleanup prompt; `replacements` applied after cleanup as plain substitution | 1 done |
| Auto-learned dictionary | Watch the focused field ~20 s after insert; if a produced word was changed to a capitalized or unknown word, queue a suggestion. Inbox card: Add / Ignore / Never ask | 4 |
| Screen harvest | Before transcribing, read proper nouns from the focused window via AX and add to that dictation's vocabulary only | 4 |
| Snippets | Dictionary replacements. Rich text later | 1 done |
| Tone per app | System prompt variant keyed by bundle id. Neutral for Codex, Claude, Ghostty. Casual for Messages. Formal for Mail | 3 |
| Context awareness | Send focused field text before and after the caret plus selection to the cleaner | 4 |
| Command Mode | Selection + held key + spoken instruction -> gemma4:31b rewrite -> replace selection via the same insert path | 5 |
| Pill overlay and sounds | Floating non-activating panel, bottom center. States: listening (level bars), working (spinner), done (check + ms), guard (warning + "Kept raw"). Ticks on start and insert, off by setting | 3 |
| Notetaker | Audio-only Core Audio taps on macOS 14.4+ (ScreenCaptureKit on older systems) + mic as two channels ("Me" / "Others"), VAD-gated ~10 s chunks to whisper, NDJSON lines `{id,timestamp,text,speaker}`, gemma4:31b summary + to-dos saved locally, with optional export to an Obsidian note | 6 |
| Whisper mode | Input gain boost and lower VAD threshold | 3 |
| Team dictionary, sync, sharing | Not built | never |

## Phases

Each phase ends with a proof, not a claim. One GitHub issue per phase in the repo.

### Phase 0. Bench and repo. Done
`bench/FINDINGS.md`, private repo, plan and mockups published.

### Phase 1. Engine prototype. Done
`engine/undertone/` with config, dictionary, audio, stt, cleanup, insert, history, hotkey, cli. Proof: `.venv/bin/undertone once --file bench/dictation.wav --no-insert` returns correct text in 957 ms. Insert test blocked only by Accessibility permission for the calling process; `insert()` now reports that plainly.

### Phase 2. Cleanup quality on real dictations
- Tune `cleanup.py`'s prompt against a private eval set (see `bench/eval_cleanup.py`).
- Add a per-app prompt variant and see whether it lifts similarity on Codex rows.
- Add the em-dash post-filter and the 60% guard to the eval so both are scored.
- Try streaming: run whisper on 5 s windows while the key is held so only cleanup runs on release.
- Targets: qwen3.5 similarity >= 0.90 on n=100 against the reference formatted text, zero rows with word ratio < 0.6, median loop under 900 ms.
- Proof: `bench/RESULTS.md` with the numbers and the chosen default model.

### Phase 3. Menu bar app
- `app/` Swift package, SwiftUI, macOS 14+. Menu bar icon, fn key hold via CGEventTap (Input Monitoring), pill panel per `docs/mockups.html` section 1, sounds, history window (section 4), settings (section 7), the three last-transcript hotkeys.
- Engine becomes a launchd agent (`com.undertone.engine`) serving the socket. App shows "warm / loading" from `status`.
- Insertion moves to Swift (AXUIElement, CGEvent). Same ladder, same rule.
- Proof: dictate into Codex, Claude Desktop, Messages, Ghostty, Mail. Screen recording of each. `pbpaste` unchanged before and after. History shows `insert_mode` = ax or type, never paste.

### Phase 4. Dictionary that learns
Edit watching, screen harvest, inbox card (mockups section 5), context to the cleaner. Proof: misspell a name once, fix it once, dictate it again and it comes out right.

### Phase 5. Command Mode
Selection detection, instruction prompt, replace in place (mockups section 2). Proof: "make this shorter" on a paragraph in Mail.

### Phase 6. Meetings
Core Audio audio-only capture on macOS 14.4+ (ScreenCaptureKit fallback on older systems), VAD, chunked whisper, live recording status and source meters, local summary with optional export to Obsidian at `Meetings/<date> <title>.md`. Proof: one real call, transcript and summary checked against the author's own notes from the same call.

### Phase 7. Daily use
Two weeks of daily use. Compare history tables. Proof: daily use, no paste fallbacks, no guard fires.

## Repo layout

```
undertone/
  AGENTS.md            builder contract (short)
  README.md
  pyproject.toml       engine package, `undertone` CLI
  engine/undertone/    Python engine (exists)
  app/                 Swift menu bar app (Phase 3)
  bench/               benchmarks and eval scripts; bench/private_eval/ is gitignored
  docs/PLAN.md         this file
  docs/plan.html       visual plan
  docs/mockups.html    UI mockups with the pill animation
```

## Conventions for builders

- Python: 3.12 in `.venv` via uv, `from __future__ import annotations`, 4-space, type hints, functions over classes, no docs beyond docstrings.
- Swift: Swift 6, SwiftUI, no third-party dependencies unless a phase says so.
- Tests: proportional. The eval scripts are the test suite for cleanup. Add a unit test only where a repeatable defect would otherwise have no guard.
- Never print transcript text from `bench/private_eval/` in logs, commits, or reports. It is private dictation data and stays off the network and out of version control.
- Every phase PR links its issue and states the proof it ran.
- macOS permissions the app needs: Microphone, Accessibility, Input Monitoring; System Audio Recording Only for meeting audio on macOS 14.4+ (Screen Recording on older systems). Builders cannot grant these; report the gap and stop.

## Runtime facts

- Ollama at `http://localhost:11434`, models `qwen3.5:latest`, `gemma4:31b`. Set `keep_alive` so they stay warm.
- mlx_whisper is a uv tool at `~/.local/share/uv/tools/mlx-whisper/`; the engine venv has its own install.
