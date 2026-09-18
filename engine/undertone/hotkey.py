from __future__ import annotations

import logging
import time
import threading
import uuid
from pathlib import Path
from typing import Any

from pynput import keyboard

from . import history, insert
from .audio import Recorder, SAMPLE_RATE
from .cleanup import clean_result
from .dictionary import load_dictionary, vocab_prompt
from .stt import Transcriber

logger = logging.getLogger("undertone.hotkey")

HOLD_KEY_MAP = {
    "f13": keyboard.Key.f13,
    "right_option": keyboard.Key.alt_r,
    "right_cmd": keyboard.Key.cmd_r,
}


def run_dictation_cycle(
    audio,
    transcriber: Transcriber,
    config: dict[str, Any],
    dictionary: dict[str, Any],
    do_insert: bool = True,
    app_bundle_id: str | None = None,
    raw_text_override: str | None = None,
    stt_ms_override: float = 0.0,
    audio_path: str | None = None,
) -> dict[str, Any]:
    t_start = time.perf_counter()
    app_bundle_id = app_bundle_id or history.frontmost_bundle_id()
    audio_path = audio_path or save_audio(audio)

    t0 = time.perf_counter()
    vocab = vocab_prompt(dictionary)
    raw_text = raw_text_override if raw_text_override is not None else transcriber.transcribe(audio, vocab=vocab)
    stt_ms = stt_ms_override + (0.0 if raw_text_override is not None else (time.perf_counter() - t0) * 1000)

    t0 = time.perf_counter()
    level = config.get("cleanup_level", "medium")
    result = clean_result(raw_text, level, dictionary, config, app=app_bundle_id)
    clean_text = result["clean_text"]
    llm_ms = (time.perf_counter() - t0) * 1000

    insert_ms = 0.0
    insert_mode_used = "skipped"
    if do_insert and clean_text:
        t0 = time.perf_counter()
        if app_bundle_id and history.frontmost_bundle_id() != app_bundle_id:
            insert_mode_used = "failed"
            logger.warning("Insertion skipped because the target application changed; dictation retained")
        else:
            try:
                insert_mode_used = insert.insert(clean_text, mode="auto", config=config)
            except Exception as exc:
                insert_mode_used = "failed"
                logger.warning("Insertion failed (%s); dictation retained", type(exc).__name__)
        insert_ms = (time.perf_counter() - t0) * 1000

    total_ms = (time.perf_counter() - t_start) * 1000 + stt_ms_override

    audio_seconds = len(audio) / SAMPLE_RATE if hasattr(audio, "__len__") else 0.0
    history.record(
        raw_text=raw_text,
        clean_text=clean_text,
        stt_ms=stt_ms,
        llm_ms=llm_ms,
        insert_ms=insert_ms,
        total_ms=total_ms,
        insert_mode=insert_mode_used,
        audio_seconds=audio_seconds,
        app_bundle_id=app_bundle_id,
        guard_fired=result["guard_fired"],
        model=result["model"],
        audio_path=audio_path,
    )

    return {
        "raw_text": raw_text,
        "clean_text": clean_text,
        "stt_ms": stt_ms,
        "llm_ms": llm_ms,
        "insert_ms": insert_ms,
        "total_ms": total_ms,
        "insert_mode": insert_mode_used,
        "guard_fired": result["guard_fired"],
        "model": result["model"],
        "audio_path": audio_path,
    }


def save_audio(audio) -> str:
    """Retain the complete recording before model or insertion work can fail."""
    import soundfile as sf
    directory = Path.home() / ".undertone" / "audio"
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / f"{uuid.uuid4()}.wav"
    sf.write(path, audio, SAMPLE_RATE, subtype="PCM_16")
    path.chmod(0o600)
    return str(path)


def listen(config: dict[str, Any]) -> None:
    """Temporary F13 listener; the native app owns fn and insertion in Phase 3."""
    from .streaming import StreamingTranscriber
    transcriber = Transcriber(model=config.get("stt_model"))
    transcriber.warm_up()
    recorder = Recorder()
    hold_key = HOLD_KEY_MAP.get(config.get("hold_key", "f13"), keyboard.Key.f13)
    state = {"recording": False, "working": False, "stream": None, "app": None, "timer": None}
    stop_timer = threading.Event()
    dictionary = load_dictionary()

    def snapshots(stream, vocab) -> None:
        while not stop_timer.wait(5):
            try:
                stream.submit_snapshot(recorder.snapshot(), vocab=vocab)
            except RuntimeError:
                return

    def start_recording() -> None:
        nonlocal dictionary
        if state["recording"] or state["working"]:
            return
        dictionary = load_dictionary()
        state["app"] = history.frontmost_bundle_id()
        recorder.start()
        state["recording"] = True
        stop_timer.clear()
        if config.get("streaming", False):
            stream = StreamingTranscriber(transcriber)
            stream.start()
            state["stream"] = stream
            timer = threading.Thread(target=snapshots, args=(stream, vocab_prompt(dictionary)), daemon=True)
            state["timer"] = timer
            timer.start()
        print("recording...")

    def process(audio, stream, app) -> None:
        try:
            path = save_audio(audio)
            raw, stt_ms = None, 0.0
            if stream is not None:
                start = time.perf_counter()
                try:
                    run = stream.finish(audio, vocab=vocab_prompt(dictionary))
                except TimeoutError:
                    logger.warning("Streaming is still processing; audio retained. Waiting for its worker before accepting another recording")
                    # Do not start another MLX invocation while the first is active.
                    run = stream.close(timeout=None)
                if not run.final_error:
                    raw = run.text
                stt_ms = (time.perf_counter() - start) * 1000
            run_dictation_cycle(audio, transcriber, config, dictionary, app_bundle_id=app,
                                raw_text_override=raw, stt_ms_override=stt_ms, audio_path=path)
        except Exception as exc:
            logger.error("Dictation failed (%s); retained audio can be retried", type(exc).__name__)
        finally:
            state["working"] = False

    def stop_recording() -> None:
        if not state["recording"]:
            return
        stop_timer.set()
        if state["timer"] is not None:
            state["timer"].join()
            state["timer"] = None
        audio = recorder.stop()
        state["recording"] = False
        stream, state["stream"] = state["stream"], None
        if len(audio) == 0:
            if stream is not None:
                stream.close()
            return
        state["working"] = True
        threading.Thread(target=process, args=(audio, stream, state["app"]), daemon=True).start()

    def on_press(key) -> None:
        if key == hold_key:
            if config.get("toggle_mode") and state["recording"]:
                stop_recording()
            else:
                start_recording()

    def on_release(key) -> None:
        if key == hold_key and not config.get("toggle_mode"):
            stop_recording()

    print(f"undertone listening. hold key: {config.get('hold_key')}")
    print("required macOS permissions: Microphone, Accessibility, Input Monitoring")
    with keyboard.Listener(on_press=on_press, on_release=on_release) as listener:
        listener.join()
