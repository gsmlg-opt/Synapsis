import assert from 'node:assert/strict'
import { test } from 'node:test'
import { snapshotNativeFields, restoreNativeFields } from '../src/react-form-native.ts'

test('snapshots nested typed fields and complete checkbox selections', () => {
  const fields = [
    { name: 'agent[max_tokens]', type: 'number', value: '0' },
    { name: 'agent[enabled]', type: 'hidden', value: 'false' },
    { name: 'agent[enabled]', type: 'checkbox', value: 'true', checked: false },
    { name: 'tool_names[]', type: 'hidden', value: '' },
    { name: 'tool_names[]', type: 'checkbox', value: 'file.read', checked: true },
    { name: 'tool_names[]', type: 'checkbox', value: 'file.write', checked: false },
    { name: 'tool_names[]', type: 'hidden', value: 'mcp.hidden' },
  ]
  assert.deepEqual(snapshotNativeFields(fields, { agent: { label: 'React draft' } }), {
    agent: { label: 'React draft', max_tokens: 0, enabled: false },
    tool_names: ['file.read', 'mcp.hidden'],
  })
  fields[3].value = ''
  fields[4].checked = false
  fields.pop()
  assert.deepEqual(snapshotNativeFields(fields).tool_names, [])
})

test('reads current hidden model values and skips disabled controls', () => {
  const field = { name: 'agent[provider]', type: 'hidden', value: 'first' }
  assert.deepEqual(snapshotNativeFields([field]), { agent: { provider: 'first' } })
  field.value = 'replacement'
  assert.deepEqual(snapshotNativeFields([field, { name: 'ignored', type: 'text', value: 'secret', disabled: true }]), {
    agent: { provider: 'replacement' },
  })
})

test('native reset restores groups, singleton booleans and multiselect', () => {
  const fields = [
    { name: 'tools[]', type: 'checkbox', value: 'read', checked: false },
    { name: 'tools[]', type: 'checkbox', value: 'write', checked: true },
    { name: 'enabled', type: 'checkbox', value: 'true', checked: true },
    { name: 'role', type: 'radio', value: 'admin', checked: true },
    { name: 'role', type: 'radio', value: 'user', checked: false },
    { name: 'tags', type: 'select-multiple', value: '', multiple: true, options: [
      { value: 'a', selected: false }, { value: 'b', selected: true },
    ] },
  ]
  restoreNativeFields(fields, { tools: ['read'], enabled: 'false', role: 'user', tags: ['a'] })
  assert.equal(fields[0].checked, true)
  assert.equal(fields[1].checked, false)
  assert.equal(fields[2].checked, false)
  assert.equal(fields[3].checked, false)
  assert.equal(fields[4].checked, true)
  assert.deepEqual(fields[5].options?.map(option => option.selected), [true, false])
})

test('empty numeric fields stay null and unchecked radios do not overwrite the selection', () => {
  assert.deepEqual(snapshotNativeFields([
    { name: 'amount', type: 'number', value: '' },
    { name: 'role', type: 'radio', value: 'admin', checked: true },
    { name: 'role', type: 'radio', value: 'user', checked: false },
  ]), { amount: null, role: 'admin' })
})
