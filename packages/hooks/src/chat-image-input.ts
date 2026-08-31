export type ChatImagePayload = {
  name: string
  media_type: string
  data: string
}

type ReadableFile = {
  name: string
  type: string
  arrayBuffer(): Promise<ArrayBuffer>
}

type ChatSendEvent = CustomEvent<{
  value?: string
  files?: ReadableFile[]
}>

type ChatInputElement = HTMLElement & {
  setValue(value: string): void
  clearFiles(): void
}

type HookContext = {
  el: ChatInputElement
  pushEvent(event: string, payload: unknown): void
  handleEvent(event: string, callback: () => void): void
  observeFieldSemantics?: () => { disconnect(): void } | null
  fieldSemanticsObserver?: { disconnect(): void }
  sendListener?: EventListener
  encodingImages?: boolean
}

const base64ChunkSize = 0x8000

export async function encodeChatImages(
  files: readonly ReadableFile[]
): Promise<ChatImagePayload[]> {
  return Promise.all(
    files.map(async (file) => ({
      name: file.name,
      media_type: file.type,
      data: bytesToBase64(new Uint8Array(await file.arrayBuffer())),
    }))
  )
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ""

  for (let offset = 0; offset < bytes.length; offset += base64ChunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + base64ChunkSize))
  }

  return btoa(binary)
}

export const ChatImageInputHook = {
  mounted(this: HookContext) {
    this.fieldSemanticsObserver = this.observeFieldSemantics?.() || undefined

    this.handleEvent("clear_chat_input", () => {
      this.el.setValue("")
      this.el.clearFiles()
    })

    this.sendListener = ((event: ChatSendEvent) => {
      if (this.encodingImages) return

      this.encodingImages = true
      const value = event.detail?.value || ""
      const files = event.detail?.files || []

      encodeChatImages(files)
        .then((images) => this.pushEvent("send_message", { value, images }))
        .catch(() => this.pushEvent("image_attachment_error", {}))
        .finally(() => {
          this.encodingImages = false
        })
    }) as EventListener

    this.el.addEventListener("send", this.sendListener)
  },

  destroyed(this: HookContext) {
    if (this.sendListener) this.el.removeEventListener("send", this.sendListener)
    this.fieldSemanticsObserver?.disconnect()
  },
}
