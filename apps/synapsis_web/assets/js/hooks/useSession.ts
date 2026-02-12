import { useState, useEffect, useCallback, useRef } from "react";
import { Channel } from "phoenix";
import { joinSession, type SessionEvent } from "../lib/socket";
import type { Message, MessagePart } from "../lib/api";

interface StreamingState {
  text: string;
  reasoning: string;
  toolUses: Array<{ tool: string; tool_use_id: string; input?: Record<string, unknown> }>;
}

export function useSession(sessionId: string | null) {
  const [messages, setMessages] = useState<Message[]>([]);
  const [status, setStatus] = useState<string>("idle");
  const [streaming, setStreaming] = useState<StreamingState>({
    text: "",
    reasoning: "",
    toolUses: [],
  });
  const [pendingPermissions, setPendingPermissions] = useState<
    Array<{ tool: string; tool_use_id: string; input: Record<string, unknown> }>
  >([]);
  const [error, setError] = useState<string | null>(null);
  const channelRef = useRef<Channel | null>(null);

  useEffect(() => {
    if (!sessionId) return;

    const channel = joinSession(sessionId);
    channelRef.current = channel;

    channel.on("text_delta", (payload: { text: string }) => {
      setStreaming((prev) => ({ ...prev, text: prev.text + payload.text }));
    });

    channel.on("reasoning", (payload: { text: string }) => {
      setStreaming((prev) => ({ ...prev, reasoning: prev.reasoning + payload.text }));
    });

    channel.on("tool_use", (payload: { tool: string; tool_use_id: string }) => {
      setStreaming((prev) => ({
        ...prev,
        toolUses: [...prev.toolUses, { tool: payload.tool, tool_use_id: payload.tool_use_id }],
      }));
    });

    channel.on("tool_result", (payload: { tool_use_id: string; content: string; is_error: boolean }) => {
      const part: MessagePart = {
        type: "tool_result",
        tool_use_id: payload.tool_use_id,
        content: payload.content,
        is_error: payload.is_error,
      };
      setMessages((prev) => [
        ...prev,
        { id: crypto.randomUUID(), role: "user", parts: [part], token_count: 0, inserted_at: new Date().toISOString() },
      ]);
    });

    channel.on("permission_request", (payload: { tool: string; tool_use_id: string; input: Record<string, unknown> }) => {
      setPendingPermissions((prev) => [...prev, payload]);
    });

    channel.on("session_status", (payload: { status: string }) => {
      setStatus(payload.status);
      if (payload.status === "idle") {
        flushStreaming();
      }
    });

    channel.on("error", (payload: { message: string }) => {
      setError(payload.message);
    });

    channel.on("done", () => {
      flushStreaming();
    });

    channel.join().receive("ok", () => {
      setError(null);
    });

    return () => {
      channel.leave();
      channelRef.current = null;
    };
  }, [sessionId]);

  const flushStreaming = useCallback(() => {
    setStreaming((prev) => {
      if (prev.text || prev.reasoning || prev.toolUses.length > 0) {
        const parts: MessagePart[] = [];
        if (prev.reasoning) parts.push({ type: "reasoning", content: prev.reasoning });
        if (prev.text) parts.push({ type: "text", content: prev.text });
        prev.toolUses.forEach((tu) =>
          parts.push({ type: "tool_use", tool: tu.tool, tool_use_id: tu.tool_use_id, input: tu.input })
        );

        setMessages((msgs) => [
          ...msgs,
          {
            id: crypto.randomUUID(),
            role: "assistant",
            parts,
            token_count: 0,
            inserted_at: new Date().toISOString(),
          },
        ]);
      }
      return { text: "", reasoning: "", toolUses: [] };
    });
  }, []);

  const sendMessage = useCallback(
    (content: string) => {
      if (!channelRef.current) return;

      setMessages((prev) => [
        ...prev,
        {
          id: crypto.randomUUID(),
          role: "user",
          parts: [{ type: "text", content }],
          token_count: 0,
          inserted_at: new Date().toISOString(),
        },
      ]);

      channelRef.current.push("session:message", { content });
    },
    []
  );

  const cancel = useCallback(() => {
    channelRef.current?.push("session:cancel", {});
  }, []);

  const approveTool = useCallback((toolUseId: string) => {
    channelRef.current?.push("session:tool_approve", { tool_use_id: toolUseId });
    setPendingPermissions((prev) => prev.filter((p) => p.tool_use_id !== toolUseId));
  }, []);

  const denyTool = useCallback((toolUseId: string) => {
    channelRef.current?.push("session:tool_deny", { tool_use_id: toolUseId });
    setPendingPermissions((prev) => prev.filter((p) => p.tool_use_id !== toolUseId));
  }, []);

  return {
    messages,
    setMessages,
    status,
    streaming,
    pendingPermissions,
    error,
    sendMessage,
    cancel,
    approveTool,
    denyTool,
  };
}
