# Phase 4 correction learning

Issue: https://github.com/bstanford29/undertone/issues/1

Project: https://github.com/users/bstanford29/projects/9

## Outcome

When the opt-in setting is enabled, Undertone observes a clear single-word correction inside the exact recent dictated span, records the edited text, learns a new vocabulary term once, and presents a non-activating Undo action. Undo removes only that learning action and leaves the user's corrected sentence intact.

## Implementation

1. Add a persisted Swift setting, default off, for correction learning.
2. Preserve the existing same-target, bounded-time, stable-edit, same-word-count, one-change checks in `EditWatcher`.
3. Extend the engine learning contract with an idempotent auto-learn operation and an action-scoped undo operation.
4. Distinguish a newly learned term from an already-known term. Do not create duplicate terms or replacement rules.
5. Show the result through Undertone's existing transient overlay without activating the app or moving focus.
6. Keep uncertain, deleted, and rewritten text on the existing suggestion/skip path.

## Safety boundaries

- Local storage and localhost engine only.
- No clipboard writes.
- No general text-field monitoring outside the recent insertion receipt.
- No acoustic training, global replacements, screen harvesting, or meeting learning.
- Synthetic fixtures only in committed tests and documentation.
- Private evaluation data, personal history, audio, and dictionary contents never enter Git or public output.

## Verification

- Python tests: auto-learn, already-known, undo ownership, repeated calls, and invalid/conflicting actions.
- Swift tests: setting default/persistence, classification guard cases, callback behavior, and overlay state.
- Full relevant test suites and app build.
- Exact-head Anthropic read-only review after the OpenAI/Luna build.
- Native proof in TextEdit and Codex, with clipboard hashes unchanged and light/dark screenshots, before any merge or installation claim.

## Delivery boundary

The reviewed branch and PR may be prepared under Brandon's build authorization. Merge and installation remain human-required steps.

## September 30 native acceptance repair

Reported symptoms: the right-edge overlay cuts off timing text, and correcting a name did not produce a learning notice. The correction occurred within the existing 20-second watch window.

- Repair panel resizing after published model values are assigned. Verify actual controller frames for timing and learning notices on the right edge.
- Add correction-observer diagnostics containing only history row IDs, field-availability flags, and event names. Never log dictated or corrected text.
- Use a signed installed build and a fresh native correction to identify the observer failure before declaring correction learning accepted.
- Keep the existing phase issue, branch, and PR. The previously authorized installation may be updated with a reversible application backup; merge remains gated on native acceptance and human approval.

The existing PR review also identified a concurrent dictionary ownership race. Automatic learning now takes the SQLite writer lock before checking whether a term exists and rechecks ownership after its durable journal commit. Manual writes and recovery use the same lock order, so a simultaneous explicit addition keeps its spelling and cannot be removed by the automatic action's Undo. A spawned-process regression covers this boundary; its lock assertion fails on the prior code.

Brandon authorized one additional bounded repair-and-review pass on October 1. The manual journal completion now reasserts explicit ownership after reacquiring the writer lock, immediately before writing YAML. Deterministic tests inject an automatic action in that gap for both manual additions and accepted suggestions; both fail before this change and pass afterward. No merge is authorized by this repair approval.
