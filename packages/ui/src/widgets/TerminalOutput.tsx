import React from "react"

interface TerminalOutputProps {
  content: string
  exitCode?: number
}

export function TerminalOutput({ content, exitCode }: TerminalOutputProps) {
  return (
    <div className="border border-base-300 rounded-lg overflow-hidden">
      <div className="bg-base-300 px-3 py-1.5 text-xs text-base-content/50 flex justify-between border-b border-base-300">
        <span>Terminal</span>
        {exitCode !== undefined && (
          <span className={exitCode === 0 ? "text-success" : "text-error"}>
            exit: {exitCode}
          </span>
        )}
      </div>
      <pre className="p-3 text-sm text-base-content/80 bg-base-200 overflow-x-auto whitespace-pre-wrap">
        {content}
      </pre>
    </div>
  )
}
