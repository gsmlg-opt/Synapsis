import importlib.util
import pathlib
import unittest
import sys

sys.dont_write_bytecode = True

path = pathlib.Path(__file__).resolve().parents[3] / 'priv/voice/pulse_audio.py'
class CursorTest(unittest.TestCase):
    def test_cursor_uses_played_samples_and_item_offsets(self):
        spec = importlib.util.spec_from_file_location('pulse_audio', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        tracker = module.PlaybackTracker()
        first = {'response_id': 'r', 'item_id': 'i', 'content_index': 0}
        tracker.append(2400, first)
        tracker.append(2400, first)
        self.assertEqual(tracker.cursor(2400)['audio_end_ms'], 100)
        self.assertEqual(tracker.cursor(3600)['audio_end_ms'], 150)
        self.assertEqual(tracker.cursor(3000)['audio_end_ms'], 150)
        tracker.append(2400, dict(first, item_id='next'))
        self.assertEqual(tracker.cursor(6000)['audio_end_ms'], 50)

unittest.main()
