import React, { useState } from "react"

interface ThinkingBlockProps {
  content: string
  isStreaming?: boolean
}

export function ThinkingBlock({ content, isStreaming }: ThinkingBlockProps) {
  const [expanded, setExpanded] = useState(false)

  return (
    <div className="border border-gray-700 rounded-lg p-3 bg-gray-900/50">
      <button
        onClick={() => setExpanded(!expanded)}
        className="flex items-center gap-2 text-sm text-gray-400 hover:text-gray-300 w-full"
      >
        <span className={`transition-transform ${expanded ? "rotate-90" : ""}`}>
          ▸
        </span>
        <span>Thinking{isStreaming ? "..." : ""}</span>
        {isStreaming && (
          <span className="inline-block w-1.5 h-3 bg-purple-400 animate-pulse" />
        )}
      </button>
      {expanded && (
        <div className="mt-2 pl-4 border-l border-gray-700 text-gray-400 text-sm whitespace-pre-wrap">
          {content}
        </div>
      )}
    </div>
  )
}
