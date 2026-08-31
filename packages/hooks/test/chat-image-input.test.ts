import assert from "node:assert/strict"
import { test } from "node:test"
const hookModule = import("../src/chat-image-input.ts").catch(() => ({}))

type Hook = {
  mounted(this: HookContext): void
  destroyed(this: HookContext): void
}

type HookContext = {
  el: FakeChatInput
  pushEvent(event: string, payload: unknown): void
  handleEvent(event: string, callback: () => void): void
  observeFieldSemantics: () => { disconnect(): void }
  fieldSemanticsObserver?: { disconnect(): void }
  sendListener?: (event: SendEvent) => void
  encodingImages?: boolean
}

type SendEvent = {
  detail: {
    value: string
    files: Array<{
      name: string
      type: string
      arrayBuffer(): Promise<ArrayBuffer>
    }>
  }
}

class FakeChatInput {
  tagName = "EL-DM-CHAT-INPUT"
  listeners = new Map<string, (event: SendEvent) => void>()
  valueChanges: string[] = []
  clearFilesCalls = 0

  addEventListener(event: string, listener: (event: SendEvent) => void) {
    this.listeners.set(event, listener)
  }

  removeEventListener(event: string, listener: (event: SendEvent) => void) {
    if (this.listeners.get(event) === listener) this.listeners.delete(event)
  }

  setValue(value: string) {
    this.valueChanges.push(value)
  }

  clearFiles() {
    this.clearFilesCalls += 1
  }
}

async function chatImageHook(): Promise<Hook> {
  const module = await hookModule
  const hook = (module as { ChatImageInputHook?: Hook }).ChatImageInputHook
  assert.ok(hook, "ChatImageInputHook must be exported")
  return hook
}

async function fixture() {
  const el = new FakeChatInput()
  const pushed: Array<{ event: string; payload: unknown }> = []
  const handled = new Map<string, () => void>()
  let disconnectCalls = 0

  const context: HookContext = {
    el,
    pushEvent(event, payload) {
      pushed.push({ event, payload })
    },
    handleEvent(event, callback) {
      handled.set(event, callback)
    },
    observeFieldSemantics() {
      return {
        disconnect() {
          disconnectCalls += 1
        },
      }
    },
  }

  const hook = await chatImageHook()
  hook.mounted.call(context)

  return {
    context,
    el,
    pushed,
    handled,
    disconnectCalls: () => disconnectCalls,
    async send(value: string, files: SendEvent["detail"]["files"]) {
      const listener = el.listeners.get("send")
      assert.ok(listener, "send listener must be installed")
      listener({ detail: { value, files } })
      await new Promise((resolve) => setTimeout(resolve, 0))
    },
  }
}

function file(name: string, type: string, bytes: number[]) {
  return {
    name,
    type,
    async arrayBuffer() {
      return Uint8Array.from(bytes).buffer
    },
  }
}

test("chat image hook sends selected files as Base64 JSON", async () => {
  const testFixture = await fixture()

  await testFixture.send("describe", [file("pixel.png", "image/png", [0x89, 0x50, 0x4e, 0x47])])

  assert.deepEqual(testFixture.pushed, [
    {
      event: "send_message",
      payload: {
        value: "describe",
        images: [{ name: "pixel.png", media_type: "image/png", data: "iVBORw==" }],
      },
    },
  ])
  assert.deepEqual(testFixture.el.valueChanges, [])
  assert.equal(testFixture.el.clearFilesCalls, 0)
})

test("chat image hook supports image-only JSON messages", async () => {
  const testFixture = await fixture()

  await testFixture.send("", [file("pixel.png", "image/png", [0x89, 0x50, 0x4e, 0x47])])

  assert.deepEqual(testFixture.pushed[0], {
    event: "send_message",
    payload: {
      value: "",
      images: [{ name: "pixel.png", media_type: "image/png", data: "iVBORw==" }],
    },
  })
})

test("chat image hook clears text and files only after server acceptance", async () => {
  const testFixture = await fixture()

  await testFixture.send("describe", [file("pixel.png", "image/png", [0x89, 0x50, 0x4e, 0x47])])

  assert.deepEqual(testFixture.el.valueChanges, [])
  assert.equal(testFixture.el.clearFilesCalls, 0)

  const clear = testFixture.handled.get("clear_chat_input")
  assert.ok(clear, "clear_chat_input handler must be registered")
  clear()

  assert.deepEqual(testFixture.el.valueChanges, [""])
  assert.equal(testFixture.el.clearFilesCalls, 1)
})

test("chat image hook retains input and reports a safe file read failure", async () => {
  const testFixture = await fixture()
  const unreadable = {
    name: "secret.png",
    type: "image/png",
    async arrayBuffer(): Promise<ArrayBuffer> {
      throw new Error("private browser detail")
    },
  }

  await testFixture.send("describe", [unreadable])

  assert.deepEqual(testFixture.pushed, [{ event: "image_attachment_error", payload: {} }])
  assert.deepEqual(testFixture.el.valueChanges, [])
  assert.equal(testFixture.el.clearFilesCalls, 0)
})

test("chat image hook removes listeners and disconnects semantics observation", async () => {
  const testFixture = await fixture()
  const listener = testFixture.el.listeners.get("send")
  assert.ok(listener)

  const hook = await chatImageHook()
  hook.destroyed.call(testFixture.context)

  assert.equal(testFixture.el.listeners.has("send"), false)
  assert.equal(testFixture.disconnectCalls(), 1)
})
