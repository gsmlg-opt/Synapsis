import React, { useState, useRef, useEffect } from "react"
import { useDispatch, useSelector } from "react-redux"
import { chatActions, type RootState, type ImageAttachment } from "./store"

interface MessageInputProps {
  disabled?: boolean
}

export function MessageInput({ disabled }: MessageInputProps) {
  const [text, setText] = useState("")
  const [images, setImages] = useState<ImageAttachment[]>([])
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const fileInputRef = useRef<HTMLInputElement>(null)
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

    if (images.length > 0) {
      dispatch(chatActions.sendMessage({ content: trimmed, images }))
    } else {
      dispatch(chatActions.sendMessage(trimmed))
    }
    setText("")
    setImages([])
  }

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault()
      handleSubmit(e)
    }
  }

  const handleImageSelect = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const files = e.target.files
    if (!files) return

    const newImages: ImageAttachment[] = []
    for (const file of Array.from(files)) {
      if (!file.type.startsWith("image/")) continue
      const data = await fileToBase64(file)
      newImages.push({ name: file.name, media_type: file.type, data })
    }
    setImages((prev) => [...prev, ...newImages])
    if (fileInputRef.current) fileInputRef.current.value = ""
  }

  const removeImage = (index: number) => {
    setImages((prev) => prev.filter((_, i) => i !== index))
  }

  return (
    <form onSubmit={handleSubmit} className="border-t border-gray-800 p-4">
      {images.length > 0 && (
        <div className="flex gap-2 mb-2 flex-wrap">
          {images.map((img, i) => (
            <div key={i} className="relative group">
              <img
                src={`data:${img.media_type};base64,${img.data}`}
                alt={img.name}
                className="h-16 w-16 object-cover rounded-lg border border-gray-700"
              />
              <button
                type="button"
                onClick={() => removeImage(i)}
                className="absolute -top-1 -right-1 w-5 h-5 bg-red-600 text-white rounded-full text-xs
                           opacity-0 group-hover:opacity-100 transition-opacity flex items-center justify-center"
              >
                x
              </button>
            </div>
          ))}
        </div>
      )}

      <div className="flex gap-2">
        <button
          type="button"
          onClick={() => fileInputRef.current?.click()}
          disabled={disabled}
          className="px-3 py-2 bg-gray-800 hover:bg-gray-700 text-gray-400 rounded-lg text-sm
                     border border-gray-700 disabled:opacity-50"
          title="Attach image"
        >
          <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z" />
          </svg>
        </button>
        <input
          ref={fileInputRef}
          type="file"
          accept="image/*"
          multiple
          onChange={handleImageSelect}
          className="hidden"
        />
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

function fileToBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => {
      const result = reader.result as string
      const base64 = result.split(",")[1] || result
      resolve(base64)
    }
    reader.onerror = reject
    reader.readAsDataURL(file)
  })
}
