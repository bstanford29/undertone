from __future__ import annotations

import json
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

from undertone import config, doctor


class _FakeResponse:
    def __init__(self, payload: dict) -> None:
        self._payload = json.dumps(payload).encode("utf-8")

    def read(self) -> bytes:
        return self._payload

    def __enter__(self) -> "_FakeResponse":
        return self

    def __exit__(self, *exc_info) -> bool:
        return False


class _FakeOpener:
    def __init__(self, response: _FakeResponse | None = None, error: Exception | None = None) -> None:
        self._response = response
        self._error = error

    def open(self, url: str, timeout: float | None = None):
        if self._error is not None:
            raise self._error
        return self._response


def _patch_opener(response: dict | None = None, error: Exception | None = None):
    fake = _FakeOpener(
        response=_FakeResponse(response) if response is not None else None,
        error=error,
    )
    return patch.object(doctor.urllib.request, "build_opener", return_value=fake)


class OllamaReachabilityTests(unittest.TestCase):
    def test_reachable_lists_model_names(self):
        payload = {"models": [{"name": "qwen3.5:latest"}, {"model": "gemma4:31b"}]}
        with _patch_opener(response=payload):
            models = doctor.fetch_ollama_models("http://localhost:11434")
        self.assertEqual(models, ["qwen3.5:latest", "gemma4:31b"])

    def test_check_ollama_reachable_ok(self):
        payload = {"models": [{"name": "qwen3.5:latest"}]}
        with _patch_opener(response=payload):
            check, models = doctor._check_ollama_reachable("http://localhost:11434")
        self.assertTrue(check.ok)
        self.assertEqual(check.tag, "ok")
        self.assertEqual(models, ["qwen3.5:latest"])

    def test_check_ollama_unreachable_is_a_required_failure(self):
        with _patch_opener(error=urllib.error.URLError("connection refused")):
            check, models = doctor._check_ollama_reachable("http://localhost:11434")
        self.assertFalse(check.ok)
        self.assertFalse(check.warn)
        self.assertEqual(check.tag, "fail")
        self.assertIsNone(models)
        self.assertIn("https://ollama.com", check.fix)

    def test_rejects_non_local_ollama_url(self):
        with self.assertRaises(ValueError):
            doctor.fetch_ollama_models("http://example.com:11434")


class ModelPresenceTests(unittest.TestCase):
    def test_required_model_present(self):
        check = doctor._check_model("cleanup_model", "qwen3.5:latest", ["qwen3.5:latest"], required=True)
        self.assertTrue(check.ok)
        self.assertEqual(check.tag, "ok")

    def test_required_model_missing_is_a_failure(self):
        check = doctor._check_model("cleanup_model", "qwen3.5:latest", ["other:latest"], required=True)
        self.assertFalse(check.ok)
        self.assertFalse(check.warn)
        self.assertEqual(check.tag, "fail")
        self.assertEqual(check.fix, "ollama pull qwen3.5:latest")

    def test_optional_model_missing_is_a_warning(self):
        check = doctor._check_model("cleanup_high_model", "gemma4:31b", ["qwen3.5:latest"], required=False)
        self.assertFalse(check.ok)
        self.assertTrue(check.warn)
        self.assertEqual(check.tag, "warn")
        self.assertEqual(check.fix, "ollama pull gemma4:31b")

    def test_model_matches_without_explicit_latest_tag(self):
        self.assertTrue(doctor._model_present("qwen3.5", ["qwen3.5:latest"]))

    def test_unreachable_ollama_cannot_check_model(self):
        check = doctor._check_model("cleanup_model", "qwen3.5:latest", None, required=True)
        self.assertFalse(check.ok)
        self.assertFalse(check.warn)
        self.assertIn("unreachable", check.detail)


class WhisperCacheTests(unittest.TestCase):
    def test_cached_model_is_ok(self):
        with tempfile.TemporaryDirectory() as directory:
            cache_root = Path(directory)
            folder = cache_root / "models--mlx-community--whisper-large-v3-turbo"
            folder.mkdir()
            (folder / "config.json").write_text("{}")
            with patch.dict("os.environ", {"HF_HUB_CACHE": str(cache_root)}, clear=False):
                check = doctor._check_whisper_cache("mlx-community/whisper-large-v3-turbo", download=False)
        self.assertTrue(check.ok)

    def test_missing_model_is_a_warning_not_a_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict("os.environ", {"HF_HUB_CACHE": directory}, clear=False):
                check = doctor._check_whisper_cache("mlx-community/whisper-large-v3-turbo", download=False)
        self.assertFalse(check.ok)
        self.assertTrue(check.warn)
        self.assertEqual(check.tag, "warn")
        self.assertIn("1.6 GB", check.detail)
        self.assertIn("--download", check.fix)

    def test_download_flag_invokes_load_model(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict("os.environ", {"HF_HUB_CACHE": directory}, clear=False):
                with patch.object(doctor, "_download_whisper_model") as download:
                    check = doctor._check_whisper_cache("mlx-community/whisper-large-v3-turbo", download=True)
        download.assert_called_once_with("mlx-community/whisper-large-v3-turbo")
        self.assertTrue(check.ok)

    def test_honors_hf_home_when_hub_cache_unset(self):
        import os

        with tempfile.TemporaryDirectory() as directory:
            hub = Path(directory) / "hub"
            folder = hub / "models--mlx-community--whisper-large-v3-turbo"
            folder.mkdir(parents=True)
            (folder / "config.json").write_text("{}")
            env = dict(os.environ)
            env.pop("HF_HUB_CACHE", None)
            env["HF_HOME"] = directory
            with patch.dict("os.environ", env, clear=True):
                check = doctor._check_whisper_cache("mlx-community/whisper-large-v3-turbo", download=False)
        self.assertTrue(check.ok)


class RunChecksAndReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        patcher = patch.object(config, "CONFIG_DIR", root)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = patch.object(config, "CONFIG_PATH", root / "config.yaml")
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_run_checks_all_pass(self):
        payload = {"models": [{"name": "qwen3.5:latest"}, {"name": "gemma4:31b"}]}
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory) / "models--mlx-community--whisper-large-v3-turbo"
            folder.mkdir()
            (folder / "config.json").write_text("{}")
            with patch.dict("os.environ", {"HF_HUB_CACHE": directory}, clear=False):
                with _patch_opener(response=payload):
                    checks = doctor.run_checks(dict(config.DEFAULTS))
        # Every check but the informational config-file check (no config
        # written in this temp home) should be a clean ok.
        by_name = {check.name: check for check in checks}
        for name in ("mlx-whisper", "ollama", "cleanup_model", "cleanup_high_model", "whisper model", "~/.undertone writable"):
            self.assertTrue(by_name[name].ok, f"{name}: {by_name[name].detail}")
        self.assertFalse(by_name["config file"].ok)
        self.assertTrue(by_name["config file"].warn)

    def test_run_checks_missing_everything_fails_required_only(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict("os.environ", {"HF_HUB_CACHE": directory}, clear=False):
                with _patch_opener(error=urllib.error.URLError("refused")):
                    checks = doctor.run_checks(dict(config.DEFAULTS))
        required_failures = [c for c in checks if not c.ok and not c.warn]
        names = {c.name for c in required_failures}
        self.assertIn("ollama", names)
        self.assertIn("cleanup_model", names)
        self.assertNotIn("cleanup_high_model", names)

    def test_format_report_includes_tags_and_fixes(self):
        checks = [
            doctor.Check("a", True, "all good"),
            doctor.Check("b", False, "needs a pull", fix="ollama pull b", warn=True),
            doctor.Check("c", False, "missing", fix="install c"),
        ]
        report = doctor.format_report(checks)
        lines = report.splitlines()
        self.assertEqual(lines[0], "ok   a: all good")
        self.assertEqual(lines[1], "warn b: needs a pull")
        self.assertEqual(lines[2], "fail c: missing")
        self.assertIn("Next steps:", report)
        self.assertIn("  - ollama pull b", report)
        self.assertIn("  - install c", report)

    def test_format_report_no_fixes_section_when_all_ok(self):
        report = doctor.format_report([doctor.Check("a", True, "fine")])
        self.assertNotIn("Next steps", report)


if __name__ == "__main__":
    unittest.main()
