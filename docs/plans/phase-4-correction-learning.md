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
