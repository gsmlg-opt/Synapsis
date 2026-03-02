import { Socket, Channel } from "phoenix"

export type SessionEvent =
  | "text_delta"
  | "reasoning"
  | "tool_use"
  | "tool_result"
  | "permission_request"
  | "session_status"
  | "error"
  | "done"
  | "orchestrator_pause"
  | "orchestrator_escalate"
  | "orchestrator_terminate"
  | "agent_switched"

let socket: Socket | null = null
const channelCache = new Map<string, Channel>()

export function getSocket(): Socket {
  if (!socket) {
    socket = new Socket("/socket", {
      reconnectAfterMs: (tries: number) => {
        // Exponential backoff: 1s, 2s, 4s, 8s, 10s max
        return Math.min(1000 * Math.pow(2, tries - 1), 10000)
      },
    })
    socket.connect()
  }
  return socket
}

export function createSessionChannel(sessionId: string): Channel {
  // Reuse existing channel for the same session to prevent duplicate
  // event callbacks when the LiveView hook remounts.
  const existing = channelCache.get(sessionId)
  if (existing) {
    return existing
  }

  const s = getSocket()
  const channel = s.channel(`session:${sessionId}`, {})
  channelCache.set(sessionId, channel)
  return channel
}

export function removeSessionChannel(sessionId: string): void {
  channelCache.delete(sessionId)
}
