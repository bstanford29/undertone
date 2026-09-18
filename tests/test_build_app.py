from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "app" / "scripts" / "build_app.sh"


class BuildAppTests(unittest.TestCase):
    def _fixture(self) -> tuple[tempfile.TemporaryDirectory, Path, Path]:
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        app = root / "app"
        (app / "scripts").mkdir(parents=True)
        (app / "Resources").mkdir()
        (app / "Resources" / "fixture.txt").write_text("fixture", encoding="utf-8")
        (app / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": "com.undertone.app",
                    "CFBundleName": "Undertone",
                    "CFBundleDisplayName": "Undertone",
                }
            )
        )
        (app / "scripts" / "build_app.sh").write_bytes(SCRIPT.read_bytes())
        (app / "scripts" / "build_app.sh").chmod(0o755)
        return temp, root, app

    @staticmethod
    def _init_repo(root: Path) -> str:
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"],
            cwd=root,
            check=True,
        )
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()

    @staticmethod
    def _fake_swift(bin_dir: Path) -> None:
        fake = bin_dir / "swift"
        fake.write_text(
            "#!/bin/sh\n"
            "while [ $# -gt 0 ]; do\n"
            "  if [ \"$1\" = \"--package-path\" ]; then shift; package=$1; fi\n"
            "  shift\n"
            "done\n"
            "mkdir -p \"$package/.build/arm64-apple-macosx/release\"\n"
            "printf 'fixture product' > \"$package/.build/arm64-apple-macosx/release/Undertone\"\n"
            "chmod +x \"$package/.build/arm64-apple-macosx/release/Undertone\"\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)

    @staticmethod
    def _fake_codesign(bin_dir: Path) -> None:
        fake = bin_dir / "codesign"
        fake.write_text(
            "#!/bin/sh\n"
            "for arg in \"$@\"; do printf '%s\\n' \"$arg\" >> \"$UNDERTONE_CODESIGN_LOG\"; done\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)

    def _run(self, root: Path, app: Path, *args: str, signing_identity: str | None = None) -> subprocess.CompletedProcess[str]:
        bin_dir = root / "bin"
        bin_dir.mkdir(exist_ok=True)
        self._fake_swift(bin_dir)
        self._fake_codesign(bin_dir)
        env = os.environ.copy()
        env["PATH"] = f"{bin_dir}:/usr/bin:/bin"
        env["UNDERTONE_CODESIGN_LOG"] = str(root / "codesign.log")
        if signing_identity is not None:
            env["UNDERTONE_SIGNING_IDENTITY"] = signing_identity
        else:
            env.pop("UNDERTONE_SIGNING_IDENTITY", None)
        return subprocess.run(
            [str(app / "scripts" / "build_app.sh"), *args],
            cwd=root,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    @staticmethod
    def _plist(path: Path) -> dict:
        return plistlib.loads((path / "Contents" / "Info.plist").read_bytes())

    def test_preview_and_production_have_distinct_staged_identities(self):
        temp, root, app = self._fixture()
        with temp:
            commit = self._init_repo(root)
            preview = self._run(root, app)
            self.assertEqual(preview.returncode, 0, preview.stderr)
            preview_path = Path(preview.stdout.strip())
            self.assertEqual(preview_path, app / ".build" / "Undertone Preview.app")
            preview_info = self._plist(preview_path)
            self.assertEqual(preview_info["CFBundleIdentifier"], "com.undertone.preview.build")
            self.assertEqual(preview_info["CFBundleName"], "Undertone Preview")
            self.assertEqual(preview_info["UndertoneBuildCommit"], commit)
            self.assertEqual((preview_path / "Contents" / "Resources" / "fixture.txt").read_text(), "fixture")

            production = self._run(root, app, "--production", signing_identity="Apple Development: Test")
            self.assertEqual(production.returncode, 0, production.stderr)
            production_path = Path(production.stdout.strip())
            self.assertEqual(production_path, app / ".build" / "production" / "Undertone")
            self.assertFalse(production_path.name.endswith(".app"))
            production_info = self._plist(production_path)
            self.assertEqual(production_info["CFBundleIdentifier"], "com.undertone.app")
            self.assertEqual(production_info["CFBundleName"], "Undertone")
            self.assertEqual(production_info["UndertoneBuildCommit"], commit)
            signing = (root / "codesign.log").read_text().splitlines()
            self.assertEqual(signing[:4], ["--force", "--sign", "Apple Development: Test", str(production_path)])
            self.assertEqual(signing[4:7], ["--verify", "--strict", str(production_path)])

    def test_production_requires_explicit_signing_identity(self):
        temp, root, app = self._fixture()
        with temp:
            self._init_repo(root)
            result = self._run(root, app, "--production")
            self.assertEqual(result.returncode, 2)
            self.assertIn("UNDERTONE_SIGNING_IDENTITY", result.stderr)
            self.assertFalse((app / ".build").exists())

    def test_production_rejects_adhoc_signing_identity(self):
        temp, root, app = self._fixture()
        with temp:
            self._init_repo(root)
            result = self._run(root, app, "--production", signing_identity="-")
            self.assertEqual(result.returncode, 2)
            self.assertIn("rejects ad hoc signing", result.stderr)
            self.assertFalse((app / ".build").exists())

    def test_unknown_arguments_fail_before_build(self):
        temp, root, app = self._fixture()
        with temp:
            result = self._run(root, app, "--staging")
            self.assertEqual(result.returncode, 2)
            self.assertIn("unknown argument", result.stderr)
            self.assertFalse((app / ".build").exists())


if __name__ == "__main__":
    unittest.main()
