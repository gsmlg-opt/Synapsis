import React from "react"
import { createRoot, Root } from "react-dom/client"
import { ChatView } from "../components/ChatView"
import { getSession } from "../lib/api"
import type { Message } from "../lib/api"

interface HookEl extends HTMLElement {
  dataset: DOMStringMap & { sessionId?: string }
}

interface HookThis {
  el: HookEl
  _root?: Root
  mounted(): void
  destroyed(): void
}

export const ChatViewHook: ThisType<HookThis> & Pick<HookThis, "mounted" | "destroyed"> = {
  mounted() {
    const sessionId = this.el.dataset.sessionId
    if (!sessionId) return

    const root = createRoot(this.el)
    this._root = root

    getSession(sessionId)
      .then((data: { messages?: Message[] }) => {
        root.render(<ChatView sessionId={sessionId} initialMessages={data.messages || []} />)
      })
      .catch(() => {
        root.render(<ChatView sessionId={sessionId} initialMessages={[]} />)
      })
  },

  destroyed() {
    this._root?.unmount()
  },
}
