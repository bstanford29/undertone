# Transcription review, November 2026

How well Undertone transcribes Brandon's own voice notes, where it goes wrong, which models fit best, and what this review changed. Measured on 2026-11-22 on an M5 Max with 128 GB of memory, models warm, everything local.

## The answer first

| Question | Answer |
|---|---|
| How accurate is it today? | Short dictations: about 96 to 97% of words agree with a consensus of other speech models. Long recordings: **every note over about 7.5 minutes came back empty.** A guard meant to catch looping output treated any long transcript as a loop and threw it away. |
| Is "Qwen" the right model? | Qwen is the *cleanup* model (`qwen3.5`, 9.7B, via Ollama). Speech-to-text is NVIDIA **Parakeet TDT 0.6B v3**. Keep both. Parakeet tied the best open model (Qwen3-ASR 1.7B) on accuracy and runs 4 times faster. For cleanup, qwen3.5 passed 27 of 34 brain-dump cases with the new prompt, up from 17. The larger qwen3.8 passed 30 and is a setting worth trying on this Mac. |
| Brain-dump cleanup | New `tidy_speech` setting, on by default, with a switch in Settings → Cleanup. It removes ums, stutters, false starts, and applies spoken corrections ("no wait, I mean X" becomes X). History still keeps the raw transcript. |
| Speed | Key up to text on his dictations: median 1.28 → **0.72 s**, worst 4.27 → **1.78 s**. On his hands-free brain dumps: median 22.4 → **1.8 s**, worst 30.6 → **5.6 s**. One-shot speech-to-text on long notes is twice as fast. One-shot cleanup of a long note takes as long as before but now actually cleans it. |
| Timestamps | No milliseconds anywhere a person reads them. Meeting notes show `[00:12]`, not `[12.345]`. The app shows `<1 s` or `2 s`, not `742 ms`. |

## How a dictation flows today

```
  hold fn ─► app records 16 kHz mono ─► streams ½-second frames to the engine
                                                    │
   engine cuts the audio at pauses ◄────────────────┘
        │
        ▼
  Parakeet TDT 0.6B v3 decodes each chunk with up to 15 s of context around it (MLX, on device)
        │
        ▼
  words are grouped into cleanup units ─► qwen3.5 cleans each unit (Ollama, localhost)
        │                                      while you are still talking
        ▼
  release fn ─► decode the last few words ─► clean the last unit ─► app types keystrokes
```

- **Engine** (`engine/undertone/`): `stt.py` holds the speech models, `live.py` the while-you-talk pipeline, `cleanup.py` the prompts and the 60% guard, `server.py` the socket.
- **One-shot path**: when live dictation is off, or a live session falls back, the whole file goes through `transcribe` then `clean`.
- **Meetings**: two channels in chunks of up to 2 minutes, Parakeet per chunk, a transcript file, then a Gemma summary and an optional Obsidian note.
- **Settings that matter here**: `stt_backend: parakeet`, `cleanup_model: qwen3.5:latest`, `cleanup_level: medium`, `live_dictation: true`, `live_max_unit_words: 40`.

## The test set

No Undertone history exists on this Mac (`~/.undertone` is absent), and macOS blocks the Voice Memos library without Full Disk Access. That gap is reported, not changed. Two other local sources hold his voice:

- **superwhisper dictations** in iCloud Drive: 264 recordings with their transcripts. These are hold-to-talk dictations, the same job Undertone does.
- **A copy of the Voice Memos library** in iCloud Drive (`Voice Notes/2026-06-25`): 259 recordings, 46 seconds to 14 hours. A local model read the start of each sampled memo and labelled it. Most are calls, not solo notes.

Sample, copied (never moved or edited) into the gitignored `bench/private_eval/transcription_review/`:

| Group | Clips | Audio | Notes |
|---|---:|---:|---|
| Dictations under 30 s | 25 | 6 min | random, fixed seed |
| Dictations 30 s and over | 25 | 18 min | every one of that length |
| Voice memos under 5 min | 8 | 12 min | 2 under 15 dB signal-to-noise |
| Voice memos 5 to 14 min | 9 | 97 min | long recordings; mostly calls |
| **Total** | **67** | **133 min** | |
| Solo brain dumps, a separate group | 7 | 57 min | 5 found among 24 more memos, plus the 2 solo notes above |

Most memos were calls, so 24 more were sampled and labelled the same way. The 7 solo notes, 1 to 13 minutes each, form their own "brain dump" group. They are scored apart from the 133-minute tables.

## How accuracy was measured

There is no human-checked transcript of these recordings. So each system is scored against a **consensus reference**: the word-by-word majority vote of the other model families (Parakeet, Whisper, Apple, Qwen3-ASR), with the scored system's own family left out. Text is normalized first: lower case, no punctuation, numbers as words, fillers removed. Word error rate (WER) is substitutions plus deletions plus insertions, divided by the reference length.

What that means for the numbers:

- They measure **disagreement with the other model families**, not truth. Where the models share a mistake, the consensus repeats it and nobody is charged, so a number can be too low. Where the consensus is wrong, every system that got it right is charged, so a number can be too high. Read the numbers as agreement, and trust the ranking only where the intervals below separate.
- Noisy recordings and crosstalk break the consensus, so those rows say more about the audio than the models.
- Differences come with 95% bootstrap intervals over clips.

Speed is wall time on the same Mac. Live dictation was simulated by streaming each recording through the real `LiveDictation` pipeline at twice real time, with the real Parakeet and Ollama models, then timing the release: key up until the final text is ready.

## Accuracy: what goes wrong today

| Group | Undertone today | With this PR | What happens |
|---|---:|---:|---|
| Dictations under 30 s | 4.1% | 4.1% | Small words (a/the, I'm/I), a few names |
| Dictations 30 s and over | 2.7% | 2.7% | Same |
| Voice memos under 5 min | 18.3% | 17.8% | Crosstalk and quiet speech on calls |
| Voice memos 5 min and over | **95.2%** | **13.6%** | Today 8 of 9 came back **empty** |
| Noisy (under 15 dB) | 39.6% | 40.1% | Every model struggles; consensus is weak |
| **All 133 minutes** | **70.2%** | **11.7%** | |

**Solo brain dumps** (7 notes, 57 minutes, scored the same way):

| Model | Word error |
|---|---:|
| Parakeet today | 76.1% (long notes empty) |
| **Parakeet, this PR** | **20.7%** |
| Qwen3-ASR 1.7B | 22.1% |
| Qwen3-ASR 0.6B | 22.1% |
| Apple SpeechTranscriber | 22.9% |
| Whisper large-v3-turbo | 30.5% |

The models agree less on these recordings than on his dictations, so every number is higher; one note is at 14 dB signal-to-noise. The order is the same.

1. **Long notes vanish (fixed).** A synthetic 6.2-minute note (macOS `say` reading an invented brain dump) shows it without private audio: today's engine returns 0 words with reason `repetition`; this PR returns all 1,311. `_looks_repetitive` in `stt.py` dropped any transcript in which fewer than 30% of the words were distinct. Ordinary speech reuses words, so it crosses that line at about 1,000 to 1,150 words, roughly 7.5 minutes. A 7.2-minute call kept 31% distinct words and survived. A 7.6-minute note had 29% and was discarded whole as a "loop", and so was every longer one. Loops are now caught only when one phrase of up to 8 words repeats over most of the text, at any length.
2. **Quiet and crosstalk audio.** Parakeet deletes more than it invents. On the noisiest call (6 dB) it missed about 1 word in 4 that the others heard. Whisper invents instead: on one quiet 3-minute memo it produced 261 words where the others heard about 130.
3. **Fillers stay in the raw text.** Parakeet keeps "um" and "uh" (about 1.3 per 100 words), repeated words, "you know", and "I mean". Cleanup must remove them.
4. **Explicit corrections are rare in his speech.** No "no wait" or "scratch that" appears in the sample; restarts and "I mean" do. The synthetic cases below cover explicit corrections.
5. **Names.** Every model writes "Whisper Flow" for Wispr Flow. Parakeet wrote "Clawed" for Claude 2 times out of 6; Qwen3-ASR got all 6 right. The personal dictionary can fix both once the terms are in it.
6. **Live decoding costs about a point on short dictations.** The live path decodes chunks cut at pauses. On dictations under 30 s its word error was 5.3%, against 4.1% when the whole file is decoded at once (2.9% against 2.7% at 30 s and over). That predates this PR and is unchanged by it.

## Speech model comparison

Tested locally on the 133-minute sample. Speed is the multiple of real time, so 100× turns a 10-minute note around in 6 seconds.

| Model | WER all | Dictations | Memos 5 min+ | Speed | Size | Fit |
|---|---:|---:|---:|---:|---:|---|
| **Parakeet TDT 0.6B v3**, fixed + chunked (this PR) | **11.7%** | 2.7 / 4.1% | **13.6%** | **152×** | 2.3 GB | Current default. Fastest, tied for most accurate, deletes rather than invents. No vocabulary prompt. |
| Parakeet TDT 0.6B v3 as shipped | 70.2% | 2.7 / 4.1% | 95.2% | 75× | 2.3 GB | Drops long notes. |
| Qwen3-ASR 1.7B (mlx-qwen3-asr) | 12.0% | **2.6 / 3.8%** | 13.9% | 33× | 4.4 GB | Tied on accuracy. 4 times slower. Once returned half of a 1-minute call. Accepts a context prompt, which could help names. New dependency. |
| Apple SpeechTranscriber (macOS 26) | 12.8% | 3.0 / 4.1% | 15.0% | 104× | 0 (built in) | No download, Swift-native. Parakeet leads it on memos by 1.4 points (95% interval 0.8 to 1.9). |
| Qwen3-ASR 0.6B | 13.4% | 3.2 / 4.4% | 15.3% | 66× | 1.8 GB | Behind its larger sibling on every group. |
| Whisper large-v3-turbo | 14.8% | 3.7 / 5.0% | 15.9% | 68× | 1.5 GB | Invents text on quiet audio. Supports a vocabulary prompt. |

Dictation pairs are 30 s and over / under 30 s.

Overall, Parakeet's word error is 0.4 points lower than Qwen3-ASR 1.7B's, with a 95% interval from 1.5 lower to 0.6 higher. That is a tie. Against Whisper it is 3.1 points lower (0.4 to 6.8), a real lead.

**Hosted options, not tested.** Undertone's rule is that nothing leaves the Mac, so his audio was not uploaded anywhere. Published numbers put the best hosted models (OpenAI's gpt-4o-transcribe, Deepgram Nova-3, ElevenLabs Scribe, AssemblyAI Universal) at or ahead of the open models on English benchmarks, at about $0.003 to $0.008 per minute: under a dollar a month for his volume. None fits a local-only app. If that rule ever changes, test Scribe and gpt-4o-transcribe first, on this same sample.

**Recommendation: keep Parakeet.** It ties the most accurate local model, runs 4 times faster, and when it errs on bad audio it leaves words out rather than making them up. Re-test Qwen3-ASR 1.7B if proper nouns become the main complaint, since it can take a vocabulary prompt.

## Cleanup model comparison

Cleanup runs after speech-to-text. It is the model behind the "Qwen" name. `bench/eval_disfluency.py` scores 34 synthetic brain-dump dictations written for this review (`bench/disfluency_cases.json`, safe to commit). A case passes when the output keeps every phrase that carries meaning and drops every filler, repeat, false start, or corrected-away word. Ten of the cases are traps: "I mean what I said", "it actually worked", "that that approach", an instruction inside the dictation.

| Cleanup model and prompt | Passed | Corrections | False starts | Traps kept | Median time | Memory |
|---|---:|---:|---:|---:|---:|---:|
| qwen3.5 9.7B, today's Medium prompt | 17/34 | 0/10 | 1/4 | 9/10 | 0.32 s | 6.6 GB |
| **qwen3.5 9.7B, tidy prompt (new default)** | **27/34** | 7/10 | 2/4 | 9/10 | 0.37 s | 6.6 GB |
| qwen3.8 27.8B, tidy prompt | **30/34** | 8/10 | 4/4 | 9/10 | 0.29 s | 18 GB |
| gemma4 31B, tidy prompt | 30/34 | 8/10 | 3/4 | 9/10 | 1.20 s | 19 GB |
| nemotron-3.5-lightning 33B, tidy prompt | 25/34 | 7/10 | 4/4 | 8/10 | 0.25 s | 25 GB |
| High level (gemma4), today's prompt | 26/34 | 7/10 | 3/4 | 8/10 | 1.19 s | 19 GB |
| High level (gemma4), tidy prompt | 27/34 | 8/10 | 3/4 | 8/10 | 1.21 s | 19 GB |

What the failures are:

- **The 60% guard blocks big corrections in short dictations, by design.** "Put it in the shared drive. Scratch that. Put it in the team folder in Notion" cleans correctly to 8 of 16 words. That is under 60%, so Undertone types the raw words instead. Every model hits this. In a long brain dump one correction is a small share, so the guard does not fire.
- **Some false starts survive on qwen3.5**: "So what I was going to, the plan is…" keeps its first half.
- **One trap fails on every model**: "I think that that approach is the cleanest one" loses a "that". It happened once in his real dictations too.

On his 50 real dictations, both with the tidy prompt, the two Qwen models removed the same fillers (none left). qwen3.8 reworded half as much (0.6% of typed words were not in the raw transcript, against 1.2%) but took 17% longer in total (83 s against 71 s; median 1.33 s against 1.36 s).

**Recommendation: keep qwen3.5 as the default.** It fits on any Apple Silicon Mac and is as good on his real dictations. qwen3.8 is the better model on hard cases. It is worth trying on this Mac, but it needs 18 GB of memory, so it stays a setting, not the default: `cleanup_model: qwen3.8:latest` in `~/.undertone/config.yaml`.

## Brain-dump cleanup

**What it does.** A new setting, `tidy_speech`, is on by default. It changes the Medium and High prompts so the model also:

- deletes filler sounds and filler phrases ("um", "uh", and "like", "you know", "I mean" when they only fill a pause),
- deletes stutters and accidental repeats ("I I think"),
- deletes false starts, keeping only the restart,
- applies spoken corrections: "send it Tuesday, no wait, Wednesday" becomes "send it Wednesday".

Pure filler sounds (um, uh, hmm) are removed by a rule before the model sees the text. The rule ignores all-caps "UM" and "UH", which are acronyms, and "uh-oh". The 60% guard still counts every word heard, fillers included, so a filler-heavy dictation cannot hide lost content; if it fires, Undertone types exactly what was heard. Everything else is the model's call, inside the same guard, the same "never answer the dictation" rule, and the same proper-noun list. A short dictation (6 words or fewer) normally skips the model; one that contains a correction ("Tuesday, sorry, Wednesday") goes to the model when tidy is on.

**Turning it off.** Settings → Cleanup → Brain dumps → "Tidy how you think out loud", or `tidy_speech: false` in `config.yaml`. Off restores exactly the earlier Medium and High prompts. None and Light are unchanged either way.

**The raw transcript stays.** History already stores the raw transcript next to the cleaned one, and the History window's Raw, Cleaned, and Diff tabs show both. Live dictation also writes the raw text beside the audio before any cleanup runs.

**Results on his 50 real dictations** (live path, same audio, cleaned today and with tidy):

| Left in the typed text | Raw transcript | Cleaned today | Cleaned with tidy |
|---|---:|---:|---:|
| um / uh | 30 | 1 | **0** |
| a word said twice in a row | 51 | 5 | 4 |
| "you know" | 19 | 10 | **3** |
| "like," as a filler | 4 | 15 | 6 |
| Words typed, share of raw | 100% | 94.6% | 91.7% |
| Guard fired | | 0 | 0 |

Real before-and-after snippets from his dictations went to Brandon directly, not to GitHub: his transcripts stay out of the repository and off the network.

His recordings contain no explicit "no wait" corrections, so these come from the synthetic set:

| He says | Cleaned today | Cleaned with tidy |
|---|---|---|
| "send the report on Tuesday no wait Wednesday" | Send the report on Tuesday. No, wait, Wednesday. | **Send the report on Wednesday.** |
| "call John, I mean Jim, about the vendor contract" | Call John, I mean Jim, about the vendor contract. | **Call Jim about the vendor contract.** |
| "use the blue template, wait no, the green one for the board deck" | Use the blue template, wait, no, the green one for the board deck. | **Use the green template for the board deck.** |
| "let's, okay so let's draft the email to the controller first" | Let's, okay, so let's draft the email to the controller first. | **Let's draft the email to the controller first.** |

**Results on his 7 solo brain dumps** (live path, 57 minutes):

| Left in the typed text | Raw transcript | Cleaned today | Cleaned with tidy |
|---|---:|---:|---:|
| um / uh | 170 | 115 | **4** |
| a word said twice in a row | 134 | 64 | **13** |
| "you know" | 33 | 30 | 18 |
| Words typed, share of raw | 100% | 97.0% | 90.3% |

Today's release re-cleaned each brain dump in one call, and in one call the model nearly copies a long transcript. With tidy, each sentence-sized unit is cleaned on its own. In 5 of the 7 notes, at least one small unit, mostly filler, would have kept under 60% of its words; the guard typed that unit as heard. That is where the 4 remaining ums come from.

**Known limits.** "Clawed" for Claude is a speech-to-text error; cleanup does not fix names it has not been told about (see the plan). A legitimate "that that" can lose one "that". A correction that deletes more than 40% of a short dictation is blocked by the guard, so the raw words are typed.

**Live dictation and corrections.** A unit never ends right before a correction ("No wait", "Sorry,", "Or rather", a bare "No,"). When one still lands at a unit boundary, for example after a pause ("…Tuesday. [pause] Sorry, Wednesday"), or opens a pause-cut chunk after a false start ("…Tuesday. I was going to [pause] no wait, Wednesday"), release cleans that unit and the one before it again, together, because the correction needs the words it corrects. Today that case re-cleaned the whole recording. It runs only when the active prompt applies corrections; with tidy off, Medium keeps every word anyway. Long one-shot transcripts are split the same way: a correction stays in the piece with the sentence it corrects.

## Speed: where the time goes

Undertone has two paths. Hold-to-talk and hands-free dictation use the **live path**: speech-to-text and cleanup run while he talks, so release only finishes the last few words. The **one-shot path** handles a whole file at once; it runs when live dictation is off and whenever a live session falls back.

**Live path, his 50 dictations, key up until the text is ready:**

| | Today | This PR |
|---|---:|---:|
| Median | 1.28 s | **0.72 s** |
| Slowest 10% | 2.78 s | **1.25 s** |
| Worst | 4.27 s | **1.78 s** |
| Dictations under 30 s, median | 0.83 s | 0.61 s |
| Dictations 30 s and over, median | 1.88 s | 0.90 s |
| Releases that re-cleaned the whole recording | 21 of 50 | **0 of 50** |
| Word error of what was transcribed | 3.42% | 3.42% |

Where the time went: units of text are cleaned while he talks, but a unit could only end where he paused, and only once a sentence had ended exactly at that pause. His sentences often run on (median 13 words; 1 in 10 runs 39 words or more; the longest ran 80), so most units hit the 40-word cap mid-sentence. A unit cut mid-sentence cannot be stitched cleanly, so release threw the live work away and cleaned the whole recording again: 1.3 to 4.3 seconds.

What changed:

1. A unit now ends at the first sentence end once it has 8 words, even in the middle of a pause-cut chunk.
2. The 40-word cap is soft. A unit runs on to finish its sentence and is cut only at 100 words.
3. Units never close right before a correction. When a correction or a 100-word cut still lands at a unit boundary, release cleans only the units on either side of it again, not the whole recording.

After the change, release is the speech-to-text of the last words (about 0.1 s) plus one cleanup call for the last unit (0.4 to 0.9 s). That cleanup call is now the floor.

**Live path, his 7 solo brain dumps (1 to 13 minutes, hands-free), key up until the text is ready:**

| | Today | This PR |
|---|---:|---:|
| Median | 22.4 s | **1.8 s** |
| Worst | 30.6 s | **5.6 s** |
| Releases that re-cleaned the whole recording | 7 of 7 | **0 of 7** |
| Words transcribed | 8,874 | 8,874 |

On a 10-minute note, some boundary almost always carries a correction ("Sorry,", "No,") or a sentence longer than the cap. Today any one of them made release clean the whole note again in one call: 13 to 31 seconds for the six notes of 5 minutes or more (880 to 1,900 words). Now only the units on either side are cleaned again, one call per spot, so a note with several such spots waits a few seconds rather than half a minute.

**One-shot path, same audio:**

| Step | Today | This PR |
|---|---:|---:|
| Speech-to-text, all 133 minutes | 106 s, and 8 long notes came back empty | **52 s**, every note transcribed |
| Speech-to-text, median note over 5 min | 9.5 s | **4.0 s** |
| Cleanup, median voice memo (about 1,200 words) | 18.8 s | 18.1 s |
| Cleanup, longest (about 2,100 words) | 37.4 s | 36.7 s |
| Cleanup, median dictation | 1.30 s | 1.35 s |
| Repo check clip, 15.5 s, `undertone once` warm | 0.99 s | 0.96 s |

Long-note cleanup is bound by how fast the model writes: about 60 words a second on this Mac, so a 2,100-word note takes about 36 s. Cleaning in pieces does not change that. Ollama here runs one request at a time (`OLLAMA_NUM_PARALLEL` is unset). A temporary second Ollama on another port, with four parallel slots, was only 3% faster (24.4 s against 25.1 s median for memos over 800 words), so the pieces run one after another. The pieces exist for quality and safety. In one call, qwen3.5 nearly copies a long transcript: ums went from 1.47 to 1.35 per 100 words, repeats from 183 to 127. In pieces it cleans it like a short one: ums 0 per 100 words, repeats 61. Each piece also gets its own 60% guard, and no call comes near the 8,192-token context window, which a single 2,900-word call would fill.

## Timestamps

| Where | Before | After |
|---|---|---|
| Obsidian meeting note | `[12.345] **me**: ...` | `[00:12] **me**: ...` |
| Past an hour | `[3725.600]` | `[1:02:06]` |
| `transcript.ndjson` | `"timestamp": 12.345` | `"timestamp": 12` |
| Summary prompt lines | `[12.345] me: ...` | `[00:12] me: ...` |
| Dock after typing | `742 ms` | `<1 s` |
| VoiceOver | "Inserted, 742 milliseconds" | "Inserted in under a second" |
| History list | `15 s · 957 ms · Codex` | `15 s audio · done in <1 s · Codex` |
| History detail | `STT 174 ms · LLM 783 ms · Insert 30 ms` | `Speech to text <1 s · Cleanup <1 s · Typing <1 s` |
| Cleanup level cards | `0.6 to 1.1 s`, `1.5 to 3.4 s` | `about 1 s`, `2 to 4 s` |

Internal fields keep their `_ms` names (`stt_ms`, `total_ms`) because the app and the history database read them. They are measurements, not something a person reads.

## Plan

Done in this PR, in the order of what they cost Brandon:

| # | Change | Why this rank |
|---:|---|---|
| 1 | Keep long notes: the loop guard no longer drops long transcripts | Whole notes were lost. Breaks the never-drop-content rule. |
| 2 | Live cleanup units end at sentence ends; the 40-word cap became soft | The largest release delay on his dictations |
| 3 | Brain-dump tidy pass with a switch; raw transcript kept | Requested; his speech is full of restarts |
| 4 | Parakeet decodes recordings over 2 minutes in overlapping windows | Twice as fast on long notes, same accuracy, bounded memory |
| 5 | Long transcripts are cleaned in sentence pieces | One call left long notes nearly uncleaned; each piece now gets its own guard and stays inside the context window |
| 6 | Whole-second times in the app and in exports | Requested |

Recommended next, not done here:

| # | Recommendation | Effort | Why not now |
|---:|---|---|---|
| 1 | Rebuild a private cleanup test set from his own dictations, with about 30 references he checks by hand. The old `bench/private_eval/pairs.jsonl` is not on this Mac. | Small, needs an hour of his review | Needs his judgment of what "right" looks like |
| 2 | Keep the cleanup model loaded longer. After 60 idle minutes Ollama unloads qwen3.5, and the next dictation's cleanup takes 2.2 to 2.7 s instead of 0.4 s. A longer `ollama_keep_alive` (for example `12h`) avoids that. | One setting | It keeps 6.6 GB of memory in use all day. His call. |
| 3 | Make changed defaults reach existing installs (see the pinned-defaults problem below) | Medium | Changes config behavior for every setting |
| 4 | Better names: learn more Parakeet sound-alikes from his corrections (today only "Ollama" has any), or re-test Qwen3-ASR with a vocabulary prompt | Medium | Needs his correction history, which is not on this Mac |
| 5 | Make long one-shot notes feel faster: show the raw transcript at once and swap in the cleaned text when it is ready (about 36 s for a 2,100-word note), or use a faster model for long notes only | Medium | A UI and product decision. Live dictation already avoids this wait. |
| 6 | Use Apple SpeechTranscriber, not Whisper, as the fallback when Parakeet is missing | Medium, Swift side | Only matters on Macs without Parakeet |

## Other problems found, not fixed here

Three limited findings from the independent review are tracked in #24: a long run-on can still be split right after a bare "No,", a tail cleaned beside a regrouped run can see superseded words as reference context, and a failed tail retry turns off cut repair between earlier units. None of them drops words.

| Problem | Effect | Where |
|---|---|---|
| `test_warm_uses_generic_message_for_other_failures` patches only the Whisper class | Fails whenever `parakeet-mlx` is installed, as in the engine's own `.venv`; it then loads the real model and calls real Ollama. CI is green because CI installs no MLX. | `tests/test_server.py` |
| The first run writes every default into `~/.undertone/config.yaml` | A changed default never reaches an existing install. This PR's unit-cap change works around it with a soft cap. | `config.py` `_write_defaults` |
| `load_wav` resamples with straight-line interpolation and no low-pass filter | 44.1 or 48 kHz files alias. Dictation records at 16 kHz, so only imported files are affected. | `audio.py` |
| "Type text as it is cleaned" mode | Still cleans a long transcript in one call. Off by default. | `cleanup.py` `stream_clean_result` |
| Voice Memos library | Readable only with Full Disk Access for the reading process. Reported, not changed. | macOS privacy |
| `bench/dictation.wav` | Ignored by git, so a fresh checkout cannot run the AGENTS.md engine check. This review used the copy in `Projects D/nemotron-bench`. | `.gitignore` |
