from __future__ import annotations

import importlib.util
import re
from pathlib import Path
from typing import Any

import numpy as np

DEFAULT_STT_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_PARAKEET_MODEL = "mlx-community/parakeet-tdt-0.6b-v3"
STT_BACKENDS = ("whisper", "parakeet")
DEFAULT_SAMPLE_RATE = 16000
DEFAULT_MIN_SPEECH_SECONDS = 0.4
DEFAULT_MIN_SPEECH_RMS = 0.004
NO_SPEECH_PROB_THRESHOLD = 0.6
COMPRESSION_RATIO_THRESHOLD = 2.4
VOCAB_ECHO_RATIO = 0.5
# A segment that fails the compression gate is re-run at these temperatures
# before it is split in halves. Whisper's own fallback ladder does the same,
# but on the whole window; this keeps the retry local to the failing slice.
RETRY_TEMPERATURES = (0.2, 0.4)
# Below this length a slice is not split further; whisper gets nothing useful
# from sub-second halves and the retry budget is better spent elsewhere.
MIN_SPLIT_SECONDS = 1.0
MAX_SPLIT_DEPTH = 2
# Whisper keeps the tail of a long initial_prompt, so the context passed with
# the vocabulary is capped here and placed before the vocabulary terms.
CONTEXT_TAIL_CHARS = 300

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


def _looks_repetitive(text: str) -> bool:
    """Catch the classic whisper loop: a few words repeated over and over."""
    tokens = _tokenize(text)
    if len(tokens) < 8:
        return False
    unique_ratio = len(set(tokens)) / len(tokens)
    if unique_ratio < 0.3:
        return True
    for width in (1, 2, 3):
        grams = [tuple(tokens[i : i + width]) for i in range(len(tokens) - width + 1)]
        if not grams:
            continue
        most_common = max(grams.count(gram) for gram in set(grams))
        if most_common * width >= 0.6 * len(tokens) and most_common >= 4:
            return True
    return False


def _segment_ok(segment: dict[str, Any]) -> bool:
    return (
        segment.get("no_speech_prob", 0.0) <= NO_SPEECH_PROB_THRESHOLD
        and segment.get("compression_ratio", 0.0) <= COMPRESSION_RATIO_THRESHOLD
    )


def _join(parts: list[str]) -> str:
    return " ".join(part.strip() for part in parts if part and part.strip()).strip()


def _empty_stats() -> dict[str, int]:
    return {"total": 0, "retried": 0, "recovered": 0, "dropped": 0}


def _speech_gate(
    audio: np.ndarray,
    *,
    min_speech_seconds: float,
    min_speech_rms: float,
    sample_rate: int,
) -> dict[str, Any] | None:
    """Return a no-speech result for empty or too-quiet audio, else None.

    Silence and faint room noise make both backends hallucinate, so the gate
    runs before any model call.
    """
    if audio.size == 0:
        return {"text": "", "no_speech": True, "reason": "empty", "segments": _empty_stats()}
    duration = len(audio) / sample_rate
    rms = float(np.sqrt(np.mean(np.square(audio))))
    if duration < min_speech_seconds or rms < min_speech_rms:
        return {"text": "", "no_speech": True, "reason": "too_quiet", "segments": _empty_stats()}
    return None


# Phrases Parakeet produces for vocabulary terms it cannot be prompted with.
# Exact, case-insensitive, whole-word matches only: fuzzy matching here turned
# ordinary words ("all may", "we can", "code") into terms.
SOUND_ALIKES: dict[str, tuple[str, ...]] = {
    "Ollama": ("all IMA", "all-IMA", "Alima", "Olama"),
}


def restore_sound_alikes(text: str, vocab: str = "") -> str:
    """Rewrite known mishearings of terms that are in this dictation's vocab."""
    terms = {term.strip().lower() for term in vocab.split(",") if term.strip()}
    for term, phrases in SOUND_ALIKES.items():
        if term.lower() not in terms:
            continue
        for phrase in phrases:
            pattern = re.compile(rf"(?<!\w){re.escape(phrase)}(?!\w)", re.IGNORECASE)
            text = pattern.sub(term, text)
    return text


def make_transcriber(config: dict[str, Any] | None = None, *, local_files_only: bool = True):
    """Build the configured STT backend: parakeet by default, whisper when asked
    or when parakeet-mlx is not installed."""
    config = config or {}
    backend = config.get("stt_backend", "parakeet") or "parakeet"
    if backend == "whisper":
        return Transcriber(model=config.get("stt_model"), local_files_only=local_files_only)
    if backend == "parakeet":
        if importlib.util.find_spec("parakeet_mlx") is None:
            # Not Apple Silicon or the extra is missing: keep dictating on whisper.
            return Transcriber(model=config.get("stt_model"), local_files_only=local_files_only)
        return ParakeetTranscriber(model=config.get("parakeet_model"), local_files_only=local_files_only)
    raise ValueError(f"Unknown stt_backend: {backend}")


def build_initial_prompt(vocab: str = "", context: str = "") -> str | None:
    """Compose whisper's initial_prompt from prior text and the vocabulary.

    Whisper keeps the last tokens of an over-long prompt, so the vocabulary
    goes last and the context tail is capped so both survive.
    """
    tail = context.strip()
    if len(tail) > CONTEXT_TAIL_CHARS:
        tail = tail[-CONTEXT_TAIL_CHARS:]
        cut = tail.find(" ")
        if 0 <= cut < len(tail) - 1:
            tail = tail[cut + 1 :]
    prompt = _join([tail, vocab])
    return prompt or None


class Transcriber:
    """Wraps mlx_whisper, loaded once and kept warm."""

    backend = "whisper"

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

    def transcribe(self, audio: np.ndarray, vocab: str = "", context: str = "") -> str:
        return self.transcribe_detailed(audio, vocab=vocab, context=context)["text"]

    def transcribe_detailed(
        self,
        audio: np.ndarray,
        vocab: str = "",
        *,
        context: str = "",
        min_speech_seconds: float = DEFAULT_MIN_SPEECH_SECONDS,
        min_speech_rms: float = DEFAULT_MIN_SPEECH_RMS,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
    ) -> dict[str, Any]:
        audio = np.asarray(audio, dtype=np.float32)
        stats = _empty_stats()
        gated = _speech_gate(
            audio,
            min_speech_seconds=min_speech_seconds,
            min_speech_rms=min_speech_rms,
            sample_rate=sample_rate,
        )
        if gated is not None:
            return gated

        if not self._warm:
            self.warm_up()

        prompt = build_initial_prompt(vocab, context)
        result = self._call_whisper(audio, temperature=0.0, prompt=prompt)

        segments = result.get("segments") or []
        stats["total"] = len(segments)
        kept: list[str] = []
        for segment in segments:
            if segment.get("no_speech_prob", 0.0) > NO_SPEECH_PROB_THRESHOLD:
                # Silence gate stays as is: nothing was said, nothing to recover.
                stats["dropped"] += 1
                continue
            if segment.get("compression_ratio", 0.0) <= COMPRESSION_RATIO_THRESHOLD:
                kept.append(segment.get("text", ""))
                continue
            # Compression failure: a repetition loop ate this slice. Re-run the
            # slice alone instead of throwing the words away.
            stats["retried"] += 1
            recovered = self._recover_segment(audio, segment, prompt, vocab, sample_rate)
            if not recovered:
                stats["dropped"] += 1
            else:
                stats["recovered"] += 1
                kept.append(recovered)
        if segments:
            text = _join(kept)
        else:
            text = result.get("text", "").strip()

        if segments and not text:
            return {"text": "", "no_speech": True, "reason": "no_speech_segments", "segments": stats}

        if _looks_like_vocab_echo(text, vocab):
            return {"text": "", "no_speech": True, "reason": "vocab_echo", "segments": stats}

        return {"text": text, "no_speech": False, "reason": "", "segments": stats}

    def _call_whisper(
        self, audio: np.ndarray, *, temperature: float, prompt: str | None
    ) -> dict[str, Any]:
        import mlx_whisper

        return mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model,
            language="en",
            temperature=temperature,
            initial_prompt=prompt,
        )

    def _recover_segment(
        self,
        audio: np.ndarray,
        segment: dict[str, Any],
        prompt: str | None,
        vocab: str,
        sample_rate: int,
    ) -> str | None:
        start = max(0, int(float(segment.get("start", 0.0)) * sample_rate))
        end = min(len(audio), int(float(segment.get("end", 0.0)) * sample_rate))
        if end <= start:
            return None
        return self._recover_slice(audio[start:end], prompt, vocab, sample_rate, depth=0)

    def _recover_slice(
        self,
        clip: np.ndarray,
        prompt: str | None,
        vocab: str,
        sample_rate: int,
        *,
        depth: int,
    ) -> str | None:
        """Retry a failing slice hotter, then in halves. None means still a loop."""
        for temperature in RETRY_TEMPERATURES:
            try:
                attempt = self._call_whisper(clip, temperature=temperature, prompt=prompt)
            except Exception:
                continue
            text = self._accept_attempt(attempt, vocab)
            if text is not None:
                return text

        seconds = len(clip) / sample_rate
        if depth >= MAX_SPLIT_DEPTH or seconds < 2 * MIN_SPLIT_SECONDS:
            return None
        middle = len(clip) // 2
        halves = [
            self._recover_slice(clip[:middle], prompt, vocab, sample_rate, depth=depth + 1),
            self._recover_slice(clip[middle:], prompt, vocab, sample_rate, depth=depth + 1),
        ]
        if all(half is None for half in halves):
            return None
        return _join([half or "" for half in halves])

    @staticmethod
    def _accept_attempt(attempt: dict[str, Any], vocab: str) -> str | None:
        """Return the attempt's text when nothing in it still looks like a loop."""
        segments = attempt.get("segments") or []
        if segments:
            if any(
                segment.get("compression_ratio", 0.0) > COMPRESSION_RATIO_THRESHOLD
                for segment in segments
            ):
                return None
            text = _join([segment.get("text", "") for segment in segments if _segment_ok(segment)])
        else:
            text = attempt.get("text", "").strip()
        if _looks_repetitive(text) or _looks_like_vocab_echo(text, vocab):
            return None
        return text


class ParakeetTranscriber:
    """NVIDIA Parakeet TDT via parakeet-mlx, loaded once and kept warm.

    Same interface and silence gates as ``Transcriber``. Parakeet has no
    initial_prompt, so ``context`` is ignored and ``vocab`` only selects which
    known sound-alikes to restore; other proper nouns rely on cleanup and
    dictionary replacements.
    The optional ``parakeet`` extra installs the package.
    """

    backend = "parakeet"

    def __init__(
        self,
        model: str | None = None,
        *,
        local_files_only: bool = True,
    ) -> None:
        self.model = _resolve_model(
            model or DEFAULT_PARAKEET_MODEL,
            local_files_only=local_files_only,
        )
        self._model = None
        self._warm = False

    def warm_up(self) -> None:
        if self._warm:
            return
        self._load()
        self._run(np.zeros(16000, dtype=np.float32))
        self._warm = True

    def transcribe(self, audio: np.ndarray, vocab: str = "", context: str = "") -> str:
        return self.transcribe_detailed(audio, vocab=vocab, context=context)["text"]

    def transcribe_detailed(
        self,
        audio: np.ndarray,
        vocab: str = "",
        *,
        context: str = "",
        min_speech_seconds: float = DEFAULT_MIN_SPEECH_SECONDS,
        min_speech_rms: float = DEFAULT_MIN_SPEECH_RMS,
        sample_rate: int = DEFAULT_SAMPLE_RATE,
    ) -> dict[str, Any]:
        audio = np.asarray(audio, dtype=np.float32)
        gated = _speech_gate(
            audio,
            min_speech_seconds=min_speech_seconds,
            min_speech_rms=min_speech_rms,
            sample_rate=sample_rate,
        )
        if gated is not None:
            return gated
        if not self._warm:
            self.warm_up()
        text = self._run(audio)
        stats = _empty_stats()
        stats["total"] = 1 if text else 0
        if not text:
            return {"text": "", "no_speech": True, "reason": "no_speech_segments", "segments": stats}
        if _looks_repetitive(text):
            stats["dropped"] = 1
            return {"text": "", "no_speech": True, "reason": "repetition", "segments": stats}
        text = restore_sound_alikes(text, vocab)
        return {"text": text, "no_speech": False, "reason": "", "segments": stats}

    def _load(self) -> None:
        if self._model is not None:
            return
        try:
            from parakeet_mlx import from_pretrained
        except ImportError as exc:
            raise RuntimeError(
                "stt_backend is parakeet but parakeet-mlx is not installed; "
                "run: uv pip install -e '.[parakeet]'"
            ) from exc
        self._model = from_pretrained(self.model)

    def _run(self, audio: np.ndarray) -> str:
        """Log-mel in process (no ffmpeg) then greedy TDT decode."""
        import mlx.core as mx
        from parakeet_mlx.audio import get_logmel

        self._load()
        mel = get_logmel(mx.array(audio), self._model.preprocessor_config)
        results = self._model.generate(mel)
        return (results[0].text if results else "").strip()


def _resolve_model(model: str, *, local_files_only: bool) -> str:
    """Resolve a cached HF model without allowing a network fetch when asked."""
    if not local_files_only or Path(model).exists():
        return model
    try:
        from huggingface_hub import snapshot_download

        return snapshot_download(repo_id=model, local_files_only=True)
    except Exception as exc:  # do not expose cache details in the public error
        raise RuntimeError(f"STT model is not cached locally: {model}") from exc
