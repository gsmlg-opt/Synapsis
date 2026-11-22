import assert from 'node:assert/strict'
import { test } from 'node:test'
import { copyChatText } from '../src/chat-clipboard.ts'

const text = '复制这段文字 👀\n\n保留第二段'

function browser(writeText?: (value: string) => Promise<void>, allowsCopy = true) {
  const state = { copied: null as string | null, removed: false, focusRestored: false }
  let selection = ''
  const field = {
    value: '',
    style: {},
    focus() {},
    setSelectionRange(start: number, end: number) { selection = field.value.slice(start, end) },
    remove() { state.removed = true }
  }
  const page = {
    defaultView: { navigator: { clipboard: writeText && { writeText } } },
    activeElement: { focus() { state.focusRestored = true } },
    createElement: () => field,
    body: { append() {} },
    execCommand(command: string) {
      assert.equal(command, 'copy')
      if (allowsCopy) state.copied = selection
      return allowsCopy
    }
  } as unknown as Document

  return { page, state }
}

test('uses the Clipboard API when available', async () => {
  let result: string | undefined
  const { page, state } = browser(async (value) => { result = value })

  assert.equal(await copyChatText(text, page), true)
  assert.equal(result, text)
  assert.equal(state.copied, null)
})

test('copies multiline Unicode on HTTP without a Clipboard API and restores focus', async () => {
  const { page, state } = browser()

  assert.equal(await copyChatText(text, page), true)
  assert.deepEqual(state, { copied: text, removed: true, focusRestored: true })
})

test('tries the browser copy command when the Clipboard API rejects the write', async () => {
  const { page, state } = browser(async () => { throw new DOMException('Denied', 'NotAllowedError') })

  assert.equal(await copyChatText(text, page), true)
  assert.equal(state.copied, text)
})

test('reports a blocked copy and removes the temporary field', async () => {
  const { page, state } = browser(undefined, false)

  assert.equal(await copyChatText(text, page), false)
  assert.deepEqual(state, { copied: null, removed: true, focusRestored: true })
})
