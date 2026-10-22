import assert from 'node:assert/strict'
import { test } from 'node:test'
import { initialSelection, AgentModelPickerHook, AgentBackupModelPickerHook } from '../src/agent-model-picker.ts'

const configured = [{ value: 'provider', label: 'Provider', children: [{ value: 'enabled', label: 'Enabled' }] }]

test('a configured saved pair stays selected', () => {
  assert.deepEqual(initialSelection(configured, 'provider', 'enabled'), { provider: 'provider', model: 'enabled' })
})

test('a disabled or deleted saved model is preserved until an explicit replacement', () => {
  assert.deepEqual(initialSelection(configured, 'provider', 'disabled'), { provider: 'provider', model: 'disabled' })
})

test('an unavailable provider preserves the complete saved pair', () => {
  assert.deepEqual(initialSelection(configured, 'removed-provider', 'custom/model'), { provider: 'removed-provider', model: 'custom/model' })
})

test('a new agent starts with no implicit model choice', () => {
  assert.deepEqual(initialSelection(configured, '', ''), { provider: '', model: '' })
})

for (const [name, definition] of [['default', AgentModelPickerHook], ['backup', AgentBackupModelPickerHook]] as const) {
  test(`${name} picker refreshes options for the same agent without remounting`, () => {
    let renders = 0
    const hook: any = { ...definition, el: { dataset: { agentId: 'same-agent', options: '[]' } }, handleEvent() {}, renderPicker() { renders += 1 } }
    hook.mounted()
    hook.el.dataset.options = JSON.stringify(configured)
    hook.updated()
    assert.equal(renders, 2)
    hook.updated()
    assert.equal(renders, 2)
  })
}

for (const [name, definition] of [['default', AgentModelPickerHook], ['backup', AgentBackupModelPickerHook]] as const) {
  test(`${name} picker receives options while its enclosing form ignores DOM updates`, () => {
    let receive: ((payload: any) => void) | undefined
    let renders = 0
    const hook: any = { ...definition, el: { dataset: { agentId: 'same-agent', options: '[]' } }, handleEvent(event: string, callback: (payload: any) => void) { assert.equal(event, 'agent:model-options'); receive = callback }, renderPicker() { renders += 1 } }
    hook.mounted()
    assert.ok(receive)
    receive({ options: configured })
    assert.deepEqual(JSON.parse(hook.el.dataset.options), configured)
    assert.equal(renders, 2)
    receive({ options: configured })
    assert.equal(renders, 2)
  })
}
