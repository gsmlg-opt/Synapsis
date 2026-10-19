import assert from 'node:assert/strict'
import { test } from 'node:test'
import { initialSelection } from '../src/agent-model-picker.ts'

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
