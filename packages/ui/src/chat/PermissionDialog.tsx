import React from "react"
import { useSelector, useDispatch } from "react-redux"
import { chatActions } from "./store"
import type { RootState } from "./store"

export function PermissionDialog() {
  const dispatch = useDispatch()
  const permissionRequests = useSelector((s: RootState) => s.chat.permissionRequests)
  const pendingToolCalls = useSelector((s: RootState) => s.chat.pendingToolCalls)

  // Only show dialog for permission requests whose tool call is still pending
  const activeRequests = permissionRequests.filter((pr) => {
    const tc = pendingToolCalls.find((t) => t.tool_use_id === pr.tool_use_id)
    return tc && tc.status === "pending"
  })

  if (activeRequests.length === 0) return null

  const current = activeRequests[0]

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="bg-base-100 border border-base-300 rounded-xl shadow-2xl w-full max-w-lg mx-4">
        <div className="flex items-center gap-2 px-5 py-3 border-b border-base-300">
          <svg className="w-5 h-5 text-warning" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L4.082 16.5c-.77.833.192 2.5 1.732 2.5z" />
          </svg>
          <h3 className="text-base-content font-semibold">Tool Permission Required</h3>
          {activeRequests.length > 1 && (
            <span className="ml-auto text-xs text-base-content/50">
              1 of {activeRequests.length}
            </span>
          )}
        </div>

        <div className="px-5 py-4 space-y-3">
          <div className="flex items-center gap-2">
            <span className="text-base-content/60 text-sm">Tool:</span>
            <span className="text-primary font-mono text-sm font-bold">{current.tool}</span>
          </div>

          <div>
            <span className="text-base-content/60 text-sm block mb-1">Arguments:</span>
            <pre className="bg-base-200 border border-base-300 rounded-lg p-3 text-base-content/80 text-xs overflow-x-auto max-h-48 overflow-y-auto">
              {JSON.stringify(current.input, null, 2)}
            </pre>
          </div>
        </div>

        <div className="flex gap-3 px-5 py-3 border-t border-base-300">
          <button
            onClick={() => dispatch(chatActions.denyToolCall(current.tool_use_id))}
            className="flex-1 px-4 py-2 text-sm font-medium bg-base-200 hover:bg-base-300 text-base-content rounded-lg transition-colors"
          >
            Deny
          </button>
          <button
            onClick={() => dispatch(chatActions.approveToolCall(current.tool_use_id))}
            className="flex-1 px-4 py-2 text-sm font-medium bg-success hover:bg-success/80 text-success-content rounded-lg transition-colors"
          >
            Approve
          </button>
        </div>
      </div>
    </div>
  )
}
