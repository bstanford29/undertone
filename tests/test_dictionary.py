from __future__ import annotations
import unittest
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
