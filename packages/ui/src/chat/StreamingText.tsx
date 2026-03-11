import React from "react"
import { MarkdownView } from "../widgets/MarkdownView"

interface StreamingTextProps {
  text: string
}

export function StreamingText({ text }: StreamingTextProps) {
  return (
    <div className="flex justify-start">
      <div className="max-w-[85%] rounded-lg p-3 bg-base-200 text-base-content">
        <div className="text-xs text-base-content/50 mb-1 font-mono">assistant</div>
        <MarkdownView content={text} />
        <span className="inline-block w-2 h-4 bg-primary animate-pulse ml-0.5" />
      </div>
    </div>
  )
}
