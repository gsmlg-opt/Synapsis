import React, { useState, useRef, useEffect } from "react"
import { useDispatch, useSelector } from "react-redux"
import { chatActions, type RootState } from "./store"

interface MessageInputProps {
  disabled?: boolean
}

export function MessageInput({ disabled }: MessageInputProps) {
  const [text, setText] = useState("")
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const dispatch = useDispatch()
  const status = useSelector((s: RootState) => s.chat.status)

  useEffect(() => {
    if (!disabled) {
      textareaRef.current?.focus()
    }
  }, [disabled])

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault()
    const trimmed = text.trim()
    if (!trimmed || disabled) return
    dispatch(chatActions.sendMessage(trimmed))
    setText("")
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault()
      handleSubmit(e)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="border-t border-gray-800 p-4">
      <div className="flex gap-2">
        <textarea
          ref={textareaRef}
          value={text}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Type a message..."
          disabled={disabled}
          rows={1}
          className="flex-1 bg-gray-800 text-gray-100 rounded-lg px-4 py-2 resize-none
                     border border-gray-700 focus:border-blue-500 focus:outline-none
                     placeholder-gray-500 disabled:opacity-50"
        />
        {status === "streaming" || status === "tool_wait" ? (
          <button
            type="button"
            onClick={() => dispatch(chatActions.cancel())}
            className="px-4 py-2 bg-red-700 hover:bg-red-600 text-white rounded-lg text-sm"
          >
            Stop
          </button>
        ) : (
          <button
            type="submit"
            disabled={!text.trim() || disabled}
            className="px-4 py-2 bg-blue-600 hover:bg-blue-500 text-white rounded-lg text-sm
                       disabled:opacity-50 disabled:cursor-not-allowed"
          >
            Send
          </button>
        )}
      </div>
    </form>
  )
}
