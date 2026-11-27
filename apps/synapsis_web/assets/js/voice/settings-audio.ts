import { testBrowserAudio } from './device-test'
import { BrowserAudioEndpoint } from './audio-endpoint'

type Kind = 'microphone' | 'speaker'
type Reply = { status: string; request?: string; peak?: number; reason?: string }
type Devices = Record<'inputs' | 'outputs', Array<{ id: string; label: string }>>
type HostDevices = ({ status: 'ready' } & Devices) | { status: 'loading' | 'unavailable' }
type Hook = {
  el: HTMLElement
  handleEvent: <Payload>(event: string, callback: (reply: Payload) => void) => unknown
  pushEvent: (event: string, payload: object, callback: (reply: Reply) => void) => unknown
  cleanup?: () => void
  refreshBrowserOptions?: () => void
}

function errorMessage(reason?: string) {
  const messages: Record<string, string> = {
    host_agent_exists: 'Open the existing Device Voice Agent to test this server’s devices.',
    host_audio_busy: 'Hang up the active host audio call before testing a device.',
    device_muted: 'The selected device is muted in the host audio settings.',
    audio_volume_unavailable: 'Could not apply the draft volume.',
    audio_volume_restore_failed: 'Could not restore the host device volume after testing.',
    input_device_unavailable: 'The selected microphone is unavailable.',
    output_device_unavailable: 'The selected speaker is unavailable.',
    output_selection_unsupported: 'This browser cannot select a speaker. Use the system default.',
    microphone_requires_https_or_localhost: 'Use HTTPS or localhost to test a browser device.',
    browser_audio_unavailable: 'Use HTTPS or localhost to test a browser device.',
    NotAllowedError: 'Allow microphone access to test your browser microphone.',
    NotFoundError: 'The selected browser device is unavailable.',
    audio_test_timeout: 'The audio device did not open in time.'
  }
  return (reason && messages[reason]) || 'Could not test the selected audio device.'
}

export const VoiceAudioTest = {
  mounted(this: Hook) {
    const editor = this.el.closest<HTMLElement>('[data-agent-editor]')
    if (!editor) return
    const buttons = () => editor.querySelectorAll<HTMLButtonElement>('[data-voice-test]')
    const cardFor = (mode: string, kind: Kind) =>
      editor
        .querySelector(`[data-voice-audio-profile=${mode}] [data-voice-test=${kind}]`)
        ?.closest<HTMLElement>('[data-voice-device-card]')
    let pending: { request: string; mode: string; kind: Kind } | null = null
    let controller: AbortController | null = null
    let timer: ReturnType<typeof setTimeout> | undefined
    let discovering = false
    let destroyed = false
    let discoveryGeneration = 0
    let browserDevices: Devices | undefined

    const renderDevices = (mode: 'host' | 'browser', devices: Devices) => {
      const selector = `[data-voice-audio-profile=${mode}] [data-voice-device-list]`
      for (const select of editor.querySelectorAll<HTMLSelectElement>(selector)) {
        const key = select.dataset.voiceDeviceList as keyof Devices
        const selected =
          mode === 'browser' && key === 'outputs' && select.value === 'default' ? '' : select.value
        const choices = devices[key].filter(
          ({ id }) => id && (mode !== 'browser' || id !== 'default')
        )
        const defaultId =
          mode === 'browser' && key === 'inputs' && selected === 'default' ? selected : ''
        const options = [
          new Option('System default', defaultId),
          ...choices.map(({ id, label }) => new Option(label, id))
        ]
        if (selected && !options.some(({ value }) => value === selected)) {
          const label =
            mode === 'host' || choices.length ? 'Saved device (unavailable)' : 'Saved device'
          options.push(new Option(label, selected))
        }
        select.replaceChildren(...options)
        select.value = selected
      }
    }

    const refreshDevices = async () => {
      const generation = ++discoveryGeneration
      const devices = await BrowserAudioEndpoint.devices()
      if (destroyed || generation !== discoveryGeneration) return
      browserDevices = devices
      renderDevices('browser', devices)
    }

    // The React form keeps its controls during LiveView patches.
    this.handleEvent<HostDevices>('voice_host_devices', (devices) => {
      const status = editor.querySelector<HTMLElement>('[data-host-device-status]')
      if (status) {
        status.dataset.state = devices.status === 'unavailable' ? 'error' : ''
        status.textContent =
          devices.status === 'loading'
            ? 'Discovering host devices…'
            : devices.status === 'unavailable'
              ? 'Could not load host audio devices.'
              : ''
      }
      if (devices.status === 'ready') renderDevices('host', devices)
    })

    const discoverDevices = async () => {
      if (discovering) return
      discovering = true
      const notice = editor.querySelector<HTMLElement>('[data-browser-device-status]')
      if (notice) notice.textContent = 'Discovering browser devices…'
      let stream: MediaStream | undefined
      try {
        if (!navigator.mediaDevices?.getUserMedia)
          throw new Error('microphone_requires_https_or_localhost')
        stream = await navigator.mediaDevices.getUserMedia({ audio: true })
        if (destroyed) return
        await refreshDevices()
        if (notice) notice.textContent = ''
      } catch (error) {
        const reason =
          error instanceof DOMException
            ? error.name
            : error instanceof Error
              ? error.message
              : undefined
        if (notice)
          notice.textContent =
            reason === 'NotAllowedError'
              ? 'Allow microphone access to discover browser devices.'
              : errorMessage(reason)
      } finally {
        stream?.getTracks().forEach((track) => track.stop())
        discovering = false
      }
    }

    const updateVolume = (range: HTMLInputElement, useDefault: boolean) => {
      const card = range.closest('[data-voice-device-card]')!
      const value = card.querySelector<HTMLInputElement>('[data-voice-volume-value]')!
      const current = card.querySelector<HTMLElement>('[data-voice-volume-current]')!
      const reset = card.querySelector<HTMLElement>('[data-voice-volume-reset]')!
      if (useDefault) range.value = '100'
      value.value = useDefault ? '' : range.value
      current.textContent = useDefault ? 'Default' : range.value + '%'
      reset.hidden = useDefault
      if (useDefault) value.dispatchEvent(new Event('input', { bubbles: true }))
    }

    const onVolumeInput = (event: Event) => {
      const range = event.target as HTMLInputElement
      if (range.matches('[data-voice-volume-range]')) updateVolume(range, false)
    }
    const onDevicesChanged = () => {
      void refreshDevices().catch(() => {})
    }

    const finish = (reply: Reply) => {
      if (pending === null || reply.request !== pending.request) return
      const card = cardFor(pending.mode, pending.kind)
      const status = card?.querySelector<HTMLElement>('[data-voice-test-status]')
      pending = null
      controller = null
      clearTimeout(timer)
      buttons().forEach((button) => {
        button.disabled = false
      })
      if (!status) return
      if (reply.status === 'error') {
        status.dataset.state = 'error'
        status.textContent = errorMessage(reply.reason)
      } else if (typeof reply.peak === 'number') {
        const bar = card?.querySelector<HTMLProgressElement>('[data-voice-test-meter]')
        if (bar) {
          bar.value = reply.peak
          bar.hidden = false
        }
        status.textContent = `Microphone peak: ${reply.peak}%`
      } else {
        status.textContent = 'Speaker test tone played.'
      }
    }

    this.handleEvent('voice_audio_test_result', finish)
    const onClick = (event: MouseEvent) => {
      const button = (event.target as HTMLElement).closest<HTMLButtonElement>('button')
      if (!button || button.disabled) return
      if (button.matches('[data-voice-discover-browser]')) {
        void discoverDevices()
        return
      }
      const card = button.closest<HTMLElement>('[data-voice-device-card]')
      if (!card) return
      if (button.matches('[data-voice-volume-reset]')) {
        const range = card.querySelector<HTMLInputElement>('[data-voice-volume-range]')
        if (range) updateVolume(range, true)
        return
      }
      if (!button.matches('[data-voice-test]') || pending !== null) return
      const kind = button.dataset.voiceTest as Kind
      const status = card.querySelector<HTMLElement>('[data-voice-test-status]')
      const mode = card.closest<HTMLElement>('[data-voice-audio-profile]')?.dataset
        .voiceAudioProfile
      if (!mode || !status) return
      const device = card.querySelector<HTMLSelectElement>('[data-voice-device]')?.value || null
      const setting = card.querySelector<HTMLInputElement>('[data-voice-volume-value]')?.value
      const volume = setting ? Number(setting) : null
      const host = mode === 'host'
      const bar = card.querySelector<HTMLProgressElement>('[data-voice-test-meter]')
      if (bar) bar.hidden = true
      if (
        volume !== null &&
        (!Number.isInteger(volume) || volume < 0 || volume > (host ? 150 : 200))
      ) {
        status.dataset.state = 'error'
        status.textContent = 'Enter a valid volume to test this device.'
        return
      }

      const request = String(Date.now()) + '-' + String(Math.random()).slice(2)
      pending = { request, mode, kind }
      buttons().forEach((control) => {
        control.disabled = true
      })
      delete status.dataset.state
      status.textContent =
        kind === 'microphone' ? 'Speak now to test the microphone…' : 'Playing a test tone…'
      timer = setTimeout(() => {
        controller?.abort()
        finish({ request, status: 'error' })
      }, 18_000)

      if (host) {
        this.pushEvent('test_voice_audio', { request, kind, device, volume }, (reply) => {
          if (reply.status === 'error') finish({ ...reply, request })
        })
      } else {
        controller = new AbortController()
        void testBrowserAudio(kind, device, volume, controller.signal)
          .then((result) => {
            finish({ ...result, request, status: 'ok' })
          })
          .catch((error: unknown) => {
            const reason =
              error instanceof DOMException
                ? error.name
                : error instanceof Error
                  ? error.message
                  : undefined
            finish({ request, status: 'error', reason })
          })
      }
    }
    editor.addEventListener('click', onClick)
    editor.addEventListener('input', onVolumeInput)
    navigator.mediaDevices?.addEventListener('devicechange', onDevicesChanged)
    this.refreshBrowserOptions = () => {
      if (destroyed || this.el.dataset.activeTab !== 'audio') return
      if (browserDevices) renderDevices('browser', browserDevices)
      else onDevicesChanged()
    }
    this.refreshBrowserOptions()

    this.cleanup = () => {
      destroyed = true
      pending = null
      clearTimeout(timer)
      controller?.abort()
      editor.removeEventListener('click', onClick)
      editor.removeEventListener('input', onVolumeInput)
      navigator.mediaDevices?.removeEventListener('devicechange', onDevicesChanged)
    }
  },

  updated(this: Hook) {
    queueMicrotask(() => this.refreshBrowserOptions?.())
  },

  destroyed(this: Hook) {
    this.cleanup?.()
  }
}
