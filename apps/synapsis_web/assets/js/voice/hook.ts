import { Socket } from 'phoenix'
import { BrowserAudioEndpoint, type PlaybackCursor } from './audio-endpoint'

type Device = { id: string; label: string }
type Devices = { inputs: Device[]; outputs: Device[]; output_selection?: boolean }
type Endpoint = {
  mode: 'host' | 'browser'
  input_device?: string
  output_device?: string
  input_volume?: number
  output_volume?: number
}
type Status = {
  phase: string
  owned?: boolean
  reason?: string
  generation?: string
  playback?: { played_ms: number | null }
  muted?: boolean
  manual?: boolean
  host?: string
  endpoint?: Endpoint
  endpoint_info?: {
    input_device?: string
    output_device?: string
    echo_cancellation?: boolean | string
    inputs?: Device[]
    outputs?: Device[]
  }
  tasks?: Array<{ agent_id: string; run_id: string; name: string; status: string; final?: unknown }>
}

type BrowserOpen = Endpoint & { generation: string }

function mount(root: HTMLElement) {
  const get = <T extends HTMLElement>(selector: string) => root.querySelector<T>(selector)!
  const status = get('[data-voice-status]')
  const failure = root.querySelector<HTMLElement>('[data-voice-error]')
  const playback = get('[data-voice-playback]')
  const tasks = get('[data-voice-tasks]')
  const mute = get<HTMLButtonElement>('[data-action=mute]')
  const commit = get<HTMLButtonElement>('[data-action=commit_audio]')
  const start = get<HTMLButtonElement>('[data-action=start]')
  const fork = root.querySelector<HTMLButtonElement>('[data-voice-fork]')
  const hangup = get<HTMLButtonElement>('[data-action=stop]')
  const stopPlayback = get<HTMLButtonElement>('[data-action=stop_playback]')
  const deviceIdentity = get('[data-voice-devices]')
  if (!failure) {
    status.textContent = 'Voice controls have changed. Reload this page to start a call.'
    start.disabled = true
    return
  }

  const errorNotice = failure
  const socket = new Socket('/socket', { transport: window.WebSocket })
  const channel = socket.channel('voice:' + root.dataset.session, { token: root.dataset.token })
  let browser: BrowserAudioEndpoint | null = null
  let generation: string | null = null
  let captureSeq = 0
  let capturePending = 0
  let pendingCursor: PlaybackCursor | null = null
  let owned = false
  let muted = false
  let browserDevices: Devices | undefined
  let previousTaskView = ''
  let latestStatus: Status = { phase: 'offline' }
  let connected = false

  function error(reason: string) {
    const messages: Record<string, string> = {
      voice_channel_disconnected: 'Connection lost. Reconnecting to the voice controls…',
      voice_channel_unavailable:
        'Voice controls are unavailable. Reload this session to reconnect.',
      media_owner_lost: 'The connection controlling this call ended. Start a new call to continue.',
      voice_runtime_failed: 'The voice runtime could not complete the reply.',
      voice_runtime_admission_failed: 'The voice runtime could not accept this turn.',
      voice_input_queue_full:
        'A microphone segment was skipped while the queue was full. Speak again after it clears.',
      voice_runtime_requires_recovery: fork
        ? 'A previous turn needs recovery. Continue in a copy of this chat.'
        : 'A previous turn in this Device Voice Agent conversation needs recovery before another call can start.',
      voice_runtime_check_timeout:
        'The session recovery check timed out. Start a call to try again.',
      realtime_protocol_error: 'The Realtime service rejected a voice request.',
      invalid_function_call: 'The model returned an invalid tool call. You can ask again.',
      realtime_duplicate_call_id: 'The model repeated a tool call. You can ask again.',
      realtime_response_failed:
        'The Realtime service could not produce the reply. Start a call to continue here.',
      realtime_response_timeout:
        'The Realtime service stopped responding. Start a call to continue here.',
      realtime_disconnected: 'The Realtime connection ended. Start a call to continue here.',
      realtime_policy_rejected:
        'The Realtime gateway rejected the call. Check the selected Backplane connection.',
      realtime_not_configured: 'Realtime is unavailable on the selected connection.',
      realtime_unauthorized: 'The Realtime connection needs authentication.',
      realtime_forbidden: 'The selected connection cannot access Realtime.',
      realtime_model_rejected: 'The Realtime service rejected the selected model.',
      realtime_setup_timeout: 'The Realtime service did not finish connecting in time.',
      audio_endpoint_timeout: 'The audio device did not finish opening in time.',
      audio_volume_unavailable: 'The selected audio device could not change its volume.',
      input_device_unavailable:
        'The selected microphone is unavailable. Select another microphone.',
      output_device_unavailable: 'The selected speaker is unavailable. Select another speaker.',
      host_audio_busy: 'The host audio devices are already in use by another call.',
      host_audio_exited: 'The host audio device connection ended.',
      media_lease_in_use: 'This call is controlled by another tab.',
      voice_operation_timed_out:
        'The voice operation timed out. Check the call state before retrying.',
      NotAllowedError: 'Microphone access was denied. Allow microphone access in your browser.',
      NotFoundError: 'No microphone is available on this browser device.'
    }
    errorNotice.textContent = messages[reason] || reason.replace(/_/g, ' ')
    errorNotice.hidden = false
  }

  function endpointIdentity(view: Status, active: boolean) {
    const endpoint = active ? view.endpoint : { mode: root.dataset.mode }
    const host = view.host || root.dataset.host || 'the Synapsis host'
    const name = endpoint?.mode === 'host' ? 'Host' : 'Web'
    const identity = name === 'Host' ? host : 'this device'
    if (!active || !view.endpoint_info) return name + ' audio on ' + identity + '.'
    const info = view.endpoint_info
    const label = (devices: Device[] | undefined, id?: string) =>
      devices?.find((device) => device.id === id)?.label || id || 'System default'
    const choices = name === 'Host' ? info : browserDevices
    const devices = [
      name + ' · ' + identity,
      'Microphone: ' + label(choices?.inputs, info.input_device),
      'Speaker: ' + label(choices?.outputs, info.output_device)
    ]
    if (info.echo_cancellation) devices.push('Echo cancellation enabled')
    return devices.join(' · ')
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
    connected = false
    statusUpdated({ phase: 'offline', reason: 'voice_channel_disconnected' })
  }

  function control(event: string, payload: object = {}, success?: (data: any) => void) {
    channel
      .push(event, payload, 15_000)
      .receive('ok', (data) => success?.(data))
      .receive('error', (data) => error(data.reason || 'voice_operation_failed'))
      .receive('timeout', () => error('voice_operation_timed_out'))
  }

  function statusUpdated(view: Status) {
    latestStatus = view
    const ended = view.phase === 'offline' || view.phase === 'error'
    owned = !ended && view.owned === true
    if (!owned) closeBrowser()
    const callActive = ['connecting', 'listening', 'responding', 'switching', 'ending'].includes(
      view.phase
    )
    const active = owned && callActive
    const ready = owned && ['listening', 'responding'].includes(view.phase)
    const phases: Record<string, string> = {
      offline: 'Ready to call',
      connecting: 'Connecting audio…',
      listening: view.playback ? 'Speaking' : view.muted ? 'Microphone muted' : 'Listening',
      responding: view.playback ? 'Speaking' : 'Preparing reply…',
      switching: 'Switching audio devices…',
      ending: 'Ending call…',
      error: 'Call stopped'
    }
    if (callActive && !owned) {
      status.textContent = 'Call controlled in another tab or process'
    } else {
      status.textContent =
        view.reason && ended ? 'Call stopped' : phases[view.phase] || 'Ready to call'
    }
    errorNotice.hidden = !view.reason
    errorNotice.textContent = ''
    if (view.reason) error(view.reason)
    root.dataset.active = String(active)
    root.dataset.ready = String(ready)
    const requiresRecovery = view.reason === 'voice_runtime_requires_recovery'
    start.disabled = !connected || callActive || requiresRecovery
    start.hidden = active || (requiresRecovery && !!fork)
    if (fork) fork.hidden = !requiresRecovery
    hangup.hidden = !active
    hangup.disabled = view.phase === 'ending'
    mute.hidden = !ready
    stopPlayback.hidden = !ready
    stopPlayback.disabled = !view.playback && view.phase !== 'responding'
    muted = view.muted === true
    mute.setAttribute('aria-pressed', String(muted))
    mute.textContent = muted ? 'Unmute microphone' : 'Mute microphone'
    commit.hidden = !ready || !view.manual
    commit.disabled = muted
    playback.textContent =
      active && view.playback
        ? typeof view.playback.played_ms === 'number'
          ? 'Playing audio · ' + (view.playback.played_ms / 1000).toFixed(1) + ' s played'
          : 'Playing audio · playback position unavailable'
        : ''
    playback.hidden = !playback.textContent
    deviceIdentity.textContent = endpointIdentity(view, active)
    renderTasks(view.tasks || [])
  }

  function renderTasks(entries: NonNullable<Status['tasks']>) {
    const serialized = JSON.stringify(entries)
    if (serialized === previousTaskView) return
    previousTaskView = serialized
    tasks.replaceChildren()
    tasks.hidden = entries.length === 0
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
        if (info.devices) browserDevices = info.devices as Devices
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
    next.setVolume('microphone', config.input_volume ?? 100)
    next.setVolume('speaker', config.output_volume ?? 100)
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
      connected = true
      statusUpdated(view)
    })
    .receive('error', (data) => error(data.reason || 'voice_channel_unavailable'))
    .receive('timeout', disconnected)

  root.onclick = (event) => {
    const element = (event.target as HTMLElement).closest<HTMLButtonElement>('[data-action]')
    const action = element?.dataset.action
    if (!action) return
    if (action === 'start') {
      statusUpdated({ ...latestStatus, phase: 'connecting', owned: true, reason: undefined })
      channel
        .push('start', { mode: root.dataset.mode || 'browser' }, 15_000)
        .receive('ok', statusUpdated)
        .receive('error', (data) => {
          owned = false
          statusUpdated({ phase: 'error', reason: data.reason || 'voice_operation_failed' })
        })
        .receive('timeout', () => {
          disconnected()
          socket.disconnect()
        })
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
