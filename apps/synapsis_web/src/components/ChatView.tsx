import { useState, useRef, useEffect } from "react";
import { useSession } from "../hooks/useSession";
import { MessageBubble } from "./MessageBubble";
import { ToolPermission } from "./ToolPermission";
import type { Message } from "../lib/api";

interface ChatViewProps {
  sessionId: string;
  initialMessages: Message[];
}

export function ChatView({ sessionId, initialMessages }: ChatViewProps) {
  const {
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
  } = useSession(sessionId);

  const [input, setInput] = useState("");
  const messagesEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    setMessages(initialMessages);
  }, [initialMessages, setMessages]);

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [messages, streaming.text]);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!input.trim() || status === "streaming") return;
    sendMessage(input.trim());
    setInput("");
  }

  return (
    <div className="flex-1 flex flex-col">
      {/* Header */}
      <div className="px-4 py-2 border-b border-gray-800 flex items-center justify-between bg-gray-900">
        <div className="text-sm">
          <span className="text-gray-400">Status: </span>
          <span
            className={
              status === "streaming"
                ? "text-green-400"
                : status === "error"
                  ? "text-red-400"
                  : "text-gray-300"
            }
          >
            {status}
          </span>
        </div>
        {status === "streaming" && (
          <button onClick={cancel} className="text-xs px-2 py-1 bg-red-600 text-white rounded hover:bg-red-700">
            Cancel
          </button>
        )}
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-y-auto px-4 py-4 space-y-4">
        {messages.map((msg) => (
          <MessageBubble key={msg.id} message={msg} />
        ))}

        {/* Streaming text */}
        {streaming.text && (
          <div className="bg-gray-900 rounded-lg px-4 py-3 border border-gray-800">
            <div className="text-xs text-gray-500 mb-1">assistant</div>
            {streaming.reasoning && (
              <div className="text-sm text-gray-500 italic mb-2">{streaming.reasoning}</div>
            )}
            <div className="text-sm whitespace-pre-wrap">{streaming.text}</div>
            <span className="inline-block w-2 h-4 bg-blue-500 animate-pulse ml-0.5" />
          </div>
        )}

        {/* Permission requests */}
        {pendingPermissions.map((perm) => (
          <ToolPermission
            key={perm.tool_use_id}
            tool={perm.tool}
            toolUseId={perm.tool_use_id}
            input={perm.input}
            onApprove={approveTool}
            onDeny={denyTool}
          />
        ))}

        {error && (
          <div className="bg-red-900/30 border border-red-800 rounded-lg px-4 py-3 text-red-300 text-sm">
            {error}
          </div>
        )}

        <div ref={messagesEndRef} />
      </div>

      {/* Input */}
      <form onSubmit={handleSubmit} className="px-4 py-3 border-t border-gray-800 bg-gray-900">
        <div className="flex gap-2">
          <input
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder="Type a message..."
            className="flex-1 px-3 py-2 bg-gray-800 border border-gray-700 rounded text-sm text-gray-100 placeholder-gray-500 focus:outline-none focus:border-blue-500"
            disabled={status === "streaming"}
          />
          <button
            type="submit"
            disabled={status === "streaming" || !input.trim()}
            className="px-4 py-2 bg-blue-600 text-white rounded text-sm hover:bg-blue-700 disabled:opacity-50"
          >
            Send
          </button>
        </div>
      </form>
    </div>
  );
}
