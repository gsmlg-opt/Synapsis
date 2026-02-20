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
      <div className="bg-gray-800 border border-gray-600 rounded-xl shadow-2xl w-full max-w-lg mx-4">
        <div className="flex items-center gap-2 px-5 py-3 border-b border-gray-700">
          <svg className="w-5 h-5 text-yellow-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L4.082 16.5c-.77.833.192 2.5 1.732 2.5z" />
          </svg>
          <h3 className="text-white font-semibold">Tool Permission Required</h3>
          {activeRequests.length > 1 && (
            <span className="ml-auto text-xs text-gray-400">
              1 of {activeRequests.length}
            </span>
          )}
        </div>

        <div className="px-5 py-4 space-y-3">
          <div className="flex items-center gap-2">
            <span className="text-gray-400 text-sm">Tool:</span>
            <span className="text-blue-400 font-mono text-sm font-bold">{current.tool}</span>
          </div>

          <div>
            <span className="text-gray-400 text-sm block mb-1">Arguments:</span>
            <pre className="bg-gray-900 border border-gray-700 rounded-lg p-3 text-gray-300 text-xs overflow-x-auto max-h-48 overflow-y-auto">
              {JSON.stringify(current.input, null, 2)}
            </pre>
          </div>
        </div>

        <div className="flex gap-3 px-5 py-3 border-t border-gray-700">
          <button
            onClick={() => dispatch(chatActions.denyToolCall(current.tool_use_id))}
            className="flex-1 px-4 py-2 text-sm font-medium bg-gray-700 hover:bg-gray-600 text-gray-200 rounded-lg transition-colors"
          >
            Deny
          </button>
          <button
            onClick={() => dispatch(chatActions.approveToolCall(current.tool_use_id))}
            className="flex-1 px-4 py-2 text-sm font-medium bg-green-600 hover:bg-green-500 text-white rounded-lg transition-colors"
          >
            Approve
          </button>
        </div>
      </div>
    </div>
  )
}
