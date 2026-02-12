import type { Message, MessagePart } from "../lib/api";

interface MessageBubbleProps {
  message: Message;
}

export function MessageBubble({ message }: MessageBubbleProps) {
  const isUser = message.role === "user";

  return (
    <div className={`rounded-lg px-4 py-3 ${isUser ? "bg-gray-800" : "bg-gray-900 border border-gray-800"}`}>
      <div className="text-xs text-gray-500 mb-1">{message.role}</div>
      <div className="space-y-2">
        {message.parts.map((part, i) => (
          <PartView key={i} part={part} />
        ))}
      </div>
    </div>
  );
}

function PartView({ part }: { part: MessagePart }) {
  switch (part.type) {
    case "text":
      return <div className="text-sm whitespace-pre-wrap">{part.content}</div>;

    case "reasoning":
      return <div className="text-sm text-gray-500 italic">{part.content}</div>;

    case "tool_use":
      return (
        <div className="bg-gray-800 rounded px-3 py-2 text-xs font-mono border border-gray-700">
          <div className="text-blue-400 mb-1">Tool: {part.tool}</div>
          {part.input && (
            <pre className="text-gray-400 overflow-x-auto">{JSON.stringify(part.input, null, 2)}</pre>
          )}
          {part.status && <div className="text-gray-500 mt-1">Status: {part.status}</div>}
        </div>
      );

    case "tool_result":
      return (
        <div
          className={`rounded px-3 py-2 text-xs font-mono border ${
            part.is_error ? "bg-red-900/20 border-red-800 text-red-300" : "bg-green-900/20 border-green-800 text-green-300"
          }`}
        >
          <div className="mb-1">{part.is_error ? "Error" : "Result"}</div>
          <pre className="overflow-x-auto whitespace-pre-wrap">{part.content}</pre>
        </div>
      );

    case "file":
      return (
        <div className="bg-gray-800 rounded px-3 py-2 text-xs font-mono border border-gray-700">
          <div className="text-yellow-400 mb-1">File: {part.content}</div>
        </div>
      );

    default:
      return <div className="text-xs text-gray-600">[{part.type}]</div>;
  }
}
