from __future__ import annotations
import fcntl
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from undertone import dictionary


class DictionaryTests(unittest.TestCase):
    def test_replacement_is_literal_not_a_regex_template(self):
        self.assertEqual(dictionary.apply_replacements('Use path please', {'replacements':{'path':r'C:\new\thing'}}), r'Use C:\new\thing please')

    def test_empty_explicit_dictionary_does_not_load_personal_data(self):
        with patch.object(dictionary, 'load_dictionary') as load:
            self.assertEqual(dictionary.vocab_prompt({}), '')
            self.assertEqual(dictionary.apply_replacements('Keep this', {}), 'Keep this')
            load.assert_not_called()

    def test_failed_save_keeps_the_previous_dictionary_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(dictionary, 'DICTIONARY_DIR', root), patch.object(
                dictionary, 'DICTIONARY_PATH', root / 'dictionary.yaml'
            ):
                dictionary.save_dictionary({'terms': ['Stable'], 'replacements': {}})
                with patch.object(dictionary.yaml, 'safe_dump', side_effect=OSError('fixture')):
                    with self.assertRaises(OSError):
                        dictionary.save_dictionary({'terms': ['Lost'], 'replacements': {}})
                self.assertEqual(dictionary.load_dictionary()['terms'], ['Stable'])

    def test_replacement_and_term_updates_preserve_each_other(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(dictionary, 'DICTIONARY_DIR', root), patch.object(
                dictionary, 'DICTIONARY_PATH', root / 'dictionary.yaml'
            ):
                dictionary.add_term('Velora')
                dictionary.set_replacement('btw', 'by the way')
                saved = dictionary.load_dictionary()
                self.assertIn('Velora', saved['terms'])
                self.assertEqual(saved['replacements']['btw'], 'by the way')

    def test_mutation_waits_for_interprocess_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'dictionary.yaml'
            lock_path = root / 'dictionary.yaml.lock'
            with patch.object(dictionary, 'DICTIONARY_DIR', root), patch.object(
                dictionary, 'DICTIONARY_PATH', path
            ):
                dictionary.save_dictionary({'terms': ['Stable'], 'replacements': {}})
                marker = root / 'started'
                code = "\n".join([
                    "from pathlib import Path",
                    "import sys",
                    "from undertone import dictionary",
                    f"dictionary.DICTIONARY_DIR = Path({str(root)!r})",
                    f"dictionary.DICTIONARY_PATH = Path({str(path)!r})",
                    f"Path({str(marker)!r}).touch()",
                    "dictionary.add_term('Concurrent')",
                ])
                environment = dict(os.environ)
                environment['PYTHONPATH'] = str(Path(__file__).parents[1] / 'engine')
                with lock_path.open('a') as lock_file:
                    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
                    process = subprocess.Popen([sys.executable, '-c', code], env=environment)
                    try:
                        deadline = time.monotonic() + 2
                        while not marker.exists() and time.monotonic() < deadline:
                            time.sleep(0.01)
                        self.assertTrue(marker.exists())
                        time.sleep(0.1)
                        self.assertIsNone(process.poll(), 'dictionary mutation ignored the process lock')
                    finally:
                        fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
                self.assertEqual(process.wait(timeout=2), 0)
                self.assertIn('Concurrent', dictionary.load_dictionary()['terms'])
