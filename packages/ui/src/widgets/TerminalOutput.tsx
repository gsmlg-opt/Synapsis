import React from "react"

interface TerminalOutputProps {
  content: string
  exitCode?: number
}

export function TerminalOutput({ content, exitCode }: TerminalOutputProps) {
  return (
    <div className="border border-gray-700 rounded-lg overflow-hidden">
      <div className="bg-gray-900 px-3 py-1.5 text-xs text-gray-500 flex justify-between border-b border-gray-700">
        <span>Terminal</span>
        {exitCode !== undefined && (
          <span className={exitCode === 0 ? "text-green-500" : "text-red-500"}>
            exit: {exitCode}
          </span>
        )}
      </div>
      <pre className="p-3 text-sm text-gray-300 bg-black/50 overflow-x-auto whitespace-pre-wrap">
        {content}
      </pre>
    </div>
  )
}
