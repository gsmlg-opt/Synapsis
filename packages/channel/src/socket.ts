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

let socket: Socket | null = null

export function getSocket(): Socket {
  if (!socket) {
    socket = new Socket("/socket", {})
    socket.connect()
  }
  return socket
}

export function createSessionChannel(sessionId: string): Channel {
  const s = getSocket()
  return s.channel(`session:${sessionId}`, {})
}
