from __future__ import annotations

import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

from undertone.stt import Transcriber

VOCAB = "Undertone, Obsidian, Ollama, Qwen, Whisper"
SAMPLE_RATE = 16000


def _transcriber() -> Transcriber:
    # A real, existing local path skips the network model resolution.
    return Transcriber(str(Path(__file__).parent), local_files_only=True)


class SpeechGateTests(unittest.TestCase):
    def test_pure_silence_returns_empty_without_calling_whisper(self):
        audio = np.zeros(SAMPLE_RATE * 3, dtype=np.float32)
        transcriber = _transcriber()
        with patch.dict(sys.modules, {"mlx_whisper": None}):
            # mlx_whisper is deliberately unimportable; any attempt to import
            # it inside transcribe_detailed would raise ImportError.
            result = transcriber.transcribe_detailed(audio, vocab=VOCAB)
        self.assertEqual(result["text"], "")
        self.assertTrue(result["no_speech"])
        self.assertEqual(result["reason"], "too_quiet")

    def test_faint_room_noise_returns_empty_without_calling_whisper(self):
        rng = np.random.default_rng(0)
        audio = (rng.standard_normal(SAMPLE_RATE * 3) * 0.0005).astype(np.float32)
        transcriber = _transcriber()
        with patch.dict(sys.modules, {"mlx_whisper": None}):
            result = transcriber.transcribe_detailed(audio, vocab=VOCAB)
        self.assertEqual(result["text"], "")
        self.assertTrue(result["no_speech"])
        self.assertEqual(result["reason"], "too_quiet")

    def test_blip_shorter_than_minimum_duration_returns_empty_without_calling_whisper(self):
        rng = np.random.default_rng(1)
        audio = (rng.standard_normal(int(SAMPLE_RATE * 0.3)) * 0.2).astype(np.float32)
        transcriber = _transcriber()
        with patch.dict(sys.modules, {"mlx_whisper": None}):
            result = transcriber.transcribe_detailed(audio, vocab=VOCAB)
        self.assertEqual(result["text"], "")
        self.assertTrue(result["no_speech"])
        self.assertEqual(result["reason"], "too_quiet")

    def test_loud_enough_and_long_enough_audio_passes_the_gate(self):
        rng = np.random.default_rng(2)
        audio = (rng.standard_normal(SAMPLE_RATE * 3) * 0.2).astype(np.float32)
        transcriber = _transcriber()
        transcriber._warm = True
        fake_module = types.SimpleNamespace(
            transcribe=lambda *a, **k: {
                "text": "hello there",
                "segments": [
                    {"text": "hello there", "no_speech_prob": 0.1, "compression_ratio": 1.0}
                ],
            }
        )
        with patch.dict(sys.modules, {"mlx_whisper": fake_module}):
            result = transcriber.transcribe_detailed(audio, vocab=VOCAB)
        self.assertEqual(result["text"], "hello there")
        self.assertFalse(result["no_speech"])


class SegmentFilterTests(unittest.TestCase):
    def test_high_no_speech_and_compression_segments_are_dropped(self):
        rng = np.random.default_rng(3)
        audio = (rng.standard_normal(SAMPLE_RATE * 3) * 0.2).astype(np.float32)
        transcriber = _transcriber()
        transcriber._warm = True
        fake_module = types.SimpleNamespace(
            transcribe=lambda *a, **k: {
                "text": "kept text garbage repeat repeat repeat",
                "segments": [
                    {"text": "kept text", "no_speech_prob": 0.1, "compression_ratio": 1.0},
                    {"text": "garbage repeat repeat repeat", "no_speech_prob": 0.9, "compression_ratio": 3.0},
                ],
            }
        )
        with patch.dict(sys.modules, {"mlx_whisper": fake_module}):
            result = transcriber.transcribe_detailed(audio, vocab="")
        self.assertEqual(result["text"], "kept text")
        self.assertFalse(result["no_speech"])

    def test_all_segments_dropped_returns_no_speech(self):
        rng = np.random.default_rng(4)
        audio = (rng.standard_normal(SAMPLE_RATE * 3) * 0.2).astype(np.float32)
        transcriber = _transcriber()
        transcriber._warm = True
        fake_module = types.SimpleNamespace(
            transcribe=lambda *a, **k: {
                "text": "garbage",
                "segments": [
                    {"text": "garbage", "no_speech_prob": 0.95, "compression_ratio": 1.0},
                ],
            }
        )
        with patch.dict(sys.modules, {"mlx_whisper": fake_module}):
            result = transcriber.transcribe_detailed(audio, vocab="")
        self.assertEqual(result["text"], "")
        self.assertTrue(result["no_speech"])
        self.assertEqual(result["reason"], "no_speech_segments")


class VocabEchoTests(unittest.TestCase):
    def test_vocabulary_echo_is_treated_as_no_speech(self):
        rng = np.random.default_rng(5)
        audio = (rng.standard_normal(SAMPLE_RATE * 3) * 0.2).astype(np.float32)
        transcriber = _transcriber()
        transcriber._warm = True
        fake_module = types.SimpleNamespace(
            transcribe=lambda *a, **k: {
                "text": VOCAB,
                "segments": [
                    {"text": VOCAB, "no_speech_prob": 0.1, "compression_ratio": 1.0}
                ],
            }
        )
        with patch.dict(sys.modules, {"mlx_whisper": fake_module}):
            result = transcriber.transcribe_detailed(audio, vocab=VOCAB)
        self.assertEqual(result["text"], "")
        self.assertTrue(result["no_speech"])
        self.assertEqual(result["reason"], "vocab_echo")

    def test_transcribe_string_api_returns_empty_on_echo(self):
        rng = np.random.default_rng(6)
        audio = (rng.standard_normal(SAMPLE_RATE * 3) * 0.2).astype(np.float32)
        transcriber = _transcriber()
        transcriber._warm = True
        fake_module = types.SimpleNamespace(
            transcribe=lambda *a, **k: {
                "text": VOCAB,
                "segments": [
                    {"text": VOCAB, "no_speech_prob": 0.1, "compression_ratio": 1.0}
                ],
            }
        )
        with patch.dict(sys.modules, {"mlx_whisper": fake_module}):
            self.assertEqual(transcriber.transcribe(audio, vocab=VOCAB), "")

    def test_genuine_speech_mentioning_one_vocab_term_is_not_flagged(self):
        rng = np.random.default_rng(7)
        audio = (rng.standard_normal(SAMPLE_RATE * 3) * 0.2).astype(np.float32)
        transcriber = _transcriber()
        transcriber._warm = True
        text = "can you open Obsidian and check the notes from yesterday please"
        fake_module = types.SimpleNamespace(
            transcribe=lambda *a, **k: {
                "text": text,
                "segments": [{"text": text, "no_speech_prob": 0.1, "compression_ratio": 1.0}],
            }
        )
        with patch.dict(sys.modules, {"mlx_whisper": fake_module}):
            result = transcriber.transcribe_detailed(audio, vocab=VOCAB)
        self.assertEqual(result["text"], text)
        self.assertFalse(result["no_speech"])


if __name__ == "__main__":
    unittest.main()
