# Verification

Run the same automated checks locally and in GitHub Actions:

```sh
uv venv --python 3.12
uv pip install -r requirements-test.txt
scripts/verify.sh
```

Use a dedicated checkout for this lightweight test environment. An existing engine
`.venv` also works. To use another environment, run
`PYTHON=/absolute/path/to/python scripts/verify.sh`. The command works from any
current directory, requires macOS, Python 3.12 or later, and Swift 6 with the macOS
SDK. It stops at the first failing suite.

The command runs Python unittest discovery under `tests/`, then `swift test` in
`app/` with three build jobs. Swift testing compiles the app in debug mode. Python
tests exercise cleanup guards, streaming, local storage, socket requests, and
failure handling with synthetic fixtures and fake model responses. Build-script
tests use fake signing and compiler commands. No signed app is built or installed.

`requirements-test.txt` contains only test imports and their supporting libraries.
It omits MLX speech engines and model weights. Shared dependency minimums follow
`pyproject.toml`; these are compatible ranges, not a dependency lock. Model Hub
downloads and telemetry are disabled while tests run. Some synthetic tests use
loopback HTTP or Unix sockets; this is not an entirely network-sandboxed runner.
The command does not run private benchmarks or upload artifacts.

## GitHub Actions

`.github/workflows/ci.yml` runs the command for pull requests, pushes to `main`, and
manual dispatches. The hosted Apple Silicon `macos-26` runner uses Xcode 26.5 and
Python 3.12. Actions are pinned to commit SHAs, the token has read-only contents
permission, checkout does not retain credentials, and superseded runs are
cancelled. A run has a 20-minute limit.

When updating the toolchain, check the [runner image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)
for the selected Xcode path. Hosted images change; the workflow records toolchain
versions so a failure can be tied to the version that ran. Update each action's
commit pin deliberately after checking its upstream release.

A green run proves compilation and synthetic regression checks. It does not
prove a signed production build, installed-app behavior, model quality, permission
access, or daily-use readiness. Branch protection and merge approval are separate
repository settings; adding this workflow does not configure them.

## Local acceptance before release

Use [PLAN.md](PLAN.md) and [the builder contract](../AGENTS.md) for the acceptance
requirements. Keep private recordings, transcript text, dictionary entries,
history databases, and benchmark pairs out of GitHub logs, artifacts, and commits.
Record only safe aggregate results and the tested source revision.

- **Dictation and models:** run the prescribed local `undertone once` and cleanup
  evaluation checks with approved local recordings and installed models. Check
  sentence retention, proper names, guard behavior, and latency.
- **Insertion and recovery:** dictate into real target apps, verify the clipboard
  is unchanged, and check focus-change and unavailable-model recovery without
  losing the recording or inserting into the wrong app.
- **Meeting capture and persistence:** exercise microphone and system audio,
  stop/save, then reopen the meeting and compare the transcript and summary to
  local notes. Verify an interrupted capture can be recovered.
- **Permissions and UI:** verify required permissions by hand and inspect light
  and dark appearances when UI changes. Report permission gaps; automated tests
  do not grant permissions.

Do not treat synthetic test results as permission to install, restart, release,
or change macOS settings.
