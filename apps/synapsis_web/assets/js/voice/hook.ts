import { Socket } from 'phoenix'
import { BrowserAudioEndpoint, type PlaybackCursor } from './audio-endpoint'

type Device = { id: string; label: string }
type Devices = { inputs: Device[]; outputs: Device[]; host?: string; output_selection?: boolean }
type Endpoint = { mode: 'host' | 'browser'; input_device?: string; output_device?: string }
type Status = {
  phase: string
  reason?: string
  generation?: string
  caption?: string
  playback?: { played_ms: number | null }
  muted?: boolean
  manual?: boolean
  host?: string
  endpoint?: Endpoint
  endpoint_info?: {
    input_device?: string
    output_device?: string
    echo_cancellation?: boolean | string
  }
  tasks?: Array<{ agent_id: string; run_id: string; name: string; status: string; final?: unknown }>
}

type BrowserOpen = Endpoint & { generation: string }

function mount(root: HTMLElement) {
  const get = <T extends HTMLElement>(selector: string) => root.querySelector<T>(selector)!
  const mode = get<HTMLSelectElement>('[name=mode]')
  const input = get<HTMLSelectElement>('[name=input_device]')
  const output = get<HTMLSelectElement>('[name=output_device]')
  const status = get('[data-voice-status]')
  const caption = get('[data-voice-caption]')
  const transcript = get('[data-voice-transcript]')
  const playback = get('[data-voice-playback]')
  const tasks = get('[data-voice-tasks]')
  const mute = get<HTMLButtonElement>('[data-action=mute]')
  const commit = get<HTMLButtonElement>('[data-action=commit_audio]')
  const start = get<HTMLButtonElement>('[data-action=start]')
  const deviceIdentity = get('[data-voice-devices]')
  const socket = new Socket('/socket', { transport: window.WebSocket })
  const channel = socket.channel('voice:' + root.dataset.session, { token: root.dataset.token })
  let browser: BrowserAudioEndpoint | null = null
  let generation: string | null = null
  let captureSeq = 0
  let capturePending = 0
  let pendingCursor: PlaybackCursor | null = null
  let owned = false
  let muted = false
  let deviceRequest = 0
  let previousTaskView = ''

  function error(reason: string) {
    status.textContent = reason.replace(/_/g, ' ')
  }

  function closeBrowser() {
    generation = null
    browser?.close()
    browser = null
    pendingCursor = null
  }

  function disconnected() {
    closeBrowser()
    owned = false
    root.dataset.active = 'false'
    start.disabled = true
    error('voice_channel_disconnected')
  }

  function control(event: string, payload: object = {}, success?: (data: any) => void) {
    channel
      .push(event, payload, 15_000)
      .receive('ok', (data) => success?.(data))
      .receive('error', (data) => error(data.reason || 'voice_operation_failed'))
      .receive('timeout', () => error('voice_operation_timed_out'))
  }

  function statusUpdated(view: Status) {
    const phases: Record<string, string> = {
      offline: 'Call ended',
      connecting: 'Connecting audio',
      listening: 'Listening',
      responding: 'Responding',
      switching: 'Switching audio devices',
      ending: 'Ending call',
      error: 'Call ended'
    }
    status.textContent = phases[view.phase] || 'Call ready'
    if (view.reason) status.textContent += ' · ' + view.reason.replace(/_/g, ' ')
    if (view.phase === 'offline' || view.phase === 'error') owned = false
    const active =
      owned && ['connecting', 'listening', 'responding', 'switching', 'ending'].includes(view.phase)
    root.dataset.active = String(active)
    root.dataset.ready = String(owned && ['listening', 'responding'].includes(view.phase))
    start.disabled = active
    muted = view.muted === true
    mute.setAttribute('aria-pressed', String(view.muted === true))
    mute.textContent = view.muted ? 'Unmute microphone' : 'Mute microphone'
    commit.hidden = !view.manual
    caption.textContent = view.caption || ''
    playback.textContent = view.playback
      ? typeof view.playback.played_ms === 'number'
        ? 'Playing audio · ' + (view.playback.played_ms / 1000).toFixed(1) + ' s played'
        : 'Playing audio · playback position unavailable'
      : ''
    if (view.endpoint_info && view.endpoint) {
      const info = view.endpoint_info
      const identity =
        view.endpoint.mode === 'host' ? view.host : navigator.platform || 'This device'
      const echo = info.echo_cancellation
        ? 'Echo cancellation active'
        : 'Echo cancellation unavailable'
      const name = view.endpoint.mode === 'host' ? 'Host' : 'Browser'
      const devices = [
        info.input_device
          ? 'Microphone: ' + (input.selectedOptions[0]?.text || info.input_device)
          : '',
        info.output_device
          ? 'Speaker: ' + (output.selectedOptions[0]?.text || info.output_device)
          : ''
      ].filter(Boolean)
      deviceIdentity.textContent = [name, identity, ...devices, echo].join(' · ')
    }
    renderTasks(view.tasks || [])
  }

  function renderTasks(entries: NonNullable<Status['tasks']>) {
    const serialized = JSON.stringify(entries)
    if (serialized === previousTaskView) return
    previousTaskView = serialized
    tasks.replaceChildren()
    for (const task of entries) {
      const entry = document.createElement('li')
      const name = document.createElement('span')
      name.textContent = task.name + ' · ' + task.status.replace(/_/g, ' ')
      entry.append(name)
      if (task.status === 'running') {
        const cancel = document.createElement('button')
        cancel.className = 'btn btn-sm btn-ghost'
        cancel.type = 'button'
        cancel.textContent = 'Cancel task'
        cancel.setAttribute('aria-label', 'Cancel task ' + task.name)
        cancel.onclick = () =>
          control('cancel_task', { agent_id: task.agent_id, run_id: task.run_id })
        entry.append(cancel)
      }
      if (task.final) {
        const result = document.createElement('p')
        result.textContent =
          typeof task.final === 'string'
            ? task.final
            : Array.isArray(task.final)
              ? task.final.map((block) => block.text || '').join('\n')
              : ''
        entry.append(result)
      }
      tasks.append(entry)
    }
  }

  function populate(select: HTMLSelectElement, list: Device[], preference?: string) {
    const current = select.value || preference || ''
    select.replaceChildren(new Option('System default', ''))
    for (const device of list) {
      if (device.id) select.add(new Option(device.label, device.id))
    }
    if (current && !Array.from(select.options).some((option) => option.value === current)) {
      select.add(new Option('Saved device', current))
    }
    select.value = current
  }

  function showDevices(devices: Devices) {
    const savedMode = mode.value === root.dataset.mode
    populate(input, devices.inputs || [], savedMode ? root.dataset.input : undefined)
    populate(output, devices.outputs || [], savedMode ? root.dataset.output : undefined)
    output.disabled = mode.value === 'browser' && devices.output_selection !== true
    if (output.disabled) output.value = ''
  }

  function refreshDevices() {
    const selected = mode.value
    const request = ++deviceRequest
    const show = (devices: Devices) => {
      if (mode.value === selected && deviceRequest === request) showDevices(devices)
    }
    if (selected === 'host') {
      control('host_devices', {}, show)
    } else {
      void BrowserAudioEndpoint.devices()
        .then(show)
        .catch((reason) => error(reason.message))
    }
  }

  function capture(id: string, frame: Uint8Array) {
    if (generation !== id || capturePending >= 12) {
      if (generation === id) browserError(id, 'browser_capture_backpressure')
      return
    }
    const buffer = new ArrayBuffer(40 + frame.byteLength)
    const bytes = new Uint8Array(buffer)
    bytes.set(new TextEncoder().encode(id), 0)
    new DataView(buffer).setUint32(36, ++captureSeq)
    bytes.set(frame, 40)
    capturePending += 1
    channel
      .push('pcm', buffer, 3_000)
      .receive('ok', () => {
        if (generation === id) capturePending -= 1
      })
      .receive('error', (data) => browserError(id, data.reason))
      .receive('timeout', () => browserError(id, 'browser_capture_timeout'))
  }

  function browserError(id: string, reason: string) {
    if (generation !== id) return
    closeBrowser()
    channel.push('browser_error', { generation: id, reason })
    error(reason)
  }

  channel.on('status', statusUpdated)
  channel.on('browser_open', async (config: BrowserOpen) => {
    closeBrowser()
    const id = config.generation
    generation = id
    captureSeq = 0
    capturePending = 0
    let ready = false
    const next = new BrowserAudioEndpoint({
      inputDevice: config.input_device,
      outputDevice: config.output_device,
      onCapture: (frame) => {
        if (ready) capture(id, frame)
      },
      onCursor: (position) => {
        if (generation === id && position) channel.push('cursor', { generation: id, position })
      },
      onState: (info) => {
        if (generation !== id) return
        if (mode.value === 'browser' && info.devices) showDevices(info.devices as Devices)
        if (info.status === 'ready') {
          control(
            'browser_ready',
            {
              generation: id,
              info: {
                input_device: info.input_device,
                output_device: info.output_device,
                echo_cancellation: info.echo_cancellation,
                output_selection: (info.devices as Devices)?.output_selection
              }
            },
            () => {
              ready = true
            }
          )
        }
      },
      onError: (reason) => browserError(id, reason)
    })
    browser = next
    try {
      await next.start()
    } catch (reason) {
      const message =
        reason instanceof DOMException
          ? reason.name
          : reason instanceof Error
            ? reason.message
            : 'browser_audio_failed'
      browserError(id, message)
    }
  })
  channel.on('browser_close', (data) => {
    if (generation === data.generation) closeBrowser()
  })
  channel.on('flush', (data) => {
    if (!browser || generation !== data.generation) return
    const position = browser.stopPlayback() || pendingCursor
    pendingCursor = null
    if (data.release) closeBrowser()
    channel.push('flushed', { generation: data.generation, token: data.token, position })
  })
  channel.on('transcript', (data) => {
    transcript.textContent = data.transcript
  })
  channel.on('pcm', (frame: ArrayBuffer) => {
    if (!(frame instanceof ArrayBuffer) || frame.byteLength < 4) return
    const length = new DataView(frame).getUint16(0)
    if (!length || length + 2 >= frame.byteLength) return
    const header = JSON.parse(new TextDecoder().decode(new Uint8Array(frame, 2, length)))
    if (!browser || generation !== header.generation) return
    try {
      browser.play(new Uint8Array(frame, 2 + length), header)
      channel.push('playback_ack', { generation, seq: header.seq })
    } catch (reason) {
      browserError(
        header.generation,
        reason instanceof Error ? reason.message : 'browser_playback_failed'
      )
    }
  })
  channel.onError(disconnected)
  channel.onClose(disconnected)
  socket.connect()
  channel
    .join()
    .receive('ok', (view: Status) => {
      statusUpdated(view)
      refreshDevices()
    })
    .receive('error', (data) => error(data.reason || 'voice_channel_unavailable'))
    .receive('timeout', disconnected)

  mode.onchange = () => {
    input.replaceChildren(new Option('System default', ''))
    output.replaceChildren(new Option('System default', ''))
    refreshDevices()
  }

  root.onclick = (event) => {
    const element = (event.target as HTMLElement).closest<HTMLButtonElement>('[data-action]')
    const action = element?.dataset.action
    if (!action) return
    const endpoint = { mode: mode.value, input_device: input.value, output_device: output.value }
    if (action === 'start') {
      start.disabled = true
      owned = true
      channel
        .push('start', endpoint, 15_000)
        .receive('ok', statusUpdated)
        .receive('error', (data) => {
          owned = false
          start.disabled = false
          error(data.reason)
        })
        .receive('timeout', () => {
          disconnected()
          socket.disconnect()
        })
    } else if (action === 'devices') {
      refreshDevices()
    } else if (action === 'switch') {
      control('switch', endpoint)
    } else if (action === 'mute') {
      const next = !muted
      control('mute', { muted: next }, () => {
        muted = next
        browser?.mute(next)
      })
    } else {
      if (action === 'stop_playback' || action === 'stop') {
        pendingCursor = browser?.stopPlayback() || pendingCursor
      }
      control(action)
    }
  }

  return () => {
    closeBrowser()
    socket.disconnect()
    root.onclick = null
    mode.onchange = null
  }
}

export const VoiceControls = {
  mounted(this: { el: HTMLElement; cleanup?: () => void }) {
    this.cleanup = mount(this.el)
  },
  destroyed(this: { cleanup?: () => void }) {
    this.cleanup?.()
  }
}
