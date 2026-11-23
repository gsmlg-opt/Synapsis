import assert from 'node:assert/strict'
import { test } from 'node:test'
import { PCM24Encoder } from '../../../assets/js/voice/pcm.ts'

test('48 kHz input is filtered to 24 kHz across arbitrary frame boundaries', () => {
  const encoder = new PCM24Encoder(48000)
  assert.deepEqual([...encoder.encode(Float32Array.from([1, -1, 0.5]))], [0])
  assert.deepEqual([...encoder.encode(Float32Array.from([0.5, -1, -1]))], [16384, -32768])
})

test('fractional input rate maintains the sample clock', () => {
  const encoder = new PCM24Encoder(44100)
  let samples = 0
  for (let frame = 0; frame < 100; frame++) samples += encoder.encode(new Float32Array(441)).length
  assert.equal(samples, 24000)
})
