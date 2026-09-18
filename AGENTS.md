# Undertone builder contract

Read `docs/PLAN.md` first. It is the build brief. `docs/mockups.html` is the UI spec. This file is short on purpose.

## Rules

- Dictation never writes the clipboard. Insertion types keystrokes; the Accessibility API is only for command-mode replace and undo. Paste stays off.
- Never drop content. The 60% word-count guard is not optional.
- Nothing leaves the machine. Localhost Ollama only.
- `bench/private_eval/` is private data. Never print its text in logs, reports, or commits. It is gitignored; keep it that way.
- One GitHub issue per phase. Work on a branch named `phase-N-short-name`. A PR states the proof it ran.
- Report macOS permission gaps; do not change System Settings.

## Verify before claiming

- Engine: `.venv/bin/undertone once --file bench/dictation.wav --no-insert` must return "Ollama" and "Qwen" spelled right and keep every sentence.
- Cleanup quality: `python3 bench/eval_cleanup.py --model <m> --n 30`.
- Insertion: a text field in a real app, `pbpaste` unchanged before and after.
- Anything visual: screenshot in light and dark.

## Stack

Python 3.12 in `.venv` (uv) for the engine. Swift 6 and SwiftUI for the app. No third-party Swift dependencies unless a phase says so.
