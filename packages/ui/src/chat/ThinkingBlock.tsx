import React, { useState } from "react"

interface ThinkingBlockProps {
  content: string
  isStreaming?: boolean
}

export function ThinkingBlock({ content, isStreaming }: ThinkingBlockProps) {
  const [expanded, setExpanded] = useState(false)

  return (
    <div className="border border-base-300 rounded-lg p-3 bg-base-200/50">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-2 text-sm text-base-content/60 hover:text-base-content/80 w-full"
      >
        <span className={`transition-transform ${expanded ? "rotate-90" : ""}`}>
          ▸
        </span>
        <span>Thinking{isStreaming ? "..." : ""}</span>
        {isStreaming && (
          <span className="inline-block w-1.5 h-3 bg-secondary animate-pulse" />
        )}
      </button>
      {expanded && (
        <div className="mt-2 pl-4 border-l border-base-300 text-base-content/60 text-sm whitespace-pre-wrap">
          {content}
        </div>
      )}
    </div>
  )
}
