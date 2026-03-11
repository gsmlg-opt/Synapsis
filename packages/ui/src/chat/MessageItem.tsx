import React from "react"
import type { Message, MessagePart } from "./store"
import { MarkdownView } from "../widgets/MarkdownView"
import { DiffViewer } from "../widgets/DiffViewer"

function tryParseToolResult(content: string | undefined): { parsed: any; hasDiff: boolean } {
  if (!content) return { parsed: null, hasDiff: false }
  try {
    const parsed = JSON.parse(content)
    return { parsed, hasDiff: !!(parsed?.diff?.old !== undefined && parsed?.diff?.new !== undefined) }
  } catch {
    return { parsed: null, hasDiff: false }
  }
}

function PartView({ part }: { part: MessagePart }) {
  switch (part.type) {
    case "text":
      return <MarkdownView content={part.content || ""} />
    case "reasoning":
      return (
        <details className="text-base-content/60 text-sm">
          <summary className="cursor-pointer hover:text-base-content/80">Thinking...</summary>
          <div className="mt-1 pl-3 border-l border-base-300 whitespace-pre-wrap">
            {part.content}
          </div>
        </details>
      )
    case "tool_use":
      return (
        <div className="border border-primary/30 rounded p-3 text-sm">
          <div className="text-primary font-mono font-bold mb-1">
            Tool: {part.tool}
          </div>
          {part.input && (
            <pre className="text-base-content/60 text-xs whitespace-pre-wrap break-all overflow-x-auto">
              {JSON.stringify(part.input, null, 2)}
            </pre>
          )}
          {part.status && (
            <div className="mt-1 text-xs text-base-content/50">Status: {part.status}</div>
          )}
        </div>
      )
    case "tool_result": {
      const { parsed, hasDiff } = tryParseToolResult(part.content)
      if (hasDiff) {
        return (
          <div className="border border-success/30 rounded p-3 text-sm">
            <div className="font-mono text-xs mb-2 text-success">
              {parsed.message || `Edited ${parsed.path || "file"}`}
            </div>
            <DiffViewer
              oldContent={parsed.diff.old}
              newContent={parsed.diff.new}
              filename={parsed.path}
            />
          </div>
        )
      }
      return (
        <div
          className={`border rounded p-3 text-sm ${
            part.is_error
              ? "border-error/30 text-error"
              : "border-success/30 text-success"
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
    }
    case "file":
      return (
        <div className="border border-warning/30 rounded p-3 text-sm">
          <div className="text-warning font-mono text-xs">{part.content}</div>
        </div>
      )
    default:
      return (
        <div className="text-base-content/50 text-sm">
          [{part.type}]
        </div>
      )
  }
}

export function MessageItem({ message }: { message: Message }) {
  const isUser = message.role === "user"

  return (
    <div className={`flex min-w-0 ${isUser ? "justify-end" : "justify-start"}`}>
      <div
        className={`max-w-[85%] min-w-0 rounded-lg p-3 ${
          isUser
            ? "bg-primary/20 text-base-content"
            : "bg-base-200 text-base-content"
        }`}
      >
        <div className="text-xs text-base-content/50 mb-1 font-mono">
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
