import importlib.util
import pathlib
import unittest
from unittest.mock import patch, Mock, call
import sys

sys.dont_write_bytecode = True

path = pathlib.Path(__file__).resolve().parents[3] / 'priv/voice/pulse_audio.py'
spec = importlib.util.spec_from_file_location('pulse_audio', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class CursorTest(unittest.TestCase):
    def test_cursor_uses_played_samples_and_item_offsets(self):
        tracker = module.PlaybackTracker()
        first = {'response_id': 'r', 'item_id': 'i', 'content_index': 0}
        tracker.append(2400, first)
        tracker.append(2400, first)
        self.assertEqual(tracker.cursor(2400)['audio_end_ms'], 100)
        self.assertEqual(tracker.cursor(3600)['audio_end_ms'], 150)
        self.assertEqual(tracker.cursor(3000)['audio_end_ms'], 150)
        tracker.append(2400, dict(first, item_id='next'))
        self.assertEqual(tracker.cursor(6000)['audio_end_ms'], 50)

    def test_playback_bridges_short_delivery_gaps_and_drains_after_idle(self):
        endpoint = module.Endpoint.__new__(module.Endpoint)
        endpoint.closed = Mock(wraps=module.threading.Event())
        endpoint.controls = module.queue.Queue()
        endpoint.playback = Mock()
        endpoint.output = Mock()
        endpoint.output.latency_samples.return_value = 240
        endpoint.tracker = module.PlaybackTracker()
        endpoint.drained_total = 0
        clock = 1.0
        frame = b'\0' * module.FRAME_BYTES
        metadata = {'response_id': 'r', 'item_id': 'i', 'content_index': 0}
        deliveries = iter([(1.10, frame), (1.12, None), (1.16, frame),
                           (1.26, None), (1.30, None)])
        drained_at = []
        wrote_at = []

        def advance(seconds):
            nonlocal clock
            clock += seconds
            if drained_at:
                endpoint.closed.set()

        def deliver(**_):
            nonlocal clock
            item = next(deliveries, None)
            if item is None:
                endpoint.closed.set()
                raise module.queue.Empty()
            expected, data = item
            clock = max(clock, expected)
            if data is None:
                raise module.queue.Empty()
            return data, metadata

        endpoint.playback.get.side_effect = deliver
        endpoint.playback.empty.side_effect = lambda: bool(drained_at)
        endpoint.closed.wait.side_effect = advance
        endpoint.output.write.side_effect = lambda _: wrote_at.append(clock)
        endpoint.output.drain.side_effect = lambda: drained_at.append(clock)
        with patch.object(module.time, 'monotonic', side_effect=lambda: clock), \
             patch.object(module, 'emit') as emit:
            endpoint.play()
        self.assertEqual(wrote_at, [1.10, 1.16])
        self.assertEqual(drained_at, [1.30])
        self.assertEqual(endpoint.drained_total, module.FRAME_BYTES)
        self.assertEqual(emit.call_args.args[0]['cursor']['played_samples'], module.FRAME_BYTES)

    def test_saved_volumes_are_applied_to_the_selected_devices(self):
        volumes = {'microphone': 100, 'speaker': 40}
        originals = {'microphone': {'selected-mic': [65536]}, 'speaker': {'selected-speaker': [26214]}}
        with patch.object(module, 'command') as command:
            module.apply_saved_volumes({'input_volume': 0, 'output_volume': 65},
                                      'selected-mic', 'selected-speaker', volumes, originals)
            self.assertEqual(command.call_args_list, [
                (('--', 'set-source-volume', 'selected-mic', '0%'), {}),
                (('--', 'set-sink-volume', 'selected-speaker', '65%'), {}),
            ])
        self.assertEqual(volumes, {'microphone': 0, 'speaker': 65})

    def test_partial_setup_restores_asymmetric_microphone_channels(self):
        available = {'default_source_name': 'selected-mic', 'default_sink_name': 'selected-speaker'}
        microphone = {'name': 'selected-mic', 'channel_map': 'front-left,front-right',
                      'volume': {'front-left': {'value': 32768}, 'front-right': {'value': 49152}}}
        speaker = dict(microphone, name='selected-speaker')
        responses = [module.json.dumps(available), module.json.dumps([microphone]),
                     module.json.dumps([speaker]), '42', '', RuntimeError('speaker failed'),
                     '', '']
        with patch.object(module, 'command', side_effect=responses) as command, \
             patch.object(module, 'Pulse'):
            with self.assertRaisesRegex(RuntimeError, 'audio_volume_unavailable'):
                module.Endpoint({'input_volume': 20, 'output_volume': 65})
            self.assertEqual(command.call_args_list[-2],
                             call('--', 'set-source-volume', 'selected-mic', '32768', '49152'))


class DeviceTest(unittest.TestCase):
    def device(self):
        return {
            'name': 'selected-device', 'mute': False,
            'channel_map': 'front-left,front-right',
            'volume': {'front-left': {'value': 32768}, 'front-right': {'value': 49152}},
        }

    def test_microphone_test_restores_exact_channel_volumes(self):
        with patch.object(module, 'command', return_value=module.json.dumps([self.device()])) as command, \
             patch.object(module, 'run_test_io', return_value={'peak': 42}) as test_io:
            result = module.test_device({'kind': 'microphone', 'device_id': 'selected-device', 'volume': 23})
            self.assertEqual(result, {'peak': 42})
            test_io.assert_called_once_with('microphone', 'selected-device')
            self.assertEqual(command.call_args_list, [
                call('-f', 'json', 'list', 'sources', timeout=1.5),
                call('--', 'set-source-volume', 'selected-device', '23%', timeout=1.5),
                call('--', 'set-source-volume', 'selected-device', '32768', '49152', timeout=1.5),
            ])

    def test_failed_test_still_restores_volume(self):
        with patch.object(module, 'command', return_value=module.json.dumps([self.device()])) as command, \
             patch.object(module, 'run_test_io', side_effect=RuntimeError('device_test_timeout')):
            with self.assertRaisesRegex(RuntimeError, 'device_test_timeout'):
                module.test_device({'kind': 'speaker', 'device_id': 'selected-device', 'volume': 70})
            self.assertEqual(command.call_args_list[-1],
                             call('--', 'set-sink-volume', 'selected-device', '32768', '49152', timeout=1.5))

    def test_failed_volume_application_still_attempts_exact_restoration(self):
        responses = [module.json.dumps([self.device()]), RuntimeError('apply_failed'), '']
        with patch.object(module, 'command', side_effect=responses) as command, \
             patch.object(module, 'run_test_io') as test_io:
            with self.assertRaisesRegex(RuntimeError, 'apply_failed'):
                module.test_device({'kind': 'speaker', 'device_id': 'selected-device', 'volume': 20})
            self.assertEqual(command.call_args_list[-1],
                             call('--', 'set-sink-volume', 'selected-device', '32768', '49152', timeout=1.5))
            test_io.assert_not_called()

    def test_restore_failure_is_reported(self):
        responses = [module.json.dumps([self.device()]), '', RuntimeError('gone')]
        with patch.object(module, 'command', side_effect=responses), \
             patch.object(module, 'run_test_io', return_value={}):
            with self.assertRaisesRegex(RuntimeError, 'audio_volume_restore_failed'):
                module.test_device({'kind': 'speaker', 'device_id': 'selected-device', 'volume': 20})

    def test_io_timeout_is_reported_without_capture_data(self):
        timeout = module.subprocess.TimeoutExpired('audio-helper', 4)
        with patch.object(module.subprocess, 'run', side_effect=timeout):
            with self.assertRaisesRegex(RuntimeError, 'device_test_timeout'):
                module.run_test_io('microphone', 'selected-device')

    def test_muted_device_fails_without_changing_volume(self):
        device = dict(self.device(), mute=True)
        with patch.object(module, 'command', return_value=module.json.dumps([device])) as command, \
             patch.object(module, 'run_test_io') as test_io:
            with self.assertRaisesRegex(RuntimeError, 'device_muted'):
                module.test_device({'kind': 'speaker', 'device_id': 'selected-device', 'volume': 20})
            command.assert_called_once()
            test_io.assert_not_called()

    def test_unspecified_volume_preserves_physical_levels(self):
        with patch.object(module, 'command', return_value=module.json.dumps([self.device()])) as command, \
             patch.object(module, 'run_test_io', return_value={}):
            self.assertEqual(module.test_device({'kind': 'speaker', 'device_id': 'selected-device'}), {})
            command.assert_called_once_with('-f', 'json', 'list', 'sinks', timeout=1.5)

    def test_default_device_is_resolved_at_test_time(self):
        responses = [module.json.dumps({'default_source_name': 'selected-device'}),
                     module.json.dumps([self.device()])]
        with patch.object(module, 'command', side_effect=responses), \
             patch.object(module, 'run_test_io', return_value={'peak': 0}) as test_io:
            module.test_device({'kind': 'microphone'})
            test_io.assert_called_once_with('microphone', 'selected-device')

    def test_bad_volume_fails_before_device_access(self):
        with patch.object(module, 'command') as command:
            for volume in [-1, 151, True, '50']:
                with self.assertRaisesRegex(RuntimeError, 'invalid_device_test'):
                    module.test_device({'kind': 'speaker', 'volume': volume})
            command.assert_not_called()

    def test_helper_protocol_returns_only_the_device_test_result(self):
        request = {'command': 'test_device', 'id': 1, 'kind': 'microphone'}
        with patch.object(module, 'read_frame', return_value=request), \
             patch.object(module, 'test_device', return_value={'peak': 17}), \
             patch.object(module, 'emit') as emit, \
             patch.object(module.signal, 'signal'):
            module.main()
            emit.assert_called_once_with({'reply': 1, 'result': {'peak': 17}})

    def test_peak_is_measured_inside_the_audio_worker(self):
        stream = Mock()
        stream.read.return_value = module.struct.pack('<h', -16384) * (module.FRAME_BYTES // 2)
        with patch.object(module, 'Pulse', return_value=stream), patch.object(module, 'emit') as emit:
            self.assertEqual(module.test_audio('microphone', 'selected-device'), {'peak': 50})
            self.assertEqual(stream.read.call_count, 100)
            stream.close.assert_called_once()
            emit.assert_not_called()

    def test_speaker_tone_is_short_and_gentle(self):
        stream = Mock()
        with patch.object(module, 'Pulse', return_value=stream):
            self.assertEqual(module.test_audio('speaker', 'selected-device'), {})
            pcm = b''.join(call.args[0] for call in stream.write.call_args_list)
            self.assertEqual(len(pcm), int(module.RATE * 0.35) * 2)
            self.assertLessEqual(max(abs(sample[0]) for sample in module.struct.iter_unpack('<h', pcm)), 2622)
            stream.drain.assert_called_once()
            stream.close.assert_called_once()

unittest.main()
