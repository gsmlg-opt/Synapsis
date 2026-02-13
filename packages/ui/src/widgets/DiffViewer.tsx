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
    <div className="border border-gray-700 rounded-lg overflow-hidden text-sm font-mono">
      {filename && (
        <div className="bg-gray-800 px-3 py-1.5 text-gray-400 text-xs border-b border-gray-700">
          {filename}
        </div>
      )}
      <div className="overflow-x-auto">
        <table className="w-full">
          <tbody>
            {oldLines.map((line, i) => (
              <tr key={`old-${i}`} className="bg-red-900/20">
                <td className="px-2 py-0.5 text-red-500 select-none w-8 text-right">-</td>
                <td className="px-2 py-0.5 text-red-300 whitespace-pre">{line}</td>
              </tr>
            ))}
            {newLines.map((line, i) => (
              <tr key={`new-${i}`} className="bg-green-900/20">
                <td className="px-2 py-0.5 text-green-500 select-none w-8 text-right">+</td>
                <td className="px-2 py-0.5 text-green-300 whitespace-pre">{line}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
