import assert from "node:assert/strict"
import { test } from "node:test"
import {
  observeChatInputFieldSemantics,
  syncChatInputFieldSemantics,
} from "../src/chat-input-field-semantics.ts"

function fieldFixture() {
  let textarea = newTextarea()

  const markdownInput = {
    shadowRoot: {
      querySelector(selector: string) {
        return selector === "textarea" ? textarea : null
      },
    },
  }
  const chatInput = {
    id: "message-input",
    tagName: "EL-DM-CHAT-INPUT",
    getAttribute(name: string) {
      return name === "name" ? "content" : null
    },
    shadowRoot: {
      querySelector(selector: string) {
        return selector === "el-dm-markdown-input" ? markdownInput : null
      },
    },
  }

  return {
    chatInput: chatInput as unknown as HTMLElement,
    currentTextarea: () => textarea,
    replaceTextarea() {
      textarea = newTextarea()
    },
  }
}

function newTextarea() {
  const attributes = new Map<string, string>()

  return {
    id: "",
    attributes,
    setAttribute(name: string, value: string) {
      attributes.set(name, value)
    },
  }
}

test("copies chat input field semantics into the nested editor", () => {
  const fixture = fieldFixture()

  syncChatInputFieldSemantics(fixture.chatInput)

  assert.equal(fixture.currentTextarea().id, "message-input-editor")
  assert.equal(fixture.currentTextarea().attributes.get("name"), "content")
})

test("reapplies field semantics when DuskMoon replaces the shadow subtree", () => {
  const fixture = fieldFixture()
  let mutationCallback = () => {}

  const observer = observeChatInputFieldSemantics(fixture.chatInput, (callback) => {
    mutationCallback = callback
    return { disconnect() {}, observe() {} }
  })

  assert.notEqual(observer, null)

  fixture.replaceTextarea()
  mutationCallback()

  assert.equal(fixture.currentTextarea().id, "message-input-editor")
  assert.equal(fixture.currentTextarea().attributes.get("name"), "content")
})
