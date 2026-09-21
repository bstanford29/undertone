# Undertone engine socket

The engine speaks newline-delimited JSON (NDJSON) over a Unix domain socket. Each request is one JSON object followed by `\n`; each response mirrors the request's `id`. The default path is `~/.undertone/engine.sock`. The CLI accepts `serve --socket /absolute/path/engine.sock` for an isolated path.

This document describes the operations implemented by `engine/undertone/server.py`, including local meeting retention and export.

## Boundaries

- Request and response frames are capped at 4 MiB.
- The server reads a frame for at most 30 seconds and rejects an unterminated frame.
- At most 32 client handlers run at once. The listen queue is also 32. An additional client receives `busy` and is closed.
- Non-status engine operations share one lock, so model work is serialized. `status` stays responsive while Whisper or Ollama is warming or processing.
- The socket is created with mode `0600`. An active existing socket is never replaced. A stale socket may be removed only after a refused connection; a non-socket path and symlink are rejected.
- Error responses contain stable generic messages. Transcript text and model exception payloads are not logged or returned as errors.
- Whisper uses the local cached model path. Ollama is accepted only at an HTTP `localhost`, `127.0.0.1`, or `::1` URL.

## Request envelope

Every request needs an integer or string `id`. Boolean IDs are rejected. The `op` field selects the operation.

```json
{"id":1,"op":"status"}
```

Malformed JSON, a non-object, a missing or invalid ID, or a frame without a final newline returns an error with `id: null`. A valid request whose arguments fail validation keeps its request ID.

## Status

Request:

```json
{"id":1,"op":"status"}
```

Response:

```json
{"id":1,"whisper":"loading","cleanup":"loading","model":"qwen3.5:latest","error_message":null}
```

`whisper` and `cleanup` are `loading`, `warm`, or `error`. `error_message` is a generic warm-up message when the engine cannot load its local models.

## Transcription

`audio_path` must be an existing absolute local file. `vocab_extra` is optional, defaults to `[]`, and accepts at most 100 strings of at most 200 characters each.

```json
{"id":2,"op":"transcribe","audio_path":"/tmp/fixture.wav","vocab_extra":["Qwen"]}
```

```json
{"id":2,"raw":"Synthetic transcript.","stt_ms":174.0,"model":"mlx-community/whisper-large-v3-turbo"}
```

The path is read locally and is not included in errors. Empty audio produces an empty raw result without invoking Whisper.

## Cleanup

`raw` is required. `level` defaults to the configured level and must be `none`, `light`, `medium`, or `high`. `app` is optional and limited to 300 characters. `context` is optional and, when present, contains only `before`, `after`, and `selected`, each a string of at most 2,000 characters. The engine sends this context to local Ollama in a separate escaped data boundary; it is never persisted or logged. The 60% content guard compares only the raw transcript, so surrounding context cannot satisfy or weaken it.

```json
{"id":3,"op":"clean","raw":"Synthetic raw words","level":"medium","app":"com.openai.codex","context":{"before":"","after":"","selected":""}}
```

```json
{"id":3,"clean":"Synthetic cleaned words.","model":"qwen3.5:latest","guard_fired":false,"llm_ms":783.0}
```

The underlying `clean_result` includes canonical `text`/`clean_text`, guard, fallback, and model metadata. The socket response exposes the stable app fields `clean`, `model`, `guard_fired`, and `llm_ms`. The 60% content guard and local fallback are engine behavior.

## Configuration

Read the merged configuration:

```json
{"id":4,"op":"config.get"}
```

Update only these keys:

| Key | Values |
| --- | --- |
| `cleanup_level` | `none`, `light`, `medium`, `high` |
| `hold_key` | `f13`, `right_option`, `right_cmd` |
| `sounds` | boolean |
| `whisper_mode` | boolean |
| `toggle_mode` | boolean |
| `streaming` | boolean |
| `obsidian_vault_path` | existing absolute directory, or empty to unset |

Defaults include `cleanup_level: medium`, `hold_key: f13`, `sounds: true`, `whisper_mode: false`, `toggle_mode: false`, and `streaming: false`. The current app sends ordinary transcribe and clean requests; streaming remains opt-in while its measured proof is pending.

```json
{"id":5,"op":"config.update","config":{"cleanup_level":"high","streaming":false}}
```

The response returns the merged `config`. Model names, Ollama URL, insertion mode, and prompt variants are read-only through this operation. Ollama URL changes are rejected and non-local configured URLs are rejected before cleanup or warm-up.

## Meetings

Meeting capture stays in the native app. The app sends local audio chunk paths
to the engine; the engine copies each chunk into `~/.undertone/meetings` (or
the configured engine directory), saves its row before STT, and retains the
audio and transcript after failures. Nothing is uploaded. `speaker` is `me` or
`others`; sequence numbers start at zero and must be contiguous. The native
capture sends `voice_activity` (default `true`) for each chunk. A quiet chunk is
still retained and written to the transcript, but completes with empty text
without invoking Whisper. A retry with the same sequence and metadata is
idempotent, while a mismatch is rejected.

```json
{"id":20,"op":"meeting.start","title":"Synthetic meeting"}
{"id":21,"op":"meeting.chunk","session_id":"<session_id>","seq":0,"audio_path":"/tmp/fixture.wav","speaker":"me","offset_s":0,"duration_s":1}
{"id":22,"op":"meeting.get","session_id":"<session_id>","offset":0,"limit":100}
{"id":23,"op":"meeting.list","limit":50}
{"id":24,"op":"meeting.end","session_id":"<session_id>"}
```

`meeting.start` returns a `session` object containing `session_id`, timestamps,
status, and transcript path.
`meeting.chunk` returns `status`, `text`, and `stt_ms`; a failed local STT call
returns `status:"error"` with `error_code:"stt_failed"`, and the same chunk
can be retried. `meeting.get` returns a bounded `session` with chunk rows and
`next_offset`; `meeting.list` returns bounded session summaries. A meeting with
untranscribed chunks cannot end.

Set `obsidian_vault_path` explicitly through `config.update` before exporting:

```json
{"id":25,"op":"config.update","config":{"obsidian_vault_path":"/Users/example/Vault"}}
```

An unset path never guesses a vault and `meeting.end` returns the retained
session with `status:"needs_vault"`. With a configured existing directory,
the engine summarizes through the high local Ollama model and atomically writes
`Meetings/<date> <sanitized title> [session].md`. The note includes the full
timestamped transcript and a session marker. Existing or symlinked notes are
never overwritten. `meeting.recover` retries an errored or vaultless export
after configuration. Summary inputs are bounded by sections; if synthesis
fails, audio, rows, and the NDJSON transcript remain available for retry.

## Dictionary

```json
{"id":6,"op":"dictionary.list"}
{"id":7,"op":"dictionary.add","term":"Qwen"}
{"id":8,"op":"dictionary.remove","term":"Qwen"}
{"id":9,"op":"dictionary.replace","phrase":"btw","replacement":"by the way"}
```

`dictionary.add` accepts a non-empty term up to 200 characters. `dictionary.remove` accepts a term up to 200 characters. `dictionary.replace` accepts a non-empty phrase up to 1,000 characters and a replacement up to 10,000 characters. Responses contain the current `terms` and `replacements` maps.

## History

Record a dictation and its timings:

```json
{"id":10,"op":"history.record","raw_text":"Synthetic raw.","clean_text":"Synthetic clean.","stt_ms":174.0,"llm_ms":783.0,"insert_ms":30.0,"total_ms":987.0,"insert_mode":"ax","audio_seconds":15.0,"app_bundle_id":"com.openai.codex","guard_fired":false,"model":"qwen3.5:latest","audio_path":"/tmp/fixture.wav"}
```

Required text fields are capped at 1,000,000 characters. Timings default to zero, must be finite non-negative numbers, and reject booleans. `insert_mode` is `ax`, `type`, `failed`, or `skipped`. Optional `app_bundle_id`, `model`, and `audio_path` are validated strings. The response is `{"id":10,"row_id":1}`.

Insertion is recorded in two steps so a process exit cannot lose a
transcript after the text has been inserted. The app first records the full
row with `insert_mode:"skipped"`, then inserts into the focused field, then
updates only the insertion metadata:

```json
{"id":14,"op":"history.update","row_id":1,"insert_mode":"ax","insert_ms":30.0,"total_ms":987.0}
```

`history.update` accepts `row_id`, `insert_mode`, `insert_ms`, and `total_ms`,
plus optional `edited_text` (and the request envelope). `edited_text` is the
user's inserted edited span and is capped at 1,000,000 characters. `insert_mode`
must be `ax`, `type`, `failed`, or `skipped`; paste is rejected. A missing row
is an invalid request. If the post-insert update fails, the app keeps the insertion undo
state and reports that the history outcome is unknown; it does not retry the
insertion.

List or retrieve rows:

```json
{"id":11,"op":"history.list","limit":50,"query":"Synthetic","app":"com.openai.codex","after":0,"before":4102444800}
{"id":12,"op":"history.last"}
```

`limit` defaults to 50 and must be 1 through 1,000. `query` searches `raw_text` and `clean_text`; `app` filters `app_bundle_id`; `after` and `before` filter Unix-second timestamps. Responses contain `rows` or a nullable `row`. History text is returned only by these explicit read operations, never by error messages or server logs.

Delete is explicit:

```json
{"id":13,"op":"history.delete","row_id":1}
```

The response is `{"id":13,"deleted":1}`. There is no automatic history deletion operation.

## Learned dictionary suggestions

The engine keeps pending post-insert edit suggestions in the local history
database. A proposal must identify an existing history row and its exact
`app_bundle_id`; this prevents an edit from one application being attached to
another application's dictation. Produced and replacement phrases are bounded
to 200 characters and 12 words and control characters are rejected.

```json
{"id":15,"op":"learned.propose","produced":"Priya","replacement":"Priya Vale","row_id":1,"app_bundle_id":"com.example.editor"}
{"id":16,"op":"learned.list"}
{"id":17,"op":"learned.add","suggestion_id":1}
{"id":18,"op":"learned.ignore","suggestion_id":2}
{"id":19,"op":"learned.never_ask","suggestion_id":3}
```

`learned.propose` returns `{"suggestion":null}` for a duplicate or a
previously suppressed produced phrase. A new suggestion contains only `id`,
`produced`, `replacement`, `row_id`, `app_bundle_id`, `created_at`, and
`reason`. `learned.list` returns pending suggestions in newest-first order.
Within these suggestion actions, only `learned.add` writes the replacement term
to the personal dictionary; ignore and never-ask do not. Every action is persisted locally and is safe to
retry with the same outcome. No suggestion text is included in errors or logs.

## Correction learning

Correction learning is enabled only by the persisted `learn_from_corrections`
setting. The app sends a client-generated opaque `client_token` (1 to 128 ASCII
letters, numbers, `_`, or `-`) with each `learning.auto_learn` request. The
token contains no candidate text and makes a repeated request idempotent.

```json
{"id":30,"op":"learning.auto_learn","produced":"Valora","replacement":"Velora","row_id":1,"app_bundle_id":"com.example.editor","client_token":"velora-token"}
```

The response is `status:"learned"` with `action_id`, `term`,
`client_token`, and `action_status:"active"`; `already_known` and `disabled`
are non-learning outcomes. The server never trusts a request-supplied enabled
flag. If a response is lost, the client performs this reconciliation lookup:

```json
{"id":31,"op":"learning.lookup","client_token":"velora-token"}
```

The lookup never creates a dictionary term. It only finishes or discards the
journaled action based on whether that term reached the local dictionary.

Lookup returns `status:"learned"` with the same action ID, term, and
`action_status`, or `status:"not_found"`. An active action can be shown as a
new Undo notice. `superseded` and `undone` actions do not create a new Undo
notice. The token is retained locally until lookup definitively finds or does
not find the action.

Undo is action-scoped and safe to repeat:

```json
{"id":32,"op":"learning.undo","action_id":12}
```

Semantic statuses are `removed` (the term was removed), `absent` (it was
already removed), `preserved` (another active learning action owns the term),
`superseded` (a later explicit dictionary action owns it), and `undone` (the
action was already consumed). These operations change only the vocabulary
term owned by the action; edited destination text is unaffected.

## Error responses

The server uses these stable error codes:

| Code | Meaning |
| --- | --- |
| `invalid_json` | Malformed JSON, non-object, missing ID, or unterminated frame |
| `invalid_request` | Invalid operation or argument types/values |
| `engine_error` | Local operation failed; retain audio and retry |
| `too_large` | Request frame exceeds 4 MiB |
| `response_too_large` | Response exceeds 4 MiB |
| `busy` | The 32-client server bound is full |

Example:

```json
{"id":14,"error":{"code":"invalid_request","message":"Invalid operation or arguments"}}
```

## Local app and launchd

Build the Swift app from the repository root:

```sh
app/scripts/build_app.sh
```

Run the fixture-only preview with `--preview`. Use `--preview --appearance light|dark` or the in-preview Appearance picker to choose the local app appearance. The app uses the default socket unless `--socket /absolute/path/engine.sock` or `UNDERTONE_SOCKET` supplies one.

Prepare a launchd plist for review without loading it:

```sh
PYTHONPATH=engine .venv/bin/python scripts/prepare_launchd.py \
  --python "$(pwd)/.venv/bin/python" \
  --output /tmp/com.undertone.engine.plist
```

The preparation script points launchd at `undertone.cli serve`, sets this checkout's `PYTHONPATH`, and sets `HF_HUB_OFFLINE=1`. It does not install or activate the service.

### `history.complete`

After retaining the raw row with `insert_mode: skipped`, set `row_id`, `clean_text`, nullable `model`, Boolean `guard_fired`, and nonnegative `llm_ms`. This only updates a skipped row and never changes raw text or audio. Complete before insertion; use `history.update` only for the subsequent insertion outcome.

### Command Mode

`command` (alias `command.rewrite`) accepts nonempty `selected` and `instruction` and returns `rewrite`, `model`, `llm_ms`. The high local model may intentionally shorten the selection; dictation's 60% retention guard does not apply. Empty/model-error output is rejected.

Before requesting a rewrite, save `history.record` with `kind: command`, original selection as `raw_text`, and spoken instruction as `instruction_text`. Complete with the rewrite before attempting insertion. Only the app may replace the still-matching selection; changed focus skips insertion. Undo restores the original selection. Ordinary rows default to `kind: dictation`.
