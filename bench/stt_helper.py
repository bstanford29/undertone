"""STT subprocess helper: runs mlx_whisper on a list of wav paths.

Run with the mlx-whisper tool's own interpreter, not system python3:
    ~/.local/share/uv/tools/mlx-whisper/bin/python \\
        bench/stt_helper.py <wav_path> [<wav_path> ...]

Loads the model once, then prints one JSON line per file to stdout:
    {"path": ..., "text": ..., "ms": ...}
"""
from __future__ import annotations

import json
import sys
import time

MODEL = "mlx-community/whisper-large-v3-turbo"


def main() -> None:
    paths = sys.argv[1:]
    if not paths:
        return

    import mlx_whisper

    for path in paths:
        start = time.time()
        try:
            result = mlx_whisper.transcribe(path, path_or_hf_repo=MODEL)
            text = result.get("text", "").strip()
            ok = True
        except Exception as exc:  # noqa: BLE001 - report and keep going
            text = f"__error__: {exc}"
            ok = False
        ms = (time.time() - start) * 1000.0
        print(json.dumps({"path": path, "text": text, "ms": ms, "ok": ok}))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
