import type { Channel } from "phoenix"
import type { Middleware, Dispatch, AnyAction } from "@reduxjs/toolkit"

export function createChannelMiddleware(channel: Channel): Middleware {
  return (store) => {
    // Inbound: channel events → dispatch
    channel.on("text_delta", (payload: any) => {
      store.dispatch({ type: "chat/appendChunk", payload: { type: "text", ...payload } })
    })
    channel.on("reasoning", (payload: any) => {
      store.dispatch({ type: "chat/appendChunk", payload: { type: "thinking", ...payload } })
    })
    channel.on("tool_use", (payload: any) => {
      store.dispatch({ type: "chat/addToolCall", payload })
    })
    channel.on("tool_result", (payload: any) => {
      store.dispatch({ type: "chat/resolveToolCall", payload })
    })
    channel.on("permission_request", (payload: any) => {
      store.dispatch({ type: "chat/addPermissionRequest", payload })
    })
    channel.on("session_status", (payload: any) => {
      store.dispatch({ type: "chat/setStatus", payload: payload.status })
    })
    channel.on("error", (payload: any) => {
      store.dispatch({ type: "chat/setError", payload: payload.message })
    })
    channel.on("done", () => {
      store.dispatch({ type: "chat/completeTurn" })
    })

    // Outbound: dispatched actions → channel.push
    return (next: Dispatch) => (action: AnyAction) => {
      const result = next(action)

      switch (action.type) {
        case "chat/sendMessage":
          channel.push("session:message", { content: action.payload })
          break
        case "chat/approveToolCall":
          channel.push("session:tool_approve", { tool_use_id: action.payload })
          break
        case "chat/denyToolCall":
          channel.push("session:tool_deny", { tool_use_id: action.payload })
          break
        case "chat/cancel":
          channel.push("session:cancel", {})
          break
        case "ui/update":
          channel.push("ui_state", action.payload)
          break
      }

      return result
    }
  }
}
