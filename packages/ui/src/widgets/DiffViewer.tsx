import React from "react"

interface DiffViewerProps {
  oldContent: string
  newContent: string
  filename?: string
}

export function DiffViewer({ oldContent, newContent, filename }: DiffViewerProps) {
  const oldLines = oldContent.split("\n")
  const newLines = newContent.split("\n")

  return (
    <div className="border border-base-300 rounded-lg overflow-hidden text-sm font-mono">
      {filename && (
        <div className="bg-base-200 px-3 py-1.5 text-base-content/60 text-xs border-b border-base-300">
          {filename}
        </div>
      )}
      <div className="overflow-x-auto">
        <table className="w-full">
          <tbody>
            {oldLines.map((line, i) => (
              <tr key={`old-${i}`} className="bg-error/10">
                <td className="px-2 py-0.5 text-error select-none w-8 text-right">-</td>
                <td className="px-2 py-0.5 text-error/80 whitespace-pre">{line}</td>
              </tr>
            ))}
            {newLines.map((line, i) => (
              <tr key={`new-${i}`} className="bg-success/10">
                <td className="px-2 py-0.5 text-success select-none w-8 text-right">+</td>
                <td className="px-2 py-0.5 text-success/80 whitespace-pre">{line}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
