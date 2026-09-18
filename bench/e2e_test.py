from __future__ import annotations
import json, sys, time, urllib.request
sys.path.insert(0, ".")
from cleanup_test import OLLAMA
from cleanup_test_v2 import SYSTEM_V2
raw = open("dictation.txt").read().strip()
print("RAW WHISPER OUTPUT:\n", raw, "\n")
for model in ["qwen2.5:7b", "qwen3.5:latest", "gemma4:31b"]:
    body = {"model": model, "stream": False, "think": False,
            "options": {"temperature": 0.0, "num_predict": 400},
            "messages": [{"role": "system", "content": SYSTEM_V2}, {"role": "user", "content": raw}]}
    req = urllib.request.Request(OLLAMA, json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as r: d = json.load(r)
    print(f"=== {model} [{time.time()-t0:.2f}s] ===\n{d['message']['content'].strip()}\n")
