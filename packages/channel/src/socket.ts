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
  const s = getSocket()
  return s.channel(`session:${sessionId}`, {})
}
