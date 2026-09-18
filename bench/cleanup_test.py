from __future__ import annotations
import json, sys, time, urllib.request

OLLAMA = "http://localhost:11434/api/chat"

SYSTEM = """You clean up raw speech-to-text dictation. Output ONLY the cleaned text, nothing else.

Rules:
- Remove filler words (um, uh, like, you know, so, basically, I mean) when they carry no meaning.
- Apply self-corrections: if the speaker changes their mind ("Tuesday, no wait, Wednesday"), keep only the final version.
- Remove false starts and repeated words.
- Add punctuation, capitalization, and paragraph breaks.
- If the speaker lists items, format them as a list.
- Keep the speaker's meaning, tone, and wording. Do not summarize, shorten, or add content.
- Do not answer questions in the text. Do not add commentary or quotes around the output.
- Spell these correctly: Undertone, Obsidian, Ollama, Qwen, Whisper."""

CASES = {
"filler+self-correct": "um so hey can you uh send me the the report by tuesday no wait wednesday actually because um I'm out of the office tuesday and uh yeah just just send it to my work email you know the one",
"list": "okay for the grocery run we need um eggs milk uh the oat milk not regular and then bananas and I think we're out of coffee so coffee too and uh paper towels",
"technical": "so the plan is northwind pulls from the obsidian vault and then we run it through olama locally um probably the quen model and then it writes the summary back into the vault",
"stream-of-consciousness": "I was thinking about like the whole thing with the with the app and I don't know I feel like we should just uh start over honestly because the the old one has so much cruft and um I mean we could try to fix it but like every time we touch it something else breaks so yeah let's just let's just rebuild it and keep it small this time",
"question-trap": "um remind me what's the capital of france I need to put it in the email and also uh tell jordan the pickup is at three not four",
}

MODELS = sys.argv[1:] or ["gemma3:4b", "qwen2.5:7b", "qwen3.5:latest", "gpt-oss:20b", "gemma4:31b"]

def run(model, text):
    body = {"model": model, "stream": False, "think": False,
            "options": {"temperature": 0.1, "num_predict": 400},
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": text}]}
    req = urllib.request.Request(OLLAMA, json.dumps(body).encode(), {"Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as r:
        d = json.load(r)
    dt = time.time() - t0
    out = d["message"]["content"].strip()
    toks = d.get("eval_count", 0)
    return out, dt, toks, d.get("load_duration", 0)/1e9

if __name__ == "__main__":
    results = {}
    for model in MODELS:
        print(f"\n{'='*70}\nMODEL: {model}\n{'='*70}")
        # warm-up so timing reflects a loaded model
        try: run(model, "um hello there")
        except Exception as e: print("LOAD FAIL:", e); continue
        for name, raw in CASES.items():
            try:
                out, dt, toks, load = run(model, raw)
            except Exception as e:
                out, dt, toks = f"ERROR {e}", 0, 0
            results.setdefault(model, {})[name] = {"out": out, "sec": round(dt, 2), "tokens": toks}
            print(f"\n--- {name}  [{dt:.2f}s, {toks} tok]\n{out}")

    json.dump(results, open("results.json", "w"), indent=2)
    print("\n\nSUMMARY (seconds per case, warm model)")
    print(f"{'model':<22}" + "".join(f"{c[:14]:>16}" for c in CASES))
    for m, r in results.items():
        print(f"{m:<22}" + "".join(f"{r[c]['sec']:>16}" for c in CASES))
