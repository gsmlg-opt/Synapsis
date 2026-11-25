import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { stripTypeScriptTypes } from 'node:module'
import { test } from 'node:test'
import { runInNewContext } from 'node:vm'

class ElementFixture {
  textContent = ''
  hidden = false
  disabled = false
  value = ''
  onchange?: () => void
  dataset: Record<string, string> = {}
  attributes = new Map<string, string>()
  options: Array<{ text: string; value: string }> = []
  children: ElementFixture[] = []
  setAttribute(name: string, value: string) { this.attributes.set(name, value) }
  replaceChildren(...children: ElementFixture[]) { this.children = children }
  append(...children: ElementFixture[]) { this.children.push(...children) }
}

function environment({ staleMarkup = false } = {}) {
  const elements = new Map<string, ElementFixture>()
  for (const name of ['status', 'error', 'playback', 'tasks', 'devices']) elements.set(`[data-voice-${name}]`, new ElementFixture())
  for (const name of ['mute', 'commit_audio', 'start', 'stop', 'switch', 'stop_playback']) elements.set(`[data-action=${name}]`, new ElementFixture())
  if (staleMarkup) elements.delete('[data-voice-error]')
  const element = (selector: string) => elements.get(selector)!
  const picker = new ElementFixture()
  picker.value = 'host'
  elements.set('[data-voice-endpoint]', picker)

  const handlers = new Map<string, (data: any) => void>()
  const pushes: Array<{ event: string; payload: object; replies: Map<string, (data: any) => void> }> = []
  let disconnected: () => void = () => {}
  const channel = {
    on(event: string, callback: (data: any) => void) { handlers.set(event, callback) },
    onError(callback: () => void) { disconnected = callback },
    onClose() {},
    push(event: string, payload: object) {
      const entry = { event, payload, replies: new Map<string, (data: any) => void>() }
      pushes.push(entry)
      const reply = { receive(name: string, callback: (data: any) => void) { entry.replies.set(name, callback); return reply } }
      return reply
    },
    join() {
      const reply = { receive(name: string, callback: (data: any) => void) { if (name === 'ok') callback({ phase: 'offline' }); return reply } }
      return reply
    }
  }
  class SocketFixture {
    channel() { return channel }
    connect() {}
    disconnect() {}
  }
  const root = {
    dataset: { session: 'session', token: 'token', mode: 'host', host: 'audio-host', active: 'false', ready: 'false' },
    querySelector: element,
    onclick: null as any
  }
  const source = readFileSync(new URL('../../../assets/js/voice/hook.ts', import.meta.url), 'utf8')
    .replace(/^import .*\n/gm, '')
    .replace(/^export const (\w+)/gm, 'globalThis.$1')
  const context: any = {
    Socket: SocketFixture,
    BrowserAudioEndpoint: class {},
    window: { WebSocket: class {} },
    navigator: {},
    TextEncoder,
    TextDecoder,
    Option: class {
      text: string
      value: string
      constructor(text: string, value: string) { this.text = text; this.value = value }
    },
    document: { createElement: () => new ElementFixture() }
  }
  runInNewContext(stripTypeScriptTypes(source), context)
  const hook = { el: root }
  context.VoiceControls.mounted.call(hook)
  const update = (status: object) => handlers.get('status')!(status)
  const start = () => {
    root.onclick({ target: { closest: () => ({ dataset: { action: 'start' } }) } })
    return pushes.findLast(push => push.event === 'start')!
  }
  return { root, element, update, start, handlers, picker, pushes, disconnected: () => disconnected() }
}

const endpoint = {
  owned: true,
  endpoint: { mode: 'host' },
  host: 'audio-host',
  endpoint_info: {
    input_device: 'mic', output_device: 'speaker', echo_cancellation: 'webrtc_reference',
    inputs: [{ id: 'mic', label: 'K66 microphone' }],
    outputs: [{ id: 'speaker', label: 'USB speaker' }]
  }
}

test('stale voice controls request a reload without joining the channel', () => {
  const { element, handlers } = environment({ staleMarkup: true })
  assert.equal(element('[data-action=start]').disabled, true)
  assert.match(element('[data-voice-status]').textContent, /Reload this page/)
  assert.equal(handlers.size, 0)
})

test('the session selection controls startup and switches a running call', () => {
  const { picker, start, update, pushes, element } = environment()
  picker.value = 'browser'
  picker.onchange!()
  assert.match(element('[data-voice-devices]').textContent, /Web audio/)
  assert.equal(Reflect.get(start().payload, 'mode'), 'browser')
  update({ phase: 'listening', owned: true, endpoint: { mode: 'browser' } })

  picker.value = 'host'
  picker.onchange!()
  assert.equal(picker.disabled, true)
  assert.equal(pushes.at(-1)?.event, 'switch')
  assert.equal(Reflect.get(pushes.at(-1)!.payload, 'mode'), 'host')
  update({ phase: 'listening', ...endpoint })
  assert.equal(picker.value, 'host')
  assert.equal(picker.disabled, false)
})

test('a rejected Realtime policy is reported as a gateway failure', () => {
  const { element, update, start } = environment()
  start().replies.get('ok')!({ phase: 'connecting', owned: true })
  update({ phase: 'error', reason: 'realtime_policy_rejected' })
  assert.match(element('[data-voice-error]').textContent, /Realtime gateway rejected/)
  assert.equal(element('[data-action=start]').disabled, false)
})

test('voice call controls clear active devices and playback after a failed reply', () => {
  const { root, element, update, start } = environment()
  assert.equal(element('[data-action=start]').disabled, false)
  start().replies.get('ok')!({ phase: 'listening', ...endpoint })
  assert.equal(root.dataset.ready, 'true')
  assert.match(element('[data-voice-devices]').textContent, /K66 microphone.*USB speaker.*Echo cancellation enabled/)

  update({ phase: 'responding', ...endpoint, playback: { played_ms: 500 } })
  assert.equal(element('[data-action=stop_playback]').disabled, false)
  update({ phase: 'error', reason: 'voice_runtime_failed', ...endpoint, playback: { played_ms: 500 } })

  assert.equal(root.dataset.active, 'false')
  assert.equal(root.dataset.ready, 'false')
  assert.equal(element('[data-voice-devices]').textContent, 'Host audio on audio-host.')
  assert.equal(element('[data-voice-playback]').hidden, true)
  assert.equal(element('[data-action=stop]').hidden, true)
  assert.equal(element('[data-action=start]').disabled, false)
  assert.equal(element('[data-action=start]').hidden, false)
  assert.equal(element('[data-voice-status]').textContent, 'Call stopped')
  assert.equal(element('[data-voice-error]').textContent, 'The voice runtime could not complete the reply.')
})

test('playback remains stoppable after response generation completes', () => {
  const { element, update, start, handlers } = environment()
  start().replies.get('ok')!({ phase: 'listening', ...endpoint })
  update({ phase: 'listening', ...endpoint, playback: { played_ms: 800 }, manual: true })
  assert.equal(element('[data-voice-status]').textContent, 'Speaking')
  assert.equal(element('[data-action=stop_playback]').disabled, false)
  assert.equal(element('[data-action=commit_audio]').hidden, false)
  assert.equal(handlers.has('transcript'), false)
})

test('lost control connection clears media presentation and disables call startup', () => {
  const { root, element, start, disconnected } = environment()
  start().replies.get('ok')!({ phase: 'listening', ...endpoint })
  disconnected()
  assert.equal(root.dataset.active, 'false')
  assert.equal(element('[data-action=start]').disabled, true)
  assert.equal(element('[data-action=stop]').hidden, true)
  assert.equal(element('[data-voice-devices]').textContent, 'Host audio on audio-host.')
  assert.match(element('[data-voice-error]').textContent, /Connection lost/)
})

test('the server restores call controls when an older offline status followed the start reply', () => {
  const { root, element, update, start } = environment()
  start().replies.get('ok')!({ phase: 'connecting', owned: true })
  update({ phase: 'offline', owned: false })
  update({ phase: 'listening', owned: true, ...endpoint })

  assert.equal(root.dataset.ready, 'true')
  assert.equal(element('[data-action=stop]').hidden, false)
  assert.match(element('[data-voice-devices]').textContent, /K66 microphone/)
})

test('a status for a call in another tab keeps start disabled and hides hangup', () => {
  const { element, update } = environment()
  update({ phase: 'listening', ...endpoint, owned: false })

  assert.match(element('[data-voice-status]').textContent, /another tab/)
  assert.equal(element('[data-action=start]').disabled, true)
  assert.equal(element('[data-action=stop]').hidden, true)
})
