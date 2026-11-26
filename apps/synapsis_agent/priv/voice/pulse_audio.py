#!/usr/bin/env python3
"""PulseAudio/PipeWire-Pulse PCM endpoint. Framed JSON is private to the host Port."""
import base64
import collections
import ctypes
import ctypes.util
import json
import math
import os
import queue
import socket
import signal
import struct
import subprocess
import sys
import threading
import time

RATE = 24000
FRAME_BYTES = 960
MAX_BUFFER_BYTES = RATE * 2 * 3
MAX_PLAYBACK_FRAMES = RATE * 2 * 15 // FRAME_BYTES
PLAYBACK_BUFFER_FRAMES = 6
PLAYBACK_PREBUFFER_FRAMES = 3
PLAYBACK_PREROLL_SECONDS = 0.10
PLAYBACK_DRAIN_IDLE_SECONDS = 0.12
WRITE_LOCK = threading.Lock()


def emit(value):
    data = json.dumps(value, separators=(',', ':')).encode()
    with WRITE_LOCK:
        sys.stdout.buffer.write(struct.pack('>I', len(data)) + data)
        sys.stdout.buffer.flush()


def command(*args, timeout=4):
    result = subprocess.run(['pactl', *args], capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('audio_service_unavailable: ' + result.stderr.decode(errors='replace')[:300])
    return result.stdout.decode()


def devices():
    return device_snapshot()[0]


def device_snapshot():
    info = json.loads(command('-f', 'json', 'info'))
    inputs = json.loads(command('-f', 'json', 'list', 'sources'))
    outputs = json.loads(command('-f', 'json', 'list', 'sinks'))
    def project(item):
        channels = [channel['value'] for channel in (item.get('volume') or {}).values()]
        volume = round(max(channels) * 100 / 65536) if channels else None
        return {'id': item['name'], 'label': item.get('description', item['name']),
                'volume': volume}
    available = {
        'host': socket.gethostname(),
        'inputs': [project(item) for item in inputs if '.monitor' not in item['name']],
        'outputs': [project(item) for item in outputs],
        'default_input': info.get('default_source_name'),
        'default_output': info.get('default_sink_name'),
        'echo_cancellation': 'module-echo-cancel',
        'sample_rate': RATE,
    }
    originals = {
        'microphone': {item['name']: channel_volumes(item) for item in inputs},
        'speaker': {item['name']: channel_volumes(item) for item in outputs},
    }
    return available, originals


def channel_volumes(device):
    channel_map = device.get('channel_map') or ''
    channels = channel_map.split(',') if isinstance(channel_map, str) else channel_map
    levels = (device.get('volume') or {})
    return [levels.get(channel, {}).get('value') for channel in channels]


def valid_channel_volumes(values):
    return bool(values) and all(type(value) is int and value >= 0 for value in values)


def apply_saved_volumes(options, input_id, output_id, volumes, originals):
    routes = [('input_volume', 'microphone', 'set-source-volume', input_id),
              ('output_volume', 'speaker', 'set-sink-volume', output_id)]
    settings = [(kind, operation, name, options.get(key)) for key, kind, operation, name in routes
                if options.get(key) is not None]
    if any(type(level) is not int or not 0 <= level <= 150 or
           not valid_channel_volumes(originals[kind][name]) for kind, _, name, level in settings):
        raise RuntimeError('audio_volume_unavailable')
    applied = []
    try:
        for kind, operation, name, level in settings:
            command('--', operation, name, f'{level}%')
            applied.append((operation, name, originals[kind][name]))
            volumes[kind] = level
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        for operation, name, original in reversed(applied):
            try:
                command('--', operation, name, *[str(value) for value in original])
            except (RuntimeError, subprocess.TimeoutExpired):
                # The device may have vanished during setup.
                continue
        raise RuntimeError('audio_volume_unavailable') from error


def test_device(options):
    kind = options.get('kind')
    device_id = options.get('device_id')
    volume = options.get('volume')
    if kind not in ('microphone', 'speaker') or (device_id is not None and
            (not isinstance(device_id, str) or not 0 < len(device_id) <= 1024 or '\x00' in device_id)) or (
            volume is not None and (type(volume) is not int or not 0 <= volume <= 150)):
        raise RuntimeError('invalid_device_test')
    direction = 'source' if kind == 'microphone' else 'sink'
    if device_id is None:
        info = json.loads(command('-f', 'json', 'info', timeout=1.5))
        device_id = info.get('default_' + direction + '_name')
    available = json.loads(command('-f', 'json', 'list', direction + 's', timeout=1.5))
    device = next((item for item in available if item['name'] == device_id), None)
    if device is None or (kind == 'microphone' and '.monitor' in device_id):
        raise RuntimeError('device_unavailable')
    if device.get('mute'):
        raise RuntimeError('device_muted')
    original = channel_volumes(device)
    if volume is not None and not valid_channel_volumes(original):
        raise RuntimeError('audio_volume_unavailable')
    operation = 'set-' + direction + '-volume'
    try:
        if volume is not None:
            command('--', operation, device_id, str(volume) + '%', timeout=1.5)
        return run_test_io(kind, device_id)
    finally:
        if volume is not None:
            try:
                command('--', operation, device_id, *[str(value) for value in original], timeout=1.5)
            except (RuntimeError, subprocess.TimeoutExpired) as error:
                raise RuntimeError('audio_volume_restore_failed') from error


def run_test_io(kind, device_id):
    # A separate process bounds native library calls, including hung reads and
    # stream teardown. This helper remains available to restore device volumes.
    try:
        result = subprocess.run([sys.executable, __file__, '--test-audio', kind, device_id],
                                capture_output=True, text=True, timeout=4)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError('device_test_timeout') from error
    try:
        value = json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise RuntimeError('device_test_failed') from error
    if result.returncode:
        raise RuntimeError(str(value.get('error', 'device_test_failed'))[:256])
    if kind == 'microphone':
        if type(value.get('peak')) is not int or not 0 <= value['peak'] <= 100:
            raise RuntimeError('invalid_device_test_result')
        return {'peak': value['peak']}
    return {}


def test_audio(kind, device_id):
    stream = Pulse(device_id, 2 if kind == 'microphone' else 1)
    try:
        if kind == 'microphone':
            peak = 0
            for _ in range(100):
                data = stream.read()
                peak = max(peak, max(abs(sample[0]) for sample in struct.iter_unpack('<h', data)))
            return {'peak': min(100, round(peak * 100 / 32768))}
        samples = int(RATE * 0.35)
        pcm = bytearray()
        for index in range(samples):
            envelope = min(1, index / (RATE * 0.03), (samples - index - 1) / (RATE * 0.03))
            value = round(32767 * 0.08 * envelope * math.sin(2 * math.pi * 440 * index / RATE))
            pcm.extend(struct.pack('<h', value))
        for offset in range(0, len(pcm), FRAME_BYTES):
            stream.write(bytes(pcm[offset:offset + FRAME_BYTES]))
        stream.drain()
        return {}
    finally:
        stream.close()


class PlaybackTracker:
    def __init__(self):
        self.total = 0
        self.played = 0
        self.segments = collections.deque()

    def append(self, samples, metadata):
        end = self.total + samples
        identity = {key: metadata[key] for key in ('response_id', 'item_id', 'content_index')}
        if self.segments and self.segments[-1]['identity'] == identity:
            self.segments[-1]['end'] = end
        else:
            self.segments.append({'start': self.total, 'end': end, 'identity': identity})
        self.total = end

    def cursor(self, played):
        played = max(self.played, min(self.total, played))
        self.played = played
        while len(self.segments) > 1 and played >= self.segments[1]['start']:
            self.segments.popleft()
        if not self.segments:
            return None
        segment = self.segments[0]
        samples = min(segment['end'], max(segment['start'], played)) - segment['start']
        return dict(segment['identity'], audio_end_ms=samples * 1000 // RATE,
                    played_samples=samples, accurate=True)


class SampleSpec(ctypes.Structure):
    _fields_ = [('format', ctypes.c_int), ('rate', ctypes.c_uint32), ('channels', ctypes.c_uint8)]


class BufferAttr(ctypes.Structure):
    _fields_ = [(key, ctypes.c_uint32) for key in ('maxlength', 'tlength', 'prebuf', 'minreq', 'fragsize')]


class Pulse:
    def __init__(self, device, direction):
        library = os.environ.get('SYNAPSIS_PULSE_LIBRARY') or ctypes.util.find_library('pulse-simple')
        if not library:
            raise RuntimeError('pulse_library_missing')
        self.lib = ctypes.CDLL(library)
        self.lib.pa_simple_new.restype = ctypes.c_void_p
        self.lib.pa_simple_new.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int,
            ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(SampleSpec), ctypes.c_void_p,
            ctypes.POINTER(BufferAttr), ctypes.POINTER(ctypes.c_int)]
        self.lib.pa_simple_write.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_int)]
        self.lib.pa_simple_read.argtypes = self.lib.pa_simple_write.argtypes
        self.lib.pa_simple_get_latency.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
        self.lib.pa_simple_get_latency.restype = ctypes.c_uint64
        self.lib.pa_simple_flush.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
        self.lib.pa_simple_drain.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
        self.lib.pa_simple_free.argtypes = [ctypes.c_void_p]
        error = ctypes.c_int()
        spec = SampleSpec(3, RATE, 1)  # PA_SAMPLE_S16LE
        if direction == 1:
            attr = BufferAttr(MAX_BUFFER_BYTES, FRAME_BYTES * PLAYBACK_BUFFER_FRAMES,
                              FRAME_BYTES * PLAYBACK_PREBUFFER_FRAMES, FRAME_BYTES, FRAME_BYTES)
        else:
            attr = BufferAttr(MAX_BUFFER_BYTES, FRAME_BYTES * 3, FRAME_BYTES, FRAME_BYTES, FRAME_BYTES)
        self.pointer = self.lib.pa_simple_new(None, b'Synapsis Voice', direction, device.encode(),
            b'Voice PCM', ctypes.byref(spec), None, ctypes.byref(attr), ctypes.byref(error))
        if not self.pointer:
            raise RuntimeError('device_open_failed: ' + str(error.value))

    def write(self, data):
        error = ctypes.c_int()
        if self.lib.pa_simple_write(self.pointer, data, len(data), ctypes.byref(error)) < 0:
            raise RuntimeError('playback_failed: ' + str(error.value))

    def read(self):
        data = ctypes.create_string_buffer(FRAME_BYTES)
        error = ctypes.c_int()
        if self.lib.pa_simple_read(self.pointer, data, FRAME_BYTES, ctypes.byref(error)) < 0:
            raise RuntimeError('capture_failed: ' + str(error.value))
        return data.raw

    def latency_samples(self):
        error = ctypes.c_int()
        latency = self.lib.pa_simple_get_latency(self.pointer, ctypes.byref(error))
        if latency == 2**64 - 1:
            raise RuntimeError('playback_timing_unavailable: ' + str(error.value))
        return latency * RATE // 1000000

    def drain(self):
        error = ctypes.c_int()
        if self.lib.pa_simple_drain(self.pointer, ctypes.byref(error)) < 0:
            raise RuntimeError('playback_drain_failed: ' + str(error.value))

    def flush(self):
        error = ctypes.c_int()
        if self.lib.pa_simple_flush(self.pointer, ctypes.byref(error)) < 0:
            raise RuntimeError('playback_flush_failed: ' + str(error.value))

    def close(self):
        self.lib.pa_simple_free(self.pointer)


class Endpoint:
    def __init__(self, options):
        self.closed = threading.Event()
        self.muted = False
        self.playback = queue.Queue(maxsize=MAX_PLAYBACK_FRAMES)
        self.controls = queue.Queue(maxsize=16)
        self.tracker = PlaybackTracker()
        self.drained_total = 0
        self.module = None
        available, originals = device_snapshot()
        input_id = options.get('input_device') or available['default_input']
        output_id = options.get('output_device') or available['default_output']
        if input_id not in [item['id'] for item in available['inputs']]:
            raise RuntimeError('input_device_unavailable')
        if output_id not in [item['id'] for item in available['outputs']]:
            raise RuntimeError('output_device_unavailable')
        volumes = {
            'microphone': next(device['volume'] for device in available['inputs'] if device['id'] == input_id),
            'speaker': next(device['volume'] for device in available['outputs'] if device['id'] == output_id),
        }
        # PulseAudio's echo-cancel module connects playback reference and input source.
        # PipeWire-Pulse implements this through its WebRTC echo-cancel implementation.
        name = 'synapsis_voice_' + str(os.getpid())
        self.module = command('load-module', 'module-echo-cancel',
            'source_master=' + input_id, 'sink_master=' + output_id,
            'source_name=' + name + '_source', 'sink_name=' + name + '_sink',
            'aec_method=webrtc', 'rate=24000', 'channels=1').strip()
        try:
            self.output = Pulse(name + '_sink', 1)
            self.input = Pulse(name + '_source', 2)
            apply_saved_volumes(options, input_id, output_id, volumes, originals)
        except Exception:
            for stream in [getattr(self, 'input', None), getattr(self, 'output', None)]:
                if stream:
                    stream.close()
            command('unload-module', self.module)
            self.module = None
            raise
        self.input_id = input_id
        self.output_id = output_id
        threading.Thread(target=self.watch_devices, daemon=True).start()
        threading.Thread(target=self.capture, daemon=True).start()
        threading.Thread(target=self.play, daemon=True).start()
        emit({'event': 'ready', 'info': dict(available, input_device=input_id,
            output_device=output_id, volumes=volumes, echo_cancellation='webrtc_reference', platform='linux')})

    def watch_devices(self):
        try:
            while not self.closed.wait(2):
                available = devices()
                if self.input_id not in [item['id'] for item in available['inputs']]:
                    raise RuntimeError('input_device_disconnected')
                if self.output_id not in [item['id'] for item in available['outputs']]:
                    raise RuntimeError('output_device_disconnected')
        except Exception as error:
            if not self.closed.is_set():
                emit({'event': 'error', 'reason': str(error)})
                self.closed.set()

    def capture(self):
        try:
            while not self.closed.is_set():
                data = self.input.read()
                if not self.muted:
                    emit({'event': 'capture', 'pcm': base64.b64encode(data).decode()})
        except Exception as error:
            if not self.closed.is_set():
                emit({'event': 'error', 'reason': str(error)})
                self.closed.set()
        finally:
            self.input.close()

    def position(self):
        if self.drained_total == self.tracker.total:
            return self.tracker.cursor(self.tracker.total)
        return self.tracker.cursor(self.tracker.total - self.output.latency_samples())

    def play(self):
        last_cursor = 0
        last_write = 0
        preroll_until = None
        try:
            while not self.closed.is_set():
                try:
                    control = self.controls.get_nowait()
                    cursor = self.position()
                    if control['command'] == 'stop_playback':
                        while True:
                            try:
                                self.playback.get_nowait()
                            except queue.Empty:
                                break
                        self.output.flush()
                        self.tracker = PlaybackTracker()
                        self.drained_total = 0
                        preroll_until = None
                    emit({'reply': control['id'], 'result': cursor})
                    continue
                except queue.Empty:
                    pass
                # Stage the first burst before handing PCM to the device. Keep
                # polling controls so stop_playback can discard it before sound.
                if self.drained_total == self.tracker.total:
                    if self.playback.empty():
                        self.closed.wait(0.02)
                        continue
                    now = time.monotonic()
                    if preroll_until is None:
                        preroll_until = now + PLAYBACK_PREROLL_SECONDS
                    if now < preroll_until:
                        self.closed.wait(min(0.02, preroll_until - now))
                        continue
                    preroll_until = None
                drained = False
                try:
                    data, metadata = self.playback.get(timeout=0.02)
                    self.output.write(data)
                    self.tracker.append(len(data) // 2, metadata)
                    last_write = time.monotonic()
                except queue.Empty:
                    # The upstream stream can pause briefly between audio deltas.
                    if (self.drained_total != self.tracker.total and
                            time.monotonic() - last_write >= PLAYBACK_DRAIN_IDLE_SECONDS):
                        self.output.drain()
                        self.drained_total = self.tracker.total
                        drained = True
                # Publish the exact end even if the periodic cursor was just sent.
                if self.tracker.total and (drained or time.monotonic() - last_cursor >= 0.05):
                    emit({'event': 'cursor', 'cursor': self.position()})
                    last_cursor = time.monotonic()
        except Exception as error:
            if not self.closed.is_set():
                emit({'event': 'error', 'reason': str(error)})
                self.closed.set()
        finally:
            self.output.close()

    def handle(self, value):
        kind = value['command']
        if kind == 'play':
            data = base64.b64decode(value['pcm'], validate=True)
            if not data or len(data) % 2 or len(data) > RATE * 4:
                raise RuntimeError('invalid_audio')
            chunks = [(data[index:index + FRAME_BYTES], value['metadata'])
                      for index in range(0, len(data), FRAME_BYTES)]
            if self.playback.qsize() + len(chunks) > MAX_PLAYBACK_FRAMES:
                raise RuntimeError('playback_queue_overflow')
            for chunk in chunks:
                self.playback.put_nowait(chunk)
        elif kind == 'mute':
            self.muted = bool(value['muted'])
            emit({'reply': value['id'], 'result': {'muted': self.muted}})
        elif kind in ('stop_playback', 'cursor'):
            self.controls.put_nowait(value)
        elif kind == 'close':
            self.closed.set()
        else:
            raise RuntimeError('invalid_command')

    def close(self):
        self.closed.set()
        if self.module:
            command('unload-module', self.module)
            self.module = None


def read_frame():
    header = sys.stdin.buffer.read(4)
    if not header:
        return None
    if len(header) != 4:
        raise RuntimeError('invalid_frame')
    length = struct.unpack('>I', header)[0]
    if length > 150000:
        raise RuntimeError('frame_too_large')
    body = sys.stdin.buffer.read(length)
    if len(body) != length:
        raise RuntimeError('incomplete_frame')
    return json.loads(body)


def main():
    def shutdown(_signum, _frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, shutdown)
    endpoint = None
    try:
        first = read_frame()
        if first is None:
            return
        if first['command'] == 'devices':
            emit({'reply': first['id'], 'result': devices()})
            return
        if first['command'] == 'test_device':
            emit({'reply': first['id'], 'result': test_device(first)})
            return
        if first['command'] != 'start':
            raise RuntimeError('start_required')
        endpoint = Endpoint(first)
        while not endpoint.closed.is_set():
            value = read_frame()
            if value is None:
                break
            endpoint.handle(value)
    except Exception as error:
        emit({'event': 'error', 'reason': str(error)[:256]})
    finally:
        if endpoint:
            endpoint.close()


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[1] == '--test-audio':
        try:
            print(json.dumps(test_audio(sys.argv[2], sys.argv[3])))
        except Exception as error:
            print(json.dumps({'error': str(error)[:256]}))
            sys.exit(1)
    else:
        main()
