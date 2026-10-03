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


class ScriptedWhisper:
    """Fake mlx_whisper whose answer depends on the slice length and temperature."""

    def __init__(self, script):
        # script(audio_seconds, temperature) -> result dict
        self.script = script
        self.calls: list[tuple[float, float, str | None]] = []

    def transcribe(self, audio, *, temperature=0.0, initial_prompt=None, **_kwargs):
        seconds = round(len(audio) / SAMPLE_RATE, 3)
        self.calls.append((seconds, temperature, initial_prompt))
        return self.script(seconds, temperature)


def _segment(text, start, end, *, ratio=1.0, no_speech=0.1):
    return {"text": text, "start": start, "end": end, "compression_ratio": ratio, "no_speech_prob": no_speech}


def _loud(seconds, seed=10):
    rng = np.random.default_rng(seed)
    return (rng.standard_normal(int(SAMPLE_RATE * seconds)) * 0.2).astype(np.float32)


class SegmentRetryTests(unittest.TestCase):
    def test_compression_failure_is_recovered_at_higher_temperature(self):
        def script(seconds, temperature):
            if seconds == 6.0:
                return {"text": "", "segments": [
                    _segment("first part", 0.0, 3.0),
                    _segment("loop loop loop loop loop loop loop loop loop", 3.0, 6.0, ratio=3.1),
                ]}
            if seconds == 3.0 and temperature == 0.2:
                return {"text": "second part", "segments": [_segment("second part", 0.0, 3.0)]}
            raise AssertionError(f"unexpected call {seconds}s at {temperature}")

        fake = ScriptedWhisper(script)
        transcriber = _transcriber()
        transcriber._warm = True
        with patch.dict(sys.modules, {"mlx_whisper": fake}):
            result = transcriber.transcribe_detailed(_loud(6.0), vocab=VOCAB)
        self.assertEqual(result["text"], "first part second part")
        self.assertFalse(result["no_speech"])
        self.assertEqual(result["segments"], {"total": 2, "retried": 1, "recovered": 1, "dropped": 0})
        self.assertEqual([(s, t) for s, t, _ in fake.calls], [(6.0, 0.0), (3.0, 0.2)])
        # The retry keeps the same prompt so proper nouns still get their hint.
        self.assertEqual(fake.calls[1][2], VOCAB)

    def test_second_temperature_then_halves_are_tried_before_dropping(self):
        def script(seconds, temperature):
            if seconds == 6.0:
                return {"text": "", "segments": [
                    _segment("intro", 0.0, 2.0),
                    _segment("the the the the the the the the the the", 2.0, 6.0, ratio=4.0),
                ]}
            if seconds == 4.0:
                # Both hotter retries still loop on the whole slice.
                return {"text": "", "segments": [_segment("the the the the the the the the", 0.0, 4.0, ratio=3.5)]}
            if seconds == 2.0:
                return {"text": "", "segments": [_segment("left half words" if temperature == 0.2 else "x", 0.0, 2.0)]}
            raise AssertionError(f"unexpected call {seconds}s at {temperature}")

        fake = ScriptedWhisper(script)
        transcriber = _transcriber()
        transcriber._warm = True
        with patch.dict(sys.modules, {"mlx_whisper": fake}):
            result = transcriber.transcribe_detailed(_loud(6.0, seed=11), vocab="")
        self.assertEqual(result["text"], "intro left half words left half words")
        self.assertEqual(result["segments"], {"total": 2, "retried": 1, "recovered": 1, "dropped": 0})
        temps = [(s, t) for s, t, _ in fake.calls]
        self.assertEqual(temps, [(6.0, 0.0), (4.0, 0.2), (4.0, 0.4), (2.0, 0.2), (2.0, 0.2)])

    def test_segment_is_dropped_only_when_every_retry_still_loops(self):
        def script(seconds, temperature):
            if seconds == 5.0:
                return {"text": "", "segments": [
                    _segment("real words here", 0.0, 2.0),
                    _segment("ha ha ha ha ha ha ha ha ha ha", 2.0, 5.0, ratio=5.0),
                ]}
            # Every retry at every size keeps looping.
            return {"text": "", "segments": [_segment("ha ha ha ha ha ha ha ha ha ha", 0.0, seconds, ratio=5.0)]}

        fake = ScriptedWhisper(script)
        transcriber = _transcriber()
        transcriber._warm = True
        with patch.dict(sys.modules, {"mlx_whisper": fake}):
            result = transcriber.transcribe_detailed(_loud(5.0, seed=12), vocab="")
        self.assertEqual(result["text"], "real words here")
        self.assertEqual(result["segments"]["retried"], 1)
        self.assertEqual(result["segments"]["recovered"], 0)
        self.assertEqual(result["segments"]["dropped"], 1)
        # 3 s slice: two temperatures, then halves of 1.5 s (two temps each),
        # and the halves are below the 2 s split floor so recursion stops.
        self.assertEqual(len(fake.calls), 1 + 2 + 2 * 2)

    def test_retry_that_passes_compression_but_repeats_text_is_rejected(self):
        def script(seconds, temperature):
            if seconds == 4.0:
                return {"text": "", "segments": [_segment("bad bad bad bad bad bad bad bad", 0.0, 4.0, ratio=3.0)]}
            # Whisper reports a fine ratio but the words are still a loop.
            return {"text": "go go go go go go go go go go", "segments": []}

        fake = ScriptedWhisper(script)
        transcriber = _transcriber()
        transcriber._warm = True
        with patch.dict(sys.modules, {"mlx_whisper": fake}):
            result = transcriber.transcribe_detailed(_loud(4.0, seed=13), vocab="")
        self.assertTrue(result["no_speech"])
        self.assertEqual(result["reason"], "no_speech_segments")
        self.assertEqual(result["segments"]["dropped"], 1)

    def test_no_speech_segments_are_not_retried(self):
        fake = ScriptedWhisper(lambda seconds, temperature: {"text": "", "segments": [
            _segment("kept", 0.0, 1.5),
            _segment("noise", 1.5, 3.0, no_speech=0.95),
        ]})
        transcriber = _transcriber()
        transcriber._warm = True
        with patch.dict(sys.modules, {"mlx_whisper": fake}):
            result = transcriber.transcribe_detailed(_loud(3.0, seed=14), vocab="")
        self.assertEqual(result["text"], "kept")
        self.assertEqual(result["segments"], {"total": 2, "retried": 0, "recovered": 0, "dropped": 1})
        self.assertEqual(len(fake.calls), 1)


class InitialPromptTests(unittest.TestCase):
    def test_context_goes_before_vocab_and_is_not_part_of_echo_check(self):
        from undertone.stt import build_initial_prompt

        self.assertEqual(build_initial_prompt("Ollama, Qwen", "we said this"), "we said this Ollama, Qwen")
        self.assertIsNone(build_initial_prompt("", ""))
        long_context = " ".join(f"w{i}" for i in range(200))
        prompt = build_initial_prompt("Ollama", long_context)
        self.assertTrue(prompt.endswith(" Ollama"))
        self.assertLess(len(prompt), 320)

        # Speech that repeats common words from the context must not be
        # mistaken for the vocabulary echo.
        fake = ScriptedWhisper(lambda seconds, temperature: {"text": "the report the report", "segments": [
            _segment("the report the report", 0.0, 3.0),
        ]})
        transcriber = _transcriber()
        transcriber._warm = True
        with patch.dict(sys.modules, {"mlx_whisper": fake}):
            result = transcriber.transcribe_detailed(_loud(3.0, seed=15), vocab="Qwen", context="send the report")
        self.assertEqual(result["text"], "the report the report")
        self.assertEqual(fake.calls[0][2], "send the report Qwen")


class FakeParakeetModules:
    """sys.modules entries standing in for mlx and parakeet-mlx."""

    def __init__(self, text="hello from parakeet"):
        self.text = text
        self.loaded: list[str] = []
        self.generated: list[int] = []
        modules = self

        class Model:
            preprocessor_config = object()

            def generate(self, mel):
                modules.generated.append(len(mel))
                return [types.SimpleNamespace(text=modules.text)]

        def from_pretrained(path):
            modules.loaded.append(path)
            return Model()

        mx = types.SimpleNamespace(array=lambda audio: np.asarray(audio))
        self.entries = {
            "mlx": types.SimpleNamespace(core=mx),
            "mlx.core": mx,
            "parakeet_mlx": types.SimpleNamespace(from_pretrained=from_pretrained),
            "parakeet_mlx.audio": types.SimpleNamespace(get_logmel=lambda audio, config: audio),
        }


class BackendSwitchTests(unittest.TestCase):
    def test_default_backend_is_parakeet_when_installed(self):
        from undertone.stt import ParakeetTranscriber, make_transcriber

        with patch("undertone.stt._resolve_model", return_value="/cached/parakeet"), \
                patch("undertone.stt.importlib.util.find_spec", return_value=object()):
            transcriber = make_transcriber({})
        self.assertIsInstance(transcriber, ParakeetTranscriber)
        self.assertEqual(transcriber.backend, "parakeet")

    def test_default_falls_back_to_whisper_without_parakeet(self):
        from undertone.stt import make_transcriber

        with patch("undertone.stt._resolve_model", return_value="/cached/whisper"), \
                patch("undertone.stt.importlib.util.find_spec", return_value=None):
            transcriber = make_transcriber({"stt_model": "org/whisper"})
        self.assertIsInstance(transcriber, Transcriber)
        self.assertEqual(transcriber.backend, "whisper")

    def test_whisper_backend_when_asked(self):
        from undertone.stt import make_transcriber

        with patch("undertone.stt._resolve_model", return_value="/cached/whisper"):
            transcriber = make_transcriber({"stt_backend": "whisper", "stt_model": "org/whisper"})
        self.assertIsInstance(transcriber, Transcriber)

    def test_parakeet_backend_resolves_cached_model_and_transcribes(self):
        from undertone.stt import ParakeetTranscriber, make_transcriber

        fake = FakeParakeetModules()
        with patch("undertone.stt._resolve_model", return_value="/cached/parakeet") as resolve, \
                patch("undertone.stt.importlib.util.find_spec", return_value=object()):
            transcriber = make_transcriber({"stt_backend": "parakeet", "parakeet_model": "org/parakeet"})
        self.assertIsInstance(transcriber, ParakeetTranscriber)
        resolve.assert_called_once_with("org/parakeet", local_files_only=True)
        with patch.dict(sys.modules, fake.entries):
            result = transcriber.transcribe_detailed(_loud(3.0, seed=20), vocab=VOCAB, context="earlier words")
        self.assertEqual(result["text"], "hello from parakeet")
        self.assertFalse(result["no_speech"])
        self.assertEqual(result["segments"]["dropped"], 0)
        # Loaded once (warm-up call plus the real call), from the cached path.
        self.assertEqual(fake.loaded, ["/cached/parakeet"])
        self.assertEqual(len(fake.generated), 2)
        self.assertEqual(fake.generated[-1], SAMPLE_RATE * 3)

    def test_parakeet_keeps_the_silence_gate_without_importing_the_package(self):
        from undertone.stt import ParakeetTranscriber

        transcriber = ParakeetTranscriber(str(Path(__file__).parent), local_files_only=True)
        with patch.dict(sys.modules, {"parakeet_mlx": None, "mlx": None, "mlx.core": None}):
            result = transcriber.transcribe_detailed(np.zeros(SAMPLE_RATE * 3, dtype=np.float32), vocab=VOCAB)
            self.assertEqual(result["reason"], "too_quiet")
            self.assertEqual(transcriber.transcribe(np.zeros(0, dtype=np.float32)), "")

    def test_parakeet_missing_package_is_a_clear_error(self):
        from undertone.stt import ParakeetTranscriber

        transcriber = ParakeetTranscriber(str(Path(__file__).parent), local_files_only=True)
        with patch.dict(sys.modules, {"parakeet_mlx": None}):
            with self.assertRaises(RuntimeError) as caught:
                transcriber.warm_up()
        self.assertIn("parakeet-mlx is not installed", str(caught.exception))

    def test_parakeet_repetition_loop_is_not_inserted(self):
        from undertone.stt import ParakeetTranscriber

        fake = FakeParakeetModules(text="ha ha ha ha ha ha ha ha ha ha ha ha")
        transcriber = ParakeetTranscriber(str(Path(__file__).parent), local_files_only=True)
        with patch.dict(sys.modules, fake.entries):
            result = transcriber.transcribe_detailed(_loud(3.0, seed=21))
        self.assertTrue(result["no_speech"])
        self.assertEqual(result["reason"], "repetition")

    def test_unknown_backend_is_rejected(self):
        from undertone.stt import make_transcriber

        with self.assertRaises(ValueError):
            make_transcriber({"stt_backend": "cloud"})


if __name__ == "__main__":
    unittest.main()
