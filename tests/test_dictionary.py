from __future__ import annotations
import tempfile
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
