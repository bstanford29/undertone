from __future__ import annotations

import numpy as np
import sounddevice as sd
from threading import Lock

SAMPLE_RATE = 16000


class Recorder:
    """Records mono float32 audio at 16 kHz into an in-memory buffer."""

    def __init__(self, sample_rate: int = SAMPLE_RATE) -> None:
        self.sample_rate = sample_rate
        self._chunks: list[np.ndarray] = []
        self._stream: sd.InputStream | None = None
        self._lock = Lock()

    def _callback(self, indata, frames, time_info, status) -> None:
        chunk = indata[:, 0].copy()
        with self._lock:
            self._chunks.append(chunk)

    def start(self) -> None:
        with self._lock:
            if self._stream is not None:
                raise RuntimeError("recorder is already running")
            self._chunks = []
        stream = sd.InputStream(
            samplerate=self.sample_rate,
            channels=1,
            dtype="float32",
            callback=self._callback,
        )
        try:
            stream.start()
        except Exception:
            stream.close()
            raise
        with self._lock:
            self._stream = stream

    def stop(self) -> np.ndarray:
        with self._lock:
            stream = self._stream
        if stream is not None:
            stream.stop()
            stream.close()
            with self._lock:
                self._stream = None
        return self.snapshot()

    def snapshot(self) -> np.ndarray:
        """Return all audio received so far without changing the recording."""
        with self._lock:
            chunks = tuple(self._chunks)
        if not chunks:
            return np.zeros(0, dtype=np.float32)
        return np.concatenate(chunks).astype(np.float32, copy=False)


def load_wav(path: str) -> np.ndarray:
    import soundfile as sf

    audio, sample_rate = sf.read(path, dtype="float32")
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sample_rate != SAMPLE_RATE:
        audio = _resample(audio, sample_rate, SAMPLE_RATE)
    return audio.astype(np.float32)


def _resample(audio: np.ndarray, from_rate: int, to_rate: int) -> np.ndarray:
    duration = len(audio) / from_rate
    target_len = int(round(duration * to_rate))
    x_old = np.linspace(0, duration, num=len(audio), endpoint=False)
    x_new = np.linspace(0, duration, num=target_len, endpoint=False)
    return np.interp(x_new, x_old, audio)
