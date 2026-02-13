import React from "react"
import { useDispatch } from "react-redux"
import { chatActions } from "./store"
import type { ToolCall, PermissionRequest } from "./store"

interface ToolCallCardProps {
  toolCall: ToolCall
  permissionRequest?: PermissionRequest
}

export function ToolCallCard({ toolCall, permissionRequest }: ToolCallCardProps) {
  const dispatch = useDispatch()

  const statusColors: Record<string, string> = {
    pending: "border-yellow-700 bg-yellow-900/20",
    approved: "border-blue-700 bg-blue-900/20",
    completed: "border-green-700 bg-green-900/20",
    error: "border-red-700 bg-red-900/20",
    denied: "border-gray-700 bg-gray-900/20",
  }

  return (
    <div className={`border rounded-lg p-3 ${statusColors[toolCall.status] || "border-gray-700"}`}>
      <div className="flex items-center justify-between mb-2">
        <span className="text-blue-400 font-mono text-sm font-bold">
          {toolCall.tool}
        </span>
        <span className="text-xs text-gray-500 capitalize">
          {toolCall.status}
        </span>
      </div>

      <pre className="text-gray-400 text-xs overflow-x-auto mb-2">
        {JSON.stringify(toolCall.input, null, 2)}
      </pre>

      {permissionRequest && toolCall.status === "pending" && (
        <div className="flex gap-2 mt-2">
          <button
            onClick={() => dispatch(chatActions.approveToolCall(toolCall.tool_use_id))}
            className="px-3 py-1 text-sm bg-green-700 hover:bg-green-600 text-white rounded"
          >
            Approve
          </button>
          <button
            onClick={() => dispatch(chatActions.denyToolCall(toolCall.tool_use_id))}
            className="px-3 py-1 text-sm bg-red-700 hover:bg-red-600 text-white rounded"
          >
            Deny
          </button>
        </div>
      )}

      {toolCall.result && (
        <div className={`mt-2 p-2 rounded text-xs ${
          toolCall.status === "error" ? "bg-red-900/30 text-red-300" : "bg-green-900/30 text-green-300"
        }`}>
          <pre className="whitespace-pre-wrap overflow-x-auto">{toolCall.result}</pre>
        </div>
      )}
    </div>
  )
}
