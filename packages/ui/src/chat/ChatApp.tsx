import React from "react"
import { Provider } from "react-redux"
import { MessageList } from "./MessageList"
import { MessageInput } from "./MessageInput"
import { StreamingText } from "./StreamingText"
import { ToolCallCard } from "./ToolCallCard"
import { ThinkingBlock } from "./ThinkingBlock"
import { useSelector } from "react-redux"
import type { RootState } from "./store"

function ChatContent({ onNavigate }: { onNavigate?: (path: string) => void }) {
  const status = useSelector((s: RootState) => s.chat.status)
  const streamingText = useSelector((s: RootState) => s.chat.streamingText)
  const streamingType = useSelector((s: RootState) => s.chat.streamingType)
  const pendingToolCalls = useSelector((s: RootState) => s.chat.pendingToolCalls)
  const permissionRequests = useSelector((s: RootState) => s.chat.permissionRequests)
  const error = useSelector((s: RootState) => s.chat.error)

  return (
    <div className="flex flex-col h-full">
      <div className="flex-1 overflow-y-auto p-4 space-y-4">
        <MessageList />

        {streamingType === "thinking" && streamingText && (
          <ThinkingBlock content={streamingText} isStreaming={true} />
        )}

        {streamingType === "text" && streamingText && (
          <StreamingText text={streamingText} />
        )}

        {pendingToolCalls.map((tc) => (
          <ToolCallCard
            key={tc.tool_use_id}
            toolCall={tc}
            permissionRequest={permissionRequests.find(
              (pr) => pr.tool_use_id === tc.tool_use_id
            )}
          />
        ))}

        {error && (
          <div className="p-3 bg-red-900/50 text-red-200 rounded text-sm">
            {error}
          </div>
        )}
      </div>

      <MessageInput disabled={status === "streaming" || status === "tool_wait"} />
    </div>
  )
}

interface ChatAppProps {
  store: any
  onNavigate?: (path: string) => void
}

export function ChatApp({ store, onNavigate }: ChatAppProps) {
  return (
    <Provider store={store}>
      <ChatContent onNavigate={onNavigate} />
    </Provider>
  )
}
