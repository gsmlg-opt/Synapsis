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

    // Orchestrator events
    channel.on("orchestrator_pause", (payload: any) => {
      store.dispatch({ type: "chat/setError", payload: `Paused: ${payload.reason}` })
    })
    channel.on("orchestrator_escalate", (payload: any) => {
      store.dispatch({ type: "chat/setStatus", payload: "streaming" })
    })
    channel.on("orchestrator_terminate", (payload: any) => {
      store.dispatch({ type: "chat/setError", payload: `Terminated: ${payload.reason}` })
    })
    channel.on("agent_switched", (payload: any) => {
      store.dispatch({ type: "session/setSession", payload: { agentMode: payload.agent } })
    })

    // Outbound: dispatched actions → channel.push
    return (next: Dispatch) => (action: AnyAction) => {
      const result = next(action)

      switch (action.type) {
        case "chat/sendMessage": {
          const payload = action.payload
          if (typeof payload === "string") {
            channel.push("session:message", { content: payload })
          } else {
            const msg: Record<string, any> = { content: payload.content }
            if (payload.images && payload.images.length > 0) {
              msg.images = payload.images.map((img: any) => ({
                media_type: img.media_type,
                data: img.data,
              }))
            }
            channel.push("session:message", msg)
          }
          break
        }
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
