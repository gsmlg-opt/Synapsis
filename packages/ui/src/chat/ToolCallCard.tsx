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
    pending: "border-warning/50 bg-warning/10",
    approved: "border-primary/50 bg-primary/10",
    completed: "border-success/50 bg-success/10",
    error: "border-error/50 bg-error/10",
    denied: "border-base-300 bg-base-200",
  }

  return (
    <div className={`border rounded-lg p-3 ${statusColors[toolCall.status] || "border-base-300"}`}>
      <div className="flex items-center justify-between mb-2">
        <span className="text-primary font-mono text-sm font-bold">
          {toolCall.tool}
        </span>
        <span className="text-xs text-base-content/50 capitalize">
          {toolCall.status}
        </span>
      </div>

      <pre className="text-base-content/60 text-xs overflow-x-auto mb-2">
        {JSON.stringify(toolCall.input, null, 2)}
      </pre>

      {permissionRequest && toolCall.status === "pending" && (
        <div className="flex gap-2 mt-2">
          <button
            onClick={() => dispatch(chatActions.approveToolCall(toolCall.tool_use_id))}
            className="px-3 py-1 text-sm bg-success hover:bg-success/80 text-success-content rounded"
          >
            Approve
          </button>
          <button
            onClick={() => dispatch(chatActions.denyToolCall(toolCall.tool_use_id))}
            className="px-3 py-1 text-sm bg-error hover:bg-error/80 text-error-content rounded"
          >
            Deny
          </button>
        </div>
      )}

      {toolCall.result && (
        <div className={`mt-2 p-2 rounded text-xs ${
          toolCall.status === "error" ? "bg-error/20 text-error" : "bg-success/20 text-success"
        }`}>
          <pre className="whitespace-pre-wrap overflow-x-auto">{toolCall.result}</pre>
        </div>
      )}
    </div>
  )
}
