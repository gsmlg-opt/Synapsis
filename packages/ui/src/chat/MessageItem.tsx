import React from "react"
import type { Message, MessagePart } from "./store"
import { MarkdownView } from "../widgets/MarkdownView"

function PartView({ part }: { part: MessagePart }) {
  switch (part.type) {
    case "text":
      return <MarkdownView content={part.content || ""} />
    case "reasoning":
      return (
        <details className="text-gray-400 text-sm">
          <summary className="cursor-pointer hover:text-gray-300">Thinking...</summary>
          <div className="mt-1 pl-3 border-l border-gray-700 whitespace-pre-wrap">
            {part.content}
          </div>
        </details>
      )
    case "tool_use":
      return (
        <div className="border border-blue-800 rounded p-3 text-sm">
          <div className="text-blue-400 font-mono font-bold mb-1">
            Tool: {part.tool}
          </div>
          {part.input && (
            <pre className="text-gray-400 text-xs overflow-x-auto">
              {JSON.stringify(part.input, null, 2)}
            </pre>
          )}
          {part.status && (
            <div className="mt-1 text-xs text-gray-500">Status: {part.status}</div>
          )}
        </div>
      )
    case "tool_result":
      return (
        <div
          className={`border rounded p-3 text-sm ${
            part.is_error
              ? "border-red-800 text-red-300"
              : "border-green-800 text-green-300"
          }`}
        >
          <div className="font-mono text-xs mb-1">
            {part.is_error ? "Error" : "Result"}
          </div>
          <pre className="whitespace-pre-wrap text-xs overflow-x-auto">
            {part.content}
          </pre>
        </div>
      )
    case "file":
      return (
        <div className="border border-yellow-800 rounded p-3 text-sm">
          <div className="text-yellow-400 font-mono text-xs">{part.content}</div>
        </div>
      )
    default:
      return (
        <div className="text-gray-500 text-sm">
          [{part.type}]
        </div>
      )
  }
}

export function MessageItem({ message }: { message: Message }) {
  const isUser = message.role === "user"

  return (
    <div className={`flex ${isUser ? "justify-end" : "justify-start"}`}>
      <div
        className={`max-w-[85%] rounded-lg p-3 ${
          isUser
            ? "bg-blue-900/50 text-blue-100"
            : "bg-gray-800/50 text-gray-100"
        }`}
      >
        <div className="text-xs text-gray-500 mb-1 font-mono">
          {message.role}
        </div>
        <div className="space-y-2">
          {message.parts.map((part, i) => (
            <PartView key={i} part={part} />
          ))}
        </div>
      </div>
    </div>
  )
}
