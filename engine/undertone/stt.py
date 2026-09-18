from __future__ import annotations

import re
from pathlib import Path
from typing import Any

import numpy as np

DEFAULT_STT_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_MIN_SPEECH_SECONDS = 0.4
DEFAULT_MIN_SPEECH_RMS = 0.004
NO_SPEECH_PROB_THRESHOLD = 0.6
COMPRESSION_RATIO_THRESHOLD = 2.4
VOCAB_ECHO_RATIO = 0.5

_PUNCT_RE = re.compile(r"[^\w\s]")


def _tokenize(text: str) -> list[str]:
    stripped = _PUNCT_RE.sub("", text.lower())
    return stripped.split()


def _looks_like_vocab_echo(text: str, vocab: str) -> bool:
    """Whisper hallucinates the initial_prompt back on silence/noise."""
    if not vocab.strip():
        return False
    output_tokens = _tokenize(text)
    if not output_tokens:
        return False
    vocab_terms = {token for term in vocab.split(",") for token in _tokenize(term)}
    if not vocab_terms:
        return False
    matches = sum(1 for token in output_tokens if token in vocab_terms)
    if matches / len(output_tokens) >= VOCAB_ECHO_RATIO:
        return True
    vocab_lead = [_tokenize(term) for term in vocab.split(",")[:3]]
    vocab_lead_tokens = [token for group in vocab_lead for token in group]
    if vocab_lead_tokens and output_tokens[: len(vocab_lead_tokens)] == vocab_lead_tokens:
        return True
    return False


class Transcriber:
    """Wraps mlx_whisper, loaded once and kept warm."""

    def __init__(
        self,
        model: str | None = None,
        *,
        local_files_only: bool = True,
    ) -> None:
        self.model = _resolve_model(
            model or DEFAULT_STT_MODEL,
            local_files_only=local_files_only,
        )
        self._warm = False

    def warm_up(self) -> None:
        if self._warm:
            return
        import mlx_whisper

        silence = np.zeros(16000, dtype=np.float32)
        mlx_whisper.transcribe(
            silence,
            path_or_hf_repo=self.model,
            language="en",
            temperature=0.0,
        )
        self._warm = True

    def transcribe(self, audio: np.ndarray, vocab: str = "") -> str:
        return self.transcribe_detailed(audio, vocab=vocab)["text"]

    def transcribe_detailed(
        self,
        audio: np.ndarray,
        vocab: str = "",
        *,
        min_speech_seconds: float = DEFAULT_MIN_SPEECH_SECONDS,
        min_speech_rms: float = DEFAULT_MIN_SPEECH_RMS,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
    ) -> dict[str, Any]:
        audio = np.asarray(audio, dtype=np.float32)
        if audio.size == 0:
            return {"text": "", "no_speech": True, "reason": "empty"}

        duration = len(audio) / sample_rate
        rms = float(np.sqrt(np.mean(np.square(audio))))
        if duration < min_speech_seconds or rms < min_speech_rms:
            # Gate before whisper: silence and faint room noise hallucinate
            # the vocabulary prompt back rather than returning empty text.
            return {"text": "", "no_speech": True, "reason": "too_quiet"}

        import mlx_whisper

        if not self._warm:
            self.warm_up()

        result = mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model,
            language="en",
            temperature=0.0,
            initial_prompt=vocab or None,
        )

        segments = result.get("segments") or []
        kept = [
            segment.get("text", "")
            for segment in segments
            if segment.get("no_speech_prob", 0.0) <= NO_SPEECH_PROB_THRESHOLD
            and segment.get("compression_ratio", 0.0) <= COMPRESSION_RATIO_THRESHOLD
        ]
        if segments:
            text = " ".join(part.strip() for part in kept if part.strip()).strip()
        else:
            text = result.get("text", "").strip()

        if segments and not text:
            return {"text": "", "no_speech": True, "reason": "no_speech_segments"}

        if _looks_like_vocab_echo(text, vocab):
            return {"text": "", "no_speech": True, "reason": "vocab_echo"}

        return {"text": text, "no_speech": False, "reason": ""}


def _resolve_model(model: str, *, local_files_only: bool) -> str:
    """Resolve a cached HF model without allowing a network fetch when asked."""
    if not local_files_only or Path(model).exists():
        return model
    try:
        from huggingface_hub import snapshot_download

        return snapshot_download(repo_id=model, local_files_only=True)
    except Exception as exc:  # do not expose cache details in the public error
        raise RuntimeError(f"STT model is not cached locally: {model}") from exc
