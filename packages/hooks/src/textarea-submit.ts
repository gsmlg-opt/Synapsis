export const TextareaSubmitHook = {
  mounted() {
    this.el.addEventListener("keydown", (e: KeyboardEvent) => {
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        const value = (this.el as HTMLTextAreaElement).value.trim()
        if (value) {
          this.pushEvent("send_message", { content: value })
          ;(this.el as HTMLTextAreaElement).value = ""
        }
      }
    })
  },
} as any
