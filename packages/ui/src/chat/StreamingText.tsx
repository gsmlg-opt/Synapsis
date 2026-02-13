import React from "react"
import { MarkdownView } from "../widgets/MarkdownView"

interface StreamingTextProps {
  text: string
}

export function StreamingText({ text }: StreamingTextProps) {
  return (
    <div className="flex justify-start">
      <div className="max-w-[85%] rounded-lg p-3 bg-gray-800/50 text-gray-100">
        <div className="text-xs text-gray-500 mb-1 font-mono">assistant</div>
        <MarkdownView content={text} />
        <span className="inline-block w-2 h-4 bg-blue-400 animate-pulse ml-0.5" />
      </div>
    </div>
  )
}
