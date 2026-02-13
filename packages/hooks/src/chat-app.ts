import { createRoot, type Root } from "react-dom/client"
import { createElement } from "react"
import { ChatApp } from "@synapsis/ui"
import { createChatStore } from "@synapsis/ui/chat/store"
import { createSessionChannel, createChannelMiddleware } from "@synapsis/channel"
import { chatActions } from "@synapsis/ui/chat/store"
import type { Channel } from "phoenix"

interface ChatAppHookInstance {
  el: HTMLElement
  root: Root | null
  channel: Channel | null
  pushEvent: (event: string, payload: any) => void
}

export const ChatAppHook = {
  mounted(this: ChatAppHookInstance) {
    const sessionId = this.el.dataset.sessionId
    const agentMode = (this.el.dataset.agentMode || "build") as "build" | "plan"

    if (!sessionId) {
      console.error("ChatApp hook: missing data-session-id")
      return
    }

    const channel = createSessionChannel(sessionId)
    this.channel = channel

    const store = createChatStore({
      preloadedState: {
        session: { id: sessionId, agentMode, provider: "", model: "" },
      },
      middleware: [createChannelMiddleware(channel)],
    })

    channel
      .join()
      .receive("ok", (reply: any) => {
        store.dispatch(chatActions.hydrate(reply))
      })
      .receive("error", (err: any) => {
        console.error("Failed to join session channel:", err)
      })

    this.root = createRoot(this.el)
    this.root.render(
      createElement(ChatApp, {
        store,
        onNavigate: (path: string) => {
          this.pushEvent("navigate", { path })
        },
      })
    )
  },

  destroyed(this: ChatAppHookInstance) {
    this.channel?.leave()
    this.root?.unmount()
  },
}
