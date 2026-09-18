from __future__ import annotations

import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bench"))

import eval_cleanup
import tune_cleanup
from undertone import cleanup


PAIR = {
    "id": 1,
    "app": "com.fixture.app",
    "asr": "Synthetic raw fixture words",
    "formatted": "Synthetic raw fixture words.",
}


def successful_result():
    return {
        "clean_text": "Synthetic cleaned fixture words.",
        "guard_fired": False,
        "fallback_attempted": False,
        "model": "fixture",
    }


class EvalConfigTests(unittest.TestCase):
    def test_repeatable_app_variants_parse_and_reject_malformed_values(self):
        self.assertEqual(
            eval_cleanup.parse_app_variants([
                "com.fixture.one=Use concise tone",
                "com.fixture.two=Use formal tone",
            ]),
            {
                "com.fixture.one": "Use concise tone",
                "com.fixture.two": "Use formal tone",
            },
        )
        with self.assertRaises(ValueError):
            eval_cleanup.parse_app_variants(["com.fixture.one"])

    def test_eval_variant_reaches_clean_result_without_loading_user_config(self):
        captured = {}

        def fake_clean(raw, level, dictionary, config, app=None):
            captured.update(config=config, app=app)
            return successful_result()

        with patch.object(eval_cleanup, "clean_result", side_effect=fake_clean):
            eval_cleanup.run_cleanup(
                "fixture", PAIR["asr"], "medium", app=PAIR["app"],
                app_variants={PAIR["app"]: "Use fixture tone."},
            )

        self.assertEqual(captured["app"], PAIR["app"])
        self.assertEqual(captured["config"]["app_prompt_variants"], {
            PAIR["app"]: "Use fixture tone."
        })

    def test_no_app_style_clears_explicit_variants(self):
        captured = {}

        def fake_clean(raw, level, dictionary, config, app=None):
            captured.update(config=config, app=app)
            return successful_result()

        with patch.object(eval_cleanup, "clean_result", side_effect=fake_clean):
            eval_cleanup.run_cleanup(
                "fixture", PAIR["asr"], "medium", app=PAIR["app"], app_style=False,
                app_variants={PAIR["app"]: "Use fixture tone."},
            )

        self.assertEqual(captured["app"], None)
        self.assertEqual(captured["config"]["app_prompt_variants"], {})

    def test_high_candidate_swaps_high_prompt_and_restores_it(self):
        original_high = cleanup.HIGH_SYSTEM_PROMPT
        original_medium = cleanup.SYSTEM_PROMPT
        seen = []

        def fake_clean(raw, level, dictionary, config, app=None):
            seen.append((cleanup.HIGH_SYSTEM_PROMPT, cleanup.SYSTEM_PROMPT))
            return successful_result()

        try:
            with patch.object(cleanup, "clean_result", side_effect=fake_clean):
                tune_cleanup._run_candidate(
                    "HIGH CANDIDATE",
                    [PAIR],
                    "fixture",
                    "high",
                    app_style=False,
                )
        finally:
            self.assertEqual(cleanup.HIGH_SYSTEM_PROMPT, original_high)
            self.assertEqual(cleanup.SYSTEM_PROMPT, original_medium)

        self.assertEqual(seen, [("HIGH CANDIDATE", original_medium)])

    def test_prompt_restores_after_candidate_exception(self):
        original_high = cleanup.HIGH_SYSTEM_PROMPT

        def fail_clean(raw, level, dictionary, config, app=None):
            raise RuntimeError("synthetic failure")

        with patch.object(cleanup, "clean_result", side_effect=fail_clean):
            with self.assertRaises(RuntimeError):
                tune_cleanup._run_candidate(
                    "HIGH CANDIDATE",
                    [PAIR],
                    "fixture",
                    "high",
                    app_style=False,
                )

        self.assertEqual(cleanup.HIGH_SYSTEM_PROMPT, original_high)

    def test_tune_variant_reaches_canonical_clean_result(self):
        captured = {}

        def fake_clean(raw, level, dictionary, config, app=None):
            captured.update(config=config, app=app)
            return successful_result()

        with patch.object(cleanup, "clean_result", side_effect=fake_clean):
            tune_cleanup._run_candidate(
                "MEDIUM CANDIDATE",
                [PAIR],
                "fixture",
                "medium",
                app_style=True,
                app_variants={PAIR["app"]: "Use fixture tone."},
            )

        self.assertEqual(captured["app"], PAIR["app"])
        self.assertEqual(captured["config"]["app_prompt_variants"], {
            PAIR["app"]: "Use fixture tone."
        })


if __name__ == "__main__":
    unittest.main()
