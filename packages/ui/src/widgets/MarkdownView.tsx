import React from "react"

interface MarkdownViewProps {
  content: string
}

export function MarkdownView({ content }: MarkdownViewProps) {
  // Simple markdown rendering — renders as pre-formatted text
  // A full implementation would use react-markdown + rehype-highlight
  return (
    <div className="prose prose-invert prose-sm max-w-none">
      <div className="whitespace-pre-wrap break-words">{content}</div>
    </div>
  )
}
