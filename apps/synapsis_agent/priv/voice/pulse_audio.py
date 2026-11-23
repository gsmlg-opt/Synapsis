#!/usr/bin/env python3
"""PulseAudio/PipeWire-Pulse PCM endpoint. Framed JSON is private to the host Port."""
import base64
import collections
import ctypes
import ctypes.util
import json
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
WRITE_LOCK = threading.Lock()


def emit(value):
    data = json.dumps(value, separators=(',', ':')).encode()
    with WRITE_LOCK:
        sys.stdout.buffer.write(struct.pack('>I', len(data)) + data)
        sys.stdout.buffer.flush()


def command(*args):
    result = subprocess.run(['pactl', *args], capture_output=True, timeout=4)
    if result.returncode:
        raise RuntimeError('audio_service_unavailable: ' + result.stderr.decode(errors='replace')[:300])
    return result.stdout.decode()


def devices():
    info = json.loads(command('-f', 'json', 'info'))
    inputs = json.loads(command('-f', 'json', 'list', 'sources'))
    outputs = json.loads(command('-f', 'json', 'list', 'sinks'))
    def project(item):
        return {'id': item['name'], 'label': item.get('description', item['name'])}
    return {
        'host': socket.gethostname(),
        'inputs': [project(item) for item in inputs if '.monitor' not in item['name']],
        'outputs': [project(item) for item in outputs],
        'default_input': info.get('default_source_name'),
        'default_output': info.get('default_sink_name'),
        'echo_cancellation': 'module-echo-cancel',
        'sample_rate': RATE,
    }


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
        self.playback = queue.Queue(maxsize=160)
        self.controls = queue.Queue(maxsize=16)
        self.tracker = PlaybackTracker()
        self.drained_total = 0
        self.module = None
        available = devices()
        input_id = options.get('input_device') or available['default_input']
        output_id = options.get('output_device') or available['default_output']
        if input_id not in [item['id'] for item in available['inputs']]:
            raise RuntimeError('input_device_unavailable')
        if output_id not in [item['id'] for item in available['outputs']]:
            raise RuntimeError('output_device_unavailable')
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
        except Exception:
            command('unload-module', self.module)
            self.module = None
            raise
        self.input_id = input_id
        self.output_id = output_id
        threading.Thread(target=self.watch_devices, daemon=True).start()
        threading.Thread(target=self.capture, daemon=True).start()
        threading.Thread(target=self.play, daemon=True).start()
        emit({'event': 'ready', 'info': dict(available, input_device=input_id,
            output_device=output_id, echo_cancellation='webrtc_reference', platform='linux')})

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
                    emit({'reply': control['id'], 'result': cursor})
                    continue
                except queue.Empty:
                    pass
                try:
                    data, metadata = self.playback.get(timeout=0.02)
                    self.output.write(data)
                    self.tracker.append(len(data) // 2, metadata)
                except queue.Empty:
                    if self.drained_total != self.tracker.total:
                        self.output.drain()
                        self.drained_total = self.tracker.total
                if time.monotonic() - last_cursor >= 0.05 and self.tracker.total:
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
            if self.playback.qsize() + len(chunks) > 150:
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
        if first['command'] != 'start':
            raise RuntimeError('start_required')
        endpoint = Endpoint(first)
        while not endpoint.closed.is_set():
            value = read_frame()
            if value is None:
                break
            endpoint.handle(value)
    except Exception as error:
        emit({'event': 'error', 'reason': str(error)})
    finally:
        if endpoint:
            endpoint.close()


if __name__ == '__main__':
    main()
