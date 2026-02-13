import React, { useRef, useEffect } from "react"
import { useSelector } from "react-redux"
import { MessageItem } from "./MessageItem"
import type { RootState } from "./store"

export function MessageList() {
  const messages = useSelector((s: RootState) => s.chat.messages)
  const endRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" })
  }, [messages])

  if (messages.length === 0) {
    return (
      <div className="flex items-center justify-center h-full text-gray-500">
        <p>Start a conversation...</p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {messages.map((msg) => (
        <MessageItem key={msg.id} message={msg} />
      ))}
      <div ref={endRef} />
    </div>
  )
}
