from __future__ import annotations

import argparse
import json
import sys
import time

from . import insert
from .audio import load_wav
from .config import load_config
from .dictionary import load_dictionary
from .doctor import cmd_doctor
from .hotkey import listen, run_dictation_cycle
from .learning import add_explicit_term
from .stt import make_transcriber


def cmd_listen(args: argparse.Namespace) -> None:
    config = load_config()
    listen(config)


def cmd_serve(args: argparse.Namespace) -> None:
    from pathlib import Path
    from .server import serve
    serve(Path(args.socket).expanduser() if args.socket else None)


def cmd_once(args: argparse.Namespace) -> None:
    config = load_config()
    if args.model:
        config["stt_model"] = args.model
    if args.level:
        config["cleanup_level"] = args.level

    dictionary = load_dictionary()
    audio = load_wav(args.file)

    transcriber = make_transcriber(config)
    transcriber.warm_up()

    result = run_dictation_cycle(
        audio,
        transcriber,
        config,
        dictionary,
        do_insert=not args.no_insert,
    )
    print(json.dumps(result, indent=2))


def cmd_insert_test(args: argparse.Namespace) -> None:
    print("focus a text field in the next 3 seconds...")
    time.sleep(3)
    mode = insert.insert(args.text, mode="auto")
    print(f"insert result: {mode}")


def cmd_dictionary_add(args: argparse.Namespace) -> None:
    dictionary = add_explicit_term(args.term)
    print(f"added '{args.term}'. terms: {dictionary['terms']}")


def cmd_update(args: argparse.Namespace) -> None:
    from pathlib import Path
    from . import updater
    state_dir = Path(args.state_dir).expanduser() if args.state_dir else None
    app = updater.valid_app_path(args.app) if args.app else None
    repo = Path(args.repo).expanduser() if args.repo else updater.REPO_ROOT
    if not (args.apply or args.undo):
        info = updater.check(repo, app)
        print(info["message"])
        for change in info.get("changes", []):
            print(f"  {change['commit']}  {change['title']}")
        if info.get("state") == "ready":
            print("Run `undertone update --apply` to install.")
        sys.exit(0 if info.get("state") in {"current", "ready"} else 1)
    if args.detached:
        out, log = sys.stdout, None
    else:
        updater.log_path(state_dir).parent.mkdir(parents=True, exist_ok=True)
        log = updater.log_path(state_dir).open("a")
        out = updater.Tee(sys.stdout, log)
    run = {"state_dir": state_dir, "out": out, "lock_fd": args.lock_fd, "run_id": args.run_id}
    try:
        if args.undo:
            result = updater.undo(repo, **run)
        else:
            result = updater.apply(repo, app, expect=args.expect, **run)
    except updater.StepFailed as exc:
        print(exc, file=out)
        sys.exit(1)
    finally:
        if log is not None:
            log.close()
    if not args.detached and result.get("state") == "done":
        # The updater never restarts the engine or quits the app itself, so a
        # dictation or meeting in progress is never cut off.
        if result.get("restart_engine"):
            print("Restart the engine to finish: Settings → Privacy → Restart, or launchctl kickstart.")
        if result.get("relaunch"):
            print("Then quit Undertone and open it again.")
    sys.exit(0 if result.get("state") == "done" else 1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="undertone")
    subparsers = parser.add_subparsers(dest="command", required=True)

    p_serve = subparsers.add_parser("serve", help="serve the local native app over a Unix socket")
    p_serve.add_argument("--socket", default=None)
    p_serve.set_defaults(func=cmd_serve)

    p_listen = subparsers.add_parser("listen", help="hold-to-talk dictation loop")
    p_listen.set_defaults(func=cmd_listen)

    p_once = subparsers.add_parser("once", help="run the pipeline once on a wav file")
    p_once.add_argument("--file", required=True)
    p_once.add_argument("--no-insert", action="store_true")
    p_once.add_argument("--model", default=None)
    p_once.add_argument("--level", default=None, choices=["none", "light", "medium", "high"])
    p_once.set_defaults(func=cmd_once)

    p_insert_test = subparsers.add_parser("insert-test", help="test text insertion into the frontmost app")
    p_insert_test.add_argument("text")
    p_insert_test.set_defaults(func=cmd_insert_test)

    p_dict = subparsers.add_parser("dictionary", help="manage the personal dictionary")
    dict_sub = p_dict.add_subparsers(dest="dict_command", required=True)
    p_dict_add = dict_sub.add_parser("add", help="add a term")
    p_dict_add.add_argument("term")
    p_dict_add.set_defaults(func=cmd_dictionary_add)

    p_doctor = subparsers.add_parser("doctor", help="check that models and services are ready")
    p_doctor.add_argument("--json", action="store_true", help="print machine-readable JSON")
    p_doctor.add_argument("--download", action="store_true", help="download the whisper model if not cached")
    p_doctor.set_defaults(func=cmd_doctor)

    p_update = subparsers.add_parser("update", help="check GitHub for a newer Undertone, or install it")
    action = p_update.add_mutually_exclusive_group()
    action.add_argument("--apply", action="store_true", help="install the newest main")
    action.add_argument("--undo", action="store_true", help="go back to the version before the last update")
    p_update.add_argument("--app", default=None, help="the installed Undertone.app to replace")
    p_update.add_argument("--repo", default=None, help=argparse.SUPPRESS)
    p_update.add_argument("--state-dir", default=None, help=argparse.SUPPRESS)
    p_update.add_argument("--expect", default=None, help="with --apply: install only this commit of main")
    p_update.add_argument("--detached", action="store_true", help=argparse.SUPPRESS)
    p_update.add_argument("--lock-fd", type=int, default=None, help=argparse.SUPPRESS)
    p_update.add_argument("--run-id", default=None, help=argparse.SUPPRESS)
    p_update.set_defaults(func=cmd_update)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
