import assert from 'node:assert/strict'
import { test } from 'node:test'
import { BrowserAudioEndpoint } from '../../../assets/js/voice/audio-endpoint.ts'

class NodeFixture {
  stopped = false
  port = { onmessage: null, postMessage: () => {}, close: () => {} }
  gain = { value: 1 }
  connect() {
    return this
  }
  disconnect() {}
  start() {}
  stop() {
    this.stopped = true
  }
}
class ContextFixture extends EventTarget {
  static current: ContextFixture
  sampleRate = 48000
  currentTime = 1
  heardTime = 1
  state = 'running'
  destination = new NodeFixture()
  audioWorklet = { addModule: async () => {} }
  nodes: NodeFixture[] = []
  constructor() {
    super()
    ContextFixture.current = this
  }
  createMediaStreamSource() {
    return new NodeFixture()
  }
  createGain() {
    return new NodeFixture()
  }
  createBuffer(_channels: number, count: number) {
    return { getChannelData: () => new Float32Array(count) }
  }
  createBufferSource() {
    const node = new NodeFixture()
    this.nodes.push(node)
    return node
  }
  getOutputTimestamp() {
    return { contextTime: this.heardTime, performanceTime: 100 }
  }
  async resume() {}
  async close() {
    this.state = 'closed'
  }
}

function environment() {
  const track = Object.assign(new EventTarget(), {
    stopped: false,
    enabled: true,
    stop() {
      this.stopped = true
    },
    getSettings() {
      return { deviceId: 'microphone', echoCancellation: true }
    }
  })
  const stream = { getTracks: () => [track], getAudioTracks: () => [track] }
  const media = Object.assign(new EventTarget(), {
    getUserMedia: async () => stream,
    enumerateDevices: async () => []
  })
  Object.defineProperty(globalThis, 'navigator', {
    value: { mediaDevices: media },
    configurable: true
  })
  Object.assign(globalThis, {
    window: Object.assign(new EventTarget(), {
      isSecureContext: true,
      location: { host: 'localhost' }
    }),
    AudioContext: ContextFixture,
    AudioWorkletNode: NodeFixture
  })
  return { track, media }
}

test('stop playback uses the device timestamp and releases every browser resource', async () => {
  const { track } = environment()
  const endpoint = new BrowserAudioEndpoint({ onCapture() {}, onError() {} })
  await endpoint.start()
  const identity = { response_id: 'response', item_id: 'item', content_index: 0 }
  endpoint.play(new Uint8Array(4800), identity)
  ContextFixture.current.heardTime = 1.07
  const cursor = endpoint.stopPlayback()
  assert.equal(cursor?.accurate, true)
  assert.ok(Math.abs(cursor!.audio_end_ms! - 50) <= 1)
  assert.equal(ContextFixture.current.nodes[0].stopped, true)
  assert.equal(endpoint.cursor(), null)
  endpoint.close()
  assert.equal(track.stopped, true)
  assert.equal(ContextFixture.current.state, 'closed')
})

test('closing while permission is pending stops the late microphone stream', async () => {
  const { track, media } = environment()
  let resolvePermission: (value: unknown) => void
  media.getUserMedia = () =>
    new Promise((resolve) => {
      resolvePermission = resolve
    }) as never
  const endpoint = new BrowserAudioEndpoint({ onCapture() {}, onError() {} })
  const opening = endpoint.start()
  endpoint.close()
  resolvePermission!({ getTracks: () => [track], getAudioTracks: () => [track] })
  await assert.rejects(opening, /endpoint_closed/)
  assert.equal(track.stopped, true)
})
