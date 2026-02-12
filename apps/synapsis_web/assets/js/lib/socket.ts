import { Socket, Channel } from "phoenix";

const SOCKET_URL = `${window.location.protocol === "https:" ? "wss" : "ws"}://${window.location.host}/socket`;

let socket: Socket | null = null;

export function getSocket(): Socket {
  if (!socket) {
    socket = new Socket(SOCKET_URL, {});
    socket.connect();
  }
  return socket;
}

export function joinSession(sessionId: string): Channel {
  const socket = getSocket();
  const channel = socket.channel(`session:${sessionId}`, {});
  return channel;
}

export type SessionEvent =
  | { type: "text_delta"; text: string }
  | { type: "tool_use"; tool: string; tool_use_id: string }
  | { type: "tool_result"; tool_use_id: string; content: string; is_error: boolean }
  | { type: "permission_request"; tool: string; tool_use_id: string; input: Record<string, unknown> }
  | { type: "reasoning"; text: string }
  | { type: "session_status"; status: string }
  | { type: "error"; message: string }
  | { type: "done" };
