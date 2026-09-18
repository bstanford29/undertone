from __future__ import annotations

import unittest
from unittest.mock import Mock, patch
import numpy as np

from undertone import hotkey


class PipelineTests(unittest.TestCase):
    def test_focus_change_retains_transcript_and_guard_without_insertion(self):
        model = Mock()
        model.transcribe.return_value = 'Keep all these words'
        result = {'clean_text':'Keep all these words.', 'guard_fired':True, 'model':None}
        with patch.object(hotkey, 'save_audio', return_value='/tmp/fixture.wav'), \
             patch.object(hotkey, 'clean_result', return_value=result), \
             patch.object(hotkey.history, 'frontmost_bundle_id', return_value='other.app'), \
             patch.object(hotkey.history, 'record') as record, \
             patch.object(hotkey.insert, 'insert') as insert:
            actual = hotkey.run_dictation_cycle(np.ones(16), model, {}, {'terms':['Fixture']}, app_bundle_id='target.app')
        insert.assert_not_called()
        self.assertEqual(actual['insert_mode'], 'failed')
        self.assertTrue(record.call_args.kwargs['guard_fired'])
        self.assertEqual(record.call_args.kwargs['audio_path'], '/tmp/fixture.wav')
        self.assertEqual(record.call_args.kwargs['app_bundle_id'], 'target.app')

    def test_completed_stream_does_not_invoke_stt_again(self):
        model = Mock()
        with patch.object(hotkey, 'save_audio', return_value='/tmp/fixture.wav'), \
             patch.object(hotkey, 'clean_result', return_value={'clean_text':'Full recording.', 'guard_fired':False, 'model':'fixture'}), \
             patch.object(hotkey.history, 'record'):
            result = hotkey.run_dictation_cycle(np.ones(16), model, {}, {'terms':['Fixture']}, False,
                                               app_bundle_id='target.app', raw_text_override='Full recording', stt_ms_override=123)
        model.transcribe.assert_not_called()
        self.assertEqual(result['stt_ms'], 123)
        self.assertEqual(result['insert_mode'], 'skipped')


if __name__ == '__main__':
    unittest.main()
