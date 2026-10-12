import assert from 'node:assert/strict'
import { test } from 'node:test'
import { MCPFormModalHook } from '../src/mcp-form-modal.ts'

function mount() {
  const dialog = new EventTarget() as any
  dialog.dataset = { closeEvent: 'hide_form' }
  dialog.open = false
  dialog.showModal = () => { dialog.open = true }
  dialog.close = () => { dialog.open = false; dialog.dispatchEvent(new Event('close')) }
  dialog.querySelector = () => ({ getBoundingClientRect: () => ({ left: 10, top: 10, right: 100, bottom: 100 }) })
  const events: string[] = []
  const hook = { ...MCPFormModalHook, el: dialog, pushEvent: (name: string) => events.push(name) }
  hook.mounted()
  return { dialog, hook, events }
}

test('Escape closes the modal and synchronizes server state once', () => {
  const { dialog, events } = mount()
  assert.equal(dialog.open, true)
  const cancel = new Event('cancel', { cancelable: true })
  dialog.dispatchEvent(cancel)
  assert.equal(cancel.defaultPrevented, true)
  assert.equal(dialog.open, false)
  assert.deepEqual(events, ['hide_form'])
})

test('only backdrop clicks close the form and listeners are removed on destroy', () => {
  const { dialog, hook, events } = mount()
  const click = (x: number, y: number) => {
    const event = new Event('click')
    Object.assign(event, { clientX: x, clientY: y })
    dialog.dispatchEvent(event)
  }
  click(50, 50)
  assert.equal(dialog.open, true)
  assert.deepEqual(events, [])
  click(0, 0)
  assert.deepEqual(events, ['hide_form'])
  hook.destroyed()
  dialog.dispatchEvent(new Event('cancel'))
  assert.deepEqual(events, ['hide_form'])
})

test('header close synchronizes server state without duplicate close events', () => {
  const { dialog, events } = mount()
  dialog.close()
  assert.deepEqual(events, ['hide_form'])
})
