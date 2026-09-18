from __future__ import annotations
import json, sys, time, urllib.request
sys.path.insert(0, ".")
from cleanup_test import CASES
from cleanup_test_v2 import SYSTEM_V2
URL = "http://127.0.0.1:8123/v1/chat/completions"
WHISPER_VOCAB = ("Um so hey can you uh send me the the report by Tuesday no wait Wednesday actually because um "
  "I'm out of the office Tuesday and uh yeah just just send it to my work email. And also the plan is Northwind pulls "
  "from the Obsidian vault and then we run it through Ollama locally. Probably the Qwen model.")
cases = dict(CASES); cases["real-whisper"] = WHISPER_VOCAB
def run(text):
    body = {"model": "qwen3-30b-a3b", "temperature": 0.0, "max_tokens": 400,
            "messages": [{"role": "system", "content": SYSTEM_V2}, {"role": "user", "content": text}]}
    req = urllib.request.Request(URL, json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as r: d = json.load(r)
    return d["choices"][0]["message"]["content"].strip(), time.time() - t0
run("um hello")
print("MODEL: Qwen3-30B-A3B-Instruct-2507-4bit via MLX (prompt v2)")
for name, raw in cases.items():
    out, dt = run(raw)
    print(f"\n--- {name}  [{dt:.2f}s]\n{out}")
