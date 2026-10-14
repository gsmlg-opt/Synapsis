import assert from 'node:assert/strict'
import { test } from 'node:test'
import { createChatRequestId } from '../src/chat-request-id.ts'

const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

test('prefers the native UUID API when available', () => {
  assert.equal(createChatRequestId({ randomUUID: () => 'native-uuid' } as Crypto), 'native-uuid')
})

test('HTTP-compatible random values produce UUID v4 without randomUUID', () => {
  const crypto = { getRandomValues: (bytes: Uint8Array) => bytes.fill(255) } as Crypto
  const id = createChatRequestId(crypto)
  assert.match(id, uuidV4)
  assert.equal(id, 'ffffffff-ffff-4fff-bfff-ffffffffffff')
})

test('a browser without Crypto API can generate distinct valid request IDs', () => {
  const ids = Array.from({ length: 1000 }, () => createChatRequestId(null))
  ids.forEach(id => assert.match(id, uuidV4))
  assert.equal(new Set(ids).size, ids.length)
})
