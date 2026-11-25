import assert from 'node:assert/strict'
import { setImmediate } from 'node:timers/promises'
import { test } from 'node:test'
import { testBrowserAudio } from '../../../assets/js/voice/device-test.ts'

class AudioNodeFixture {
  connected: AudioNodeFixture | null = null
  disconnected = false
  stopped = false
  gain = {
    value: 1,
    envelope: [] as number[],
    setValueAtTime(value: number) { this.value = value; this.envelope.push(value) },
    linearRampToValueAtTime(value: number) { this.value = value; this.envelope.push(value) }
  }
  frequency = { value: 0 }
  fftSize = 32
  type = ''
  peak = 0.25
  started = false
  connect(target: AudioNodeFixture) { this.connected = target; return target }
  disconnect() { this.disconnected = true }
  start() { this.started = true }
  stop() { this.stopped = true }
  getFloatTimeDomainData(samples: Float32Array) { samples.fill(this.peak) }
}

class ContextFixture {
  static current: ContextFixture
  state = 'running'
  currentTime = 1
  destination = new AudioNodeFixture()
  source: AudioNodeFixture | null = null
  gain: AudioNodeFixture | null = null
  analyser: AudioNodeFixture | null = null
  oscillator: AudioNodeFixture | null = null
  sink: string | null = null
  constructor() { ContextFixture.current = this }
  async resume() {}
  async setSinkId(value: string) { this.sink = value }
  async close() { this.state = 'closed' }
  createMediaStreamSource() { this.source = new AudioNodeFixture(); return this.source }
  createGain() { this.gain = new AudioNodeFixture(); return this.gain }
  createAnalyser() { this.analyser = new AudioNodeFixture(); return this.analyser }
  createOscillator() { this.oscillator = new AudioNodeFixture(); return this.oscillator }
}

function environment() {
  const track = Object.assign(new EventTarget(), { stopped: false, stop() { this.stopped = true } })
  const stream = { getTracks: () => [track], getAudioTracks: () => [track] }
  let constraints: unknown = null
  const media = {
    getUserMedia: async (value: unknown) => { constraints = value; return stream }
  }
  Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { mediaDevices: media } })
  Object.assign(globalThis, { window: { isSecureContext: true }, AudioContext: ContextFixture })
  return { track, stream, media, constraints: () => constraints }
}

test('microphone preview applies the draft gain and measures without monitoring or upload', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  const fixture = environment()
  const testing = testBrowserAudio('microphone', 'saved-mic', 150)
  await setImmediate()
  const context = ContextFixture.current
  assert.equal(context.gain?.gain.value, 1.5)
  assert.deepEqual(fixture.constraints(), { audio: {
    deviceId: { exact: 'saved-mic' }, channelCount: { ideal: 1 }, echoCancellation: true,
    noiseSuppression: true, autoGainControl: false
  } })
  assert.equal(context.source?.connected, context.gain)
  assert.equal(context.gain?.connected, context.analyser)
  assert.equal(context.analyser?.connected, null)
  assert.equal(context.oscillator, null)
  t.mock.timers.tick(2000)
  assert.deepEqual(await testing, { peak: 25 })
  assert.equal(fixture.track.stopped, true)
  assert.equal(context.state, 'closed')
})

test('speaker preview uses the selected sink and a bounded gentle tone', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  const fixture = environment()
  const testing = testBrowserAudio('speaker', 'saved-speaker', 200)
  await setImmediate()
  const context = ContextFixture.current
  assert.equal(context.sink, 'saved-speaker')
  assert.equal(context.oscillator?.started, true)
  assert.equal(context.source, null)
  assert.equal(fixture.constraints(), null)
  assert.equal(context.gain?.connected, context.destination)
  assert.equal(Math.max(...context.gain!.gain.envelope), 0.16)
  t.mock.timers.tick(600)
  assert.deepEqual(await testing, {})
  assert.equal(context.oscillator?.stopped, true)
  assert.equal(context.state, 'closed')
})

test('abort during capture or a speaker tone releases the active device immediately', async () => {
  for (const kind of ['microphone', 'speaker'] as const) {
    const fixture = environment()
    const controller = new AbortController()
    const testing = testBrowserAudio(kind, null, 100, controller.signal)
    await setImmediate()
    controller.abort()
    await assert.rejects(testing, { name: 'AbortError' })
    const context = ContextFixture.current
    assert.equal(context.state, 'closed')
    if (kind === 'microphone') assert.equal(fixture.track.stopped, true)
    else assert.equal(context.oscillator?.stopped, true)
  }
})

test('abort rejects promptly and stops tracks granted after the permission request was cancelled', async () => {
  const fixture = environment()
  let grant: (value: any) => void = () => {}
  fixture.media.getUserMedia = () => new Promise(resolve => { grant = resolve })
  const controller = new AbortController()
  const testing = testBrowserAudio('microphone', 'saved-mic', 100, controller.signal)
  await setImmediate()
  controller.abort()
  await assert.rejects(testing, { name: 'AbortError' })
  assert.equal(ContextFixture.current.state, 'closed')
  grant(fixture.stream)
  await setImmediate()
  assert.equal(fixture.track.stopped, true)
})

test('microphone removal and setup timeout release resources', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  const fixture = environment()
  const testing = testBrowserAudio('microphone', null, null)
  await setImmediate()
  fixture.track.dispatchEvent(new Event('ended'))
  await assert.rejects(testing, /input_device_disconnected/)
  assert.equal(fixture.track.stopped, true)
  assert.equal(ContextFixture.current.state, 'closed')

  fixture.media.getUserMedia = () => new Promise(() => {})
  const pending = testBrowserAudio('microphone', null, null)
  await setImmediate()
  t.mock.timers.tick(10000)
  await assert.rejects(pending, /audio_test_timeout/)
  assert.equal(ContextFixture.current.state, 'closed')
})

test('the system default speaker previews without custom sink selection', async t => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] })
  environment()
  const sink = ContextFixture.prototype.setSinkId
  Object.defineProperty(ContextFixture.prototype, 'setSinkId', { configurable: true, value: undefined })
  try {
    const testing = testBrowserAudio('speaker', 'default', 100)
    await setImmediate()
    t.mock.timers.tick(600)
    assert.deepEqual(await testing, {})
  } finally {
    Object.defineProperty(ContextFixture.prototype, 'setSinkId', { configurable: true, value: sink })
  }
})

test('unavailable selected speaker, permission denial, and invalid volume fail explicitly', async () => {
  const fixture = environment()
  Object.defineProperty(ContextFixture.prototype, 'setSinkId', { configurable: true, value: undefined })
  try {
    await assert.rejects(testBrowserAudio('speaker', 'saved-speaker', 100), /output_selection_unsupported/)
    assert.equal(ContextFixture.current.state, 'closed')
  } finally {
    Object.defineProperty(ContextFixture.prototype, 'setSinkId', { configurable: true, value: async function(value: string) { this.sink = value } })
  }
  fixture.media.getUserMedia = async () => { throw new DOMException('denied', 'NotAllowedError') }
  await assert.rejects(testBrowserAudio('microphone', null, 100), { name: 'NotAllowedError' })
  assert.equal(ContextFixture.current.state, 'closed')
  await assert.rejects(testBrowserAudio('speaker', null, 201), /invalid_audio_volume/)
  await assert.rejects(testBrowserAudio('speaker', null, Number.NaN), /invalid_audio_volume/)
  Object.assign(globalThis, { window: { isSecureContext: false } })
  await assert.rejects(testBrowserAudio('microphone', null, null), /microphone_requires_https_or_localhost/)
})

test('selected devices rejected by the browser retain their original error and close the context', async () => {
  const fixture = environment()
  fixture.media.getUserMedia = async () => { throw new DOMException('missing microphone', 'OverconstrainedError') }
  await assert.rejects(testBrowserAudio('microphone', 'missing', 100), { name: 'OverconstrainedError' })
  assert.equal(ContextFixture.current.state, 'closed')
  const previous = ContextFixture.prototype.setSinkId
  ContextFixture.prototype.setSinkId = async () => { throw new DOMException('missing speaker', 'NotFoundError') }
  try {
    await assert.rejects(testBrowserAudio('speaker', 'missing', 100), { name: 'NotFoundError' })
    assert.equal(ContextFixture.current.state, 'closed')
    assert.equal(ContextFixture.current.oscillator, null)
  } finally {
    ContextFixture.prototype.setSinkId = previous
  }
})
