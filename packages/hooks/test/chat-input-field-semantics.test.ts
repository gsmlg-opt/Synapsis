import { expect, test } from "bun:test"
import {
  observeChatInputFieldSemantics,
  syncChatInputFieldSemantics,
} from "../src/chat-input-field-semantics"

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

  expect(fixture.currentTextarea().id).toBe("message-input-editor")
  expect(fixture.currentTextarea().attributes.get("name")).toBe("content")
})

test("reapplies field semantics when DuskMoon replaces the shadow subtree", () => {
  const fixture = fieldFixture()
  let mutationCallback = () => {}

  const observer = observeChatInputFieldSemantics(fixture.chatInput, (callback) => {
    mutationCallback = callback
    return { disconnect() {}, observe() {} }
  })

  expect(observer).not.toBeNull()

  fixture.replaceTextarea()
  mutationCallback()

  expect(fixture.currentTextarea().id).toBe("message-input-editor")
  expect(fixture.currentTextarea().attributes.get("name")).toBe("content")
})
