from __future__ import annotations
import time, mlx_whisper
M = "mlx-community/whisper-large-v3-turbo"
VOCAB = "Undertone, Obsidian, Ollama, Qwen, Whisper."
for i, kw in enumerate([{}, {}, {"initial_prompt": VOCAB}]):
    t0 = time.time()
    r = mlx_whisper.transcribe("dictation.wav", path_or_hf_repo=M, language="en", temperature=0.0, **kw)
    tag = "cold" if i == 0 else ("warm" if i == 1 else "warm+vocab")
    print(f"[{tag}] {time.time()-t0:.2f}s  ->", r["text"].strip())
