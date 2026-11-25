import { PCM24Encoder } from './pcm.ts'

export type AudioIdentity = {
  response_id: string
  item_id: string
  content_index: number
}
export type PlaybackCursor = AudioIdentity & {
  audio_end_ms: number | null
  accurate: boolean
}
export type VolumeDevice = 'microphone' | 'speaker'

export type BrowserAudioOptions = {
  inputDevice?: string | null
  outputDevice?: string | null
  onCapture: (pcm: Uint8Array) => void
  onCursor?: (cursor: PlaybackCursor | null) => void
  onState?: (state: Record<string, unknown>) => void
  onError: (reason: string) => void
}

type SinkAudioContext = AudioContext & {
  setSinkId?: (id: string) => Promise<void>
}
type Segment = AudioIdentity & {
  start: number
  end: number
  offsetSamples: number
  samples: number
  source: AudioBufferSourceNode
}

const PCM_SAMPLE_RATE = 24_000
const MAX_QUEUED_PLAYBACK_SECONDS = 15

// Capture runs outside rendering and the UI event loop. It maintains filter state
// between device blocks and posts 20 ms PCM16 frames at the protocol sample rate.
const captureProcessor = `
const PCM24Encoder = ${PCM24Encoder.toString()}
class VoiceCapture extends AudioWorkletProcessor {
  constructor() {
    super()
    this.encoder = new PCM24Encoder(sampleRate)
    this.frame = new Int16Array(480)
    this.index = 0
    this.muted = false
    this.port.onmessage = event => {
      this.muted = event.data.muted
      this.encoder = new PCM24Encoder(sampleRate)
      this.frame = new Int16Array(480)
      this.index = 0
    }
  }
  process(inputs) {
    const channels = inputs[0]
    if (this.muted || !channels || !channels.length) return true
    const mono = new Float32Array(channels[0].length)
    for (const channel of channels) {
      for (let index = 0; index < channel.length; index++) mono[index] += channel[index] / channels.length
    }
    for (const sample of this.encoder.encode(mono)) {
      this.frame[this.index++] = sample
      if (this.index === this.frame.length) {
        if (!this.muted) this.port.postMessage(this.frame.buffer, [this.frame.buffer])
        this.frame = new Int16Array(480)
        this.index = 0
      }
    }
    return true
  }
}
registerProcessor('synapsis-voice-capture', VoiceCapture)
`

/** Browser-only device owner. Constructing this object never requests permission. */
export class BrowserAudioEndpoint {
  declare private context: SinkAudioContext | null
  declare private stream: MediaStream | null
  declare private capture: AudioWorkletNode | null
  declare private source: MediaStreamAudioSourceNode | null
  declare private microphoneGain: GainNode | null
  declare private speakerGain: GainNode | null
  declare private silent: GainNode | null
  declare private segments: Segment[]
  declare private nextStart: number
  declare private cursorTimer: ReturnType<typeof setInterval> | null
  declare private closed: boolean
  declare private opening: boolean
  declare private readonly onPageHide: () => void
  declare private readonly onDeviceChange: () => void
  declare private readonly options: BrowserAudioOptions
  declare private readonly volumes: Record<VolumeDevice, number>

  // WORKAROUND(upstream): duskmoon-dev/duskmoon-bundler#46
  // Keep ES2020 constructor assignments until dev assets serve generated field helpers.
  constructor(options: BrowserAudioOptions) {
    this.options = options
    this.context = null
    this.stream = null
    this.capture = null
    this.source = null
    this.microphoneGain = null
    this.speakerGain = null
    this.silent = null
    this.segments = []
    this.nextStart = 0
    this.cursorTimer = null
    this.closed = false
    this.opening = false
    this.volumes = { microphone: 100, speaker: 100 }
    this.onPageHide = () => this.close()
    this.onDeviceChange = () => {
      void BrowserAudioEndpoint.devices()
        .then((devices) => this.options.onState?.({ devices }))
        .catch(() => this.fail('device_enumeration_failed'))
    }
  }

  static async devices() {
    if (!navigator.mediaDevices?.enumerateDevices) throw new Error('browser_audio_unavailable')
    const devices = await navigator.mediaDevices.enumerateDevices()
    const outputSelection =
      typeof AudioContext !== 'undefined' && 'setSinkId' in AudioContext.prototype
    return {
      endpoint: 'browser',
      host: window.location.host,
      inputs: devices
        .filter((device) => device.kind === 'audioinput')
        .map((device) => ({
          id: device.deviceId,
          label: device.label || 'Microphone'
        })),
      outputs: outputSelection
        ? devices
            .filter((device) => device.kind === 'audiooutput')
            .map((device) => ({
              id: device.deviceId,
              label: device.label || 'Speaker'
            }))
        : [{ id: '', label: 'System default' }],
      output_selection: outputSelection
    }
  }

  async start(): Promise<void> {
    if (this.opening || this.context || this.closed) throw new Error('endpoint_already_started')
    if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
      throw new Error('microphone_requires_https_or_localhost')
    }
    this.opening = true
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          deviceId: this.options.inputDevice ? { exact: this.options.inputDevice } : undefined,
          channelCount: { ideal: 1 },
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true
        }
      })
      if (this.closed) {
        stream.getTracks().forEach((track) => track.stop())
        throw new Error('endpoint_closed')
      }
      this.stream = stream
      const context = new AudioContext({ latencyHint: 'interactive' }) as SinkAudioContext
      this.context = context
      if (context.sampleRate < 24000) throw new Error('unsupported_sample_rate')
      if (this.options.outputDevice && this.options.outputDevice !== 'default') {
        if (!context.setSinkId) throw new Error('output_selection_unsupported')
        await context.setSinkId(this.options.outputDevice)
      }
      const moduleURL = URL.createObjectURL(
        new Blob([captureProcessor], { type: 'text/javascript' })
      )
      try {
        await context.audioWorklet.addModule(moduleURL)
      } finally {
        URL.revokeObjectURL(moduleURL)
      }
      if (this.closed) throw new Error('endpoint_closed')
      this.capture = new AudioWorkletNode(context, 'synapsis-voice-capture')
      this.capture.port.onmessage = (event) => {
        if (!this.closed) this.options.onCapture(new Uint8Array(event.data as ArrayBuffer))
      }
      this.source = context.createMediaStreamSource(stream)
      this.microphoneGain = context.createGain()
      this.microphoneGain.gain.value = this.volumes.microphone / 100
      this.speakerGain = context.createGain()
      this.speakerGain.gain.value = this.volumes.speaker / 100
      this.speakerGain.connect(context.destination)
      this.silent = context.createGain()
      this.silent.gain.value = 0
      this.source.connect(this.microphoneGain).connect(this.capture).connect(this.silent).connect(context.destination)
      stream.getAudioTracks().forEach((track) => {
        track.addEventListener('ended', () => {
          if (!this.closed) this.fail('input_device_disconnected')
        })
      })
      context.addEventListener('statechange', () => {
        if (!this.closed && context.state === 'suspended') this.fail('audio_context_suspended')
      })
      await context.resume()
      navigator.mediaDevices.addEventListener('devicechange', this.onDeviceChange)
      window.addEventListener('pagehide', this.onPageHide)
      this.cursorTimer = setInterval(() => this.options.onCursor?.(this.cursor()), 50)
      this.options.onState?.({
        status: 'ready',
        endpoint: 'browser',
        input_device: stream.getAudioTracks()[0]?.getSettings().deviceId,
        output_device: this.options.outputDevice || 'default',
        echo_cancellation: stream.getAudioTracks()[0]?.getSettings().echoCancellation === true,
        sample_rate: 24000,
        devices: await BrowserAudioEndpoint.devices(),
        accurate_playback_cursor: typeof context.getOutputTimestamp === 'function'
      })
    } catch (error) {
      this.close()
      throw error
    } finally {
      this.opening = false
    }
  }

  mute(muted: boolean) {
    if (!this.capture || !this.stream) throw new Error('endpoint_not_ready')
    this.capture.port.postMessage({ muted })
    this.stream.getAudioTracks().forEach((track) => {
      track.enabled = !muted
    })
    this.options.onState?.({ muted })
  }

  setVolume(device: VolumeDevice, percent: number) {
    if (!Number.isInteger(percent) || percent < 0 || percent > 200) return
    this.volumes[device] = percent
    const node = device === 'microphone' ? this.microphoneGain : this.speakerGain
    if (node) node.gain.value = percent / 100
  }

  play(pcm: Uint8Array, identity: AudioIdentity) {
    const context = this.context
    if (!context || !this.speakerGain || this.closed) throw new Error('endpoint_not_ready')
    if (
      !pcm.byteLength ||
      pcm.byteLength % 2 ||
      pcm.byteLength > 96000 ||
      !identity.response_id ||
      !identity.item_id ||
      !Number.isInteger(identity.content_index) ||
      identity.content_index < 0
    )
      throw new Error('invalid_audio')
    const samples = pcm.byteLength / 2
    const duration = samples / PCM_SAMPLE_RATE
    const start = Math.max(this.nextStart, context.currentTime + 0.02)
    if (start + duration - context.currentTime > MAX_QUEUED_PLAYBACK_SECONDS) {
      this.fail('playback_queue_overflow')
      throw new Error('playback_queue_overflow')
    }
    const buffer = context.createBuffer(1, samples, PCM_SAMPLE_RATE)
    const target = buffer.getChannelData(0)
    const view = new DataView(pcm.buffer, pcm.byteOffset, pcm.byteLength)
    for (let index = 0; index < samples; index++)
      target[index] = view.getInt16(index * 2, true) / 32768
    const source = context.createBufferSource()
    source.buffer = buffer
    source.connect(this.speakerGain)
    const previous = this.segments[this.segments.length - 1]
    const sameItem =
      previous?.response_id === identity.response_id &&
      previous?.item_id === identity.item_id &&
      previous?.content_index === identity.content_index
    const offsetSamples = sameItem ? previous.offsetSamples + previous.samples : 0
    this.segments.push({ ...identity, start, end: start + duration, offsetSamples, samples, source })
    source.onended = () => source.disconnect()
    source.start(start)
    this.nextStart = start + duration
  }

  cursor(): PlaybackCursor | null {
    const context = this.context
    if (!context || !this.segments.length) return null
    const timestamp = context.getOutputTimestamp?.()
    const accurate =
      !!timestamp && typeof timestamp.contextTime === 'number' && timestamp.performanceTime! > 0
    const heard = accurate ? timestamp!.contextTime! : 0
    while (this.segments.length > 1 && heard >= this.segments[1].start) this.segments.shift()
    const current = this.segments[0]
    const elapsedSamples = heard >= current.end
      ? current.samples
      : Math.max(0, Math.floor((heard - current.start) * PCM_SAMPLE_RATE))
    return {
      response_id: current.response_id,
      item_id: current.item_id,
      content_index: current.content_index,
      audio_end_ms: accurate ? Math.floor((current.offsetSamples + elapsedSamples) * 1000 / PCM_SAMPLE_RATE) : null,
      accurate
    }
  }

  stopPlayback(): PlaybackCursor | null {
    const cursor = this.cursor()
    for (const segment of this.segments) {
      segment.source.stop()
      segment.source.disconnect()
    }
    this.segments = []
    this.nextStart = 0
    return cursor
  }

  close() {
    if (this.closed) return
    this.closed = true
    this.stopPlayback()
    if (this.cursorTimer) clearInterval(this.cursorTimer)
    this.cursorTimer = null
    this.capture?.port.close()
    this.capture?.disconnect()
    this.source?.disconnect()
    this.microphoneGain?.disconnect()
    this.speakerGain?.disconnect()
    this.silent?.disconnect()
    this.stream?.getTracks().forEach((track) => track.stop())
    void this.context?.close()
    this.context = null
    this.stream = null
    navigator.mediaDevices?.removeEventListener('devicechange', this.onDeviceChange)
    window.removeEventListener('pagehide', this.onPageHide)
  }

  private fail(reason: string) {
    this.close()
    this.options.onError(reason)
  }
}
